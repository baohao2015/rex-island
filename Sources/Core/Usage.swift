import Foundation

/// One rate-limit window of a plan, e.g. Claude's 5-hour window at 62%.
struct LimitWindow: Equatable, Identifiable {
    enum Span: String { case fiveHour, weekly }

    var span: Span
    var usedPercent: Double
    var resetsAt: Date?

    var id: String { span.rawValue }
    var length: TimeInterval { span == .fiveHour ? 5 * 3600 : 7 * 86400 }

    /// After its reset time a window starts over: nothing used yet, next reset unknown until new data.
    func current(now: Date = Date()) -> LimitWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        return LimitWindow(span: span, usedPercent: 0, resetsAt: nil)
    }

    /// How far usage runs ahead of time: +0.12 means 12 points more used than the window has elapsed.
    func pace(now: Date = Date()) -> Double? {
        guard let resetsAt else { return nil }
        let elapsed = 1 - resetsAt.timeIntervalSince(now) / length
        guard elapsed > 0.02, elapsed <= 1 else { return nil }
        return usedPercent / 100 - elapsed
    }
}

struct TokenTotals: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    static func - (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(input: lhs.input - rhs.input, output: lhs.output - rhs.output,
                    cacheRead: lhs.cacheRead - rhs.cacheRead, cacheWrite: lhs.cacheWrite - rhs.cacheWrite)
    }

    var isNegative: Bool { input < 0 || output < 0 || cacheRead < 0 || cacheWrite < 0 }
}

struct ProviderUsage: Equatable {
    var provider: AgentKind
    var plan: String?
    /// Windows past their reset time read as fresh (0%).
    var windows: [LimitWindow]
    var today: TokenTotals

    func window(_ span: LimitWindow.Span) -> LimitWindow? { windows.first { $0.span == span } }
}

/// What the status line wrapper recorded for one Claude Code session.
struct ClaudeSessionStatus: Equatable {
    var sessionID: String
    var block: String?
    var at: Date
    var model: String?
    var contextPercent: Double?
    var costUSD: Double?
    var limits: [LimitWindow]

    static func parse(_ data: Data) -> ClaudeSessionStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["session_id"] as? String,
              let at = (object["at"] as? NSNumber)?.doubleValue else { return nil }
        return ClaudeSessionStatus(
            sessionID: id,
            block: object["block"] as? String,
            at: Date(timeIntervalSince1970: at),
            model: object["model"] as? String,
            contextPercent: (object["context_used_percentage"] as? NSNumber)?.doubleValue,
            costUSD: (object["cost_usd"] as? NSNumber)?.doubleValue,
            limits: claudeLimits(object["rate_limits"] as? [String: Any] ?? [:])
        )
    }

    /// `rate_limits` from Claude Code's status line input: `used_percentage`, `resets_at` in epoch seconds.
    static func claudeLimits(_ limits: [String: Any]) -> [LimitWindow] {
        [("five_hour", LimitWindow.Span.fiveHour), ("seven_day", .weekly)].compactMap { key, span in
            guard let entry = limits[key] as? [String: Any],
                  let used = (entry["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return LimitWindow(span: span, usedPercent: used, resetsAt: resets)
        }
    }

    /// Reads every session file, deleting ones older than two days.
    static func loadAll(in directory: URL, now: Date = Date()) -> [ClaudeSessionStatus] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 2 * 86400 {
                try? fm.removeItem(at: url)
                return nil
            }
            return (try? Data(contentsOf: url)).flatMap(parse)
        }
    }

    /// Plan limits are account-wide: the newest report wins, with windows that reset since shown as fresh.
    static func currentLimits(_ sessions: [ClaudeSessionStatus], now: Date = Date()) -> [LimitWindow] {
        let newest = sessions.filter { !$0.limits.isEmpty }.max { $0.at < $1.at }
        return (newest?.limits ?? []).map { $0.current(now: now) }
    }
}

/// Today's token use from local transcripts, plus Codex's latest plan limits. Reads files incrementally:
/// transcripts only grow, so each scan reads just the bytes appended since the last one.
/// Not thread-safe: the app confines it to one serial queue, hence `@unchecked Sendable`.
final class UsageScanner: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64 = 0
        /// Codex reports running totals; today's use is the sum of the increases.
        var codexTotal = TokenTotals()
    }

    private(set) var claudeToday = TokenTotals()
    private(set) var codexToday = TokenTotals()
    private(set) var codexLimits: [LimitWindow] = []
    private(set) var codexPlan: String?
    private var codexLimitsAt = Date.distantPast
    private var files: [String: FileState] = [:]
    private var claudeSeen = Set<String>()
    private var day: Date?
    private let claudeRoot: URL
    private let codexRoot: URL

    init(claudeRoot: URL, codexRoot: URL) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
    }

    func scan(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        if day != today {
            day = today
            files = [:]
            claudeSeen = []
            claudeToday = TokenTotals()
            codexToday = TokenTotals()
        }
        for url in Self.jsonl(under: claudeRoot, modifiedSince: today) {
            read(url) { line, _ in self.claudeLine(line, since: today) }
        }
        for url in Self.jsonl(under: codexRoot, modifiedSince: today) {
            read(url) { line, state in self.codexLine(line, since: today, state: &state) }
        }
        codexLimits = codexLimits.map { $0.current(now: now) }
    }

    // MARK: Claude: assistant lines carry `message.usage`; one API response can span several lines.

    private func claudeLine(_ line: Substring, since day: Date) {
        guard line.contains("\"usage\""),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["type"] as? String == "assistant",
              let date = RexParse.date(object["timestamp"] as? String), date >= day,
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let key = (message["id"] as? String ?? "") + "|" + (object["requestId"] as? String ?? "")
        guard key != "|", claudeSeen.insert(key).inserted else { return }
        func int(_ name: String) -> Int { (usage[name] as? NSNumber)?.intValue ?? 0 }
        claudeToday = claudeToday + TokenTotals(input: int("input_tokens"), output: int("output_tokens"),
                                                cacheRead: int("cache_read_input_tokens"),
                                                cacheWrite: int("cache_creation_input_tokens"))
    }

    // MARK: Codex: `token_count` events with running totals and the plan's rate limits.

    private func codexLine(_ line: Substring, since day: Date, state: inout FileState) {
        guard line.contains("\"token_count\""),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count" else { return }
        let date = RexParse.date(object["timestamp"] as? String) ?? Date()

        if let total = ((payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any]).map(Self.codexTotals) {
            var delta = total - state.codexTotal
            if delta.isNegative { delta = total } // a new run in the same file restarted its count
            if date >= day { codexToday = codexToday + delta }
            state.codexTotal = total
        }
        if let limits = payload["rate_limits"] as? [String: Any], date >= codexLimitsAt {
            let windows = Self.codexLimits(limits)
            if !windows.isEmpty {
                codexLimits = windows
                codexPlan = limits["plan_type"] as? String
                codexLimitsAt = date
            }
        }
    }

    /// Codex counts cached tokens inside `input_tokens`; split them out so totals match Claude's.
    static func codexTotals(_ usage: [String: Any]) -> TokenTotals {
        func int(_ name: String) -> Int { (usage[name] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cached_input_tokens")
        return TokenTotals(input: max(0, int("input_tokens") - cached), output: int("output_tokens"), cacheRead: cached, cacheWrite: 0)
    }

    static func codexLimits(_ limits: [String: Any]) -> [LimitWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let entry = limits[key] as? [String: Any],
                  let used = (entry["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (entry["window_minutes"] as? NSNumber)?.doubleValue ?? (key == "primary" ? 300 : 10_080)
            let resets = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return LimitWindow(span: minutes <= 600 ? .fiveHour : .weekly, usedPercent: used, resetsAt: resets)
        }
    }

    // MARK: Files

    /// Reads complete lines appended since the last scan; a half-written last line waits for the next one.
    private func read(_ url: URL, _ handle: (Substring, inout FileState) -> Void) {
        var state = files[url.path] ?? FileState()
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() } // truncated or replaced
        guard size > state.offset else { files[url.path] = state; return }
        try? file.seek(toOffset: state.offset)
        guard let data = try? file.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        let text = String(decoding: complete, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            handle(line, &state)
        }
        state.offset += UInt64(complete.count)
        files[url.path] = state
    }

    static func jsonl(under root: URL, modifiedSince date: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= date else { continue }
            result.append(url)
        }
        return result
    }
}
