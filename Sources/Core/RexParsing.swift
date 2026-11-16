import Foundation

/// Parses what the `rex` CLI prints. Everything from Rex is validated here, at the boundary.
enum RexParse {
    static func status(record: [String: Any]) -> RexStatus? {
        guard let state = record["state"] as? String else { return nil }
        return RexStatus(
            state: AgentState(report: state),
            kind: (record["kind"] as? String).flatMap(BlockedKind.init(rawValue:)),
            msg: nonEmpty(record["msg"] as? String),
            app: nonEmpty(record["effective_app"] as? String) ?? nonEmpty(record["app"] as? String),
            progress: (record["progress"] as? NSNumber)?.intValue,
            updatedAt: date(record["updated_at"] as? String) ?? Date()
        )
    }

    /// The record that speaks for a pane: the root record (no ID), else the most urgent one.
    static func paneStatus(records: [[String: Any]]) -> RexStatus? {
        if let root = records.first(where: { ($0["id"] as? String ?? "").isEmpty }), let status = status(record: root) {
            return status
        }
        return records.compactMap(status(record:)).min { $0.state.urgency < $1.state.urgency }
    }

    /// `{"records":[…]}` from the terminal's `program_status` method.
    static func paneStatus(methodResult data: Data) -> RexStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = object["records"] as? [[String: Any]] else { return nil }
        return paneStatus(records: records)
    }

    /// RFC 3339 with any number of fractional digits, e.g. `2026-11-16T21:00:55.860458+08:00`.
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        // Drop fractional digits the formatter refuses, keeping their value.
        guard let dot = text.firstIndex(of: "."),
              let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) else { return nil }
        let fraction = Double("0" + text[dot..<end]) ?? 0
        return plain.date(from: String(text[..<dot]) + String(text[end...]))?.addingTimeInterval(fraction)
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One line of `rex events --all --json`, reduced to what Rex Island acts on.
enum RexEvent: Equatable {
    /// A status report; `record` is nil when it can't be read.
    case status(session: String, block: String, recordID: String, record: RexStatus?)
    /// Some of a pane's records were removed: read the pane again.
    case statusRemoved(session: String, block: String)
    case title(session: String, block: String, title: String?)
    /// The pane's program or directory changed.
    case process(session: String, block: String)
    /// Windows, panes or labels changed in a session.
    case layout(session: String)
    /// Sessions came or went.
    case sessions
    case ignored

    init(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { self = .ignored; return }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch type {
        case "session_created", "session_destroyed", "session_moved":
            self = .sessions
            return
        case "session_event":
            break
        default:
            self = .ignored
            return
        }
        guard let session = payload["session_id"] as? String,
              let event = payload["event"] as? [String: Any],
              let eventType = event["type"] as? String else { self = .ignored; return }
        let body = event["payload"] as? [String: Any] ?? [:]

        guard eventType == "block_event" else {
            if eventType.hasPrefix("client_") {
                self = .ignored
            } else {
                // Unknown session events are treated as layout changes: re-reading a session is cheap and safe.
                self = .layout(session: session)
            }
            return
        }
        guard let block = body["block_id"] as? String, let name = body["name"] as? String else { self = .ignored; return }
        let inner = body["payload"] as? [String: Any] ?? [:]
        switch name {
        case "program_status_changed":
            let record = (inner["record"] as? [String: Any]).flatMap(RexParse.status(record:))
            self = .status(session: session, block: block, recordID: inner["id"] as? String ?? "", record: record)
        case "program_status_removed":
            self = .statusRemoved(session: session, block: block)
        case "title_changed":
            self = .title(session: session, block: block, title: inner["title"] as? String)
        case "process_changed", "pwd_changed", "child_exited":
            self = .process(session: session, block: block)
        default:
            self = .ignored
        }
    }
}

/// Session layout from `session.view`, and pane facts from block methods.
enum RexLayout {
    struct Window: Equatable {
        var id: String
        var label: String?
        var focusedBlockID: String?
    }

    struct View: Equatable {
        var sessionID: String
        var label: String
        var activeWindowID: String?
        var windows: [Window]
    }

    static func view(_ data: Data) -> View? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let session = object["session_id"] as? String else { return nil }
        let windows = (object["windows"] as? [[String: Any]] ?? []).compactMap { window -> Window? in
            guard let id = window["window_id"] as? String else { return nil }
            return Window(id: id, label: userLabel(window["label"] as? String), focusedBlockID: window["focused_block_id"] as? String)
        }
        return View(sessionID: session, label: object["label"] as? String ?? "", activeWindowID: object["active_window_id"] as? String, windows: windows)
    }

    struct Block: Equatable {
        var id: String
        var windowID: String?
        var isTerminal: Bool
    }

    /// `rex block ls -s SESSION --json`.
    static func blocks(_ data: Data) -> [Block] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let blocks = object["blocks"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard let id = block["block_id"] as? String else { return nil }
            let creator = block["creator_name"] as? String ?? ""
            return Block(id: id, windowID: block["window_id"] as? String, isTerminal: creator == "com.superlogical.terminal")
        }
    }

    /// `rex ls --json`: `{"sessions":[{"session_id","label"}]}`.
    static func sessions(_ data: Data) -> [(id: String, label: String)] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]] else { return [] }
        return sessions.compactMap { session in
            guard let id = session["session_id"] as? String else { return nil }
            return (id, session["label"] as? String ?? "")
        }
    }

    static func title(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["title"] as? String
    }

    /// The foreground process's directory, from the terminal's `process` method.
    static func cwd(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (object["foreground"] as? [String: Any])?["cwd"] as? String
    }

    /// Rex names new tabs "Window 1a2b3c4d"; only a name the user gave is worth showing.
    static func userLabel(_ label: String?) -> String? {
        guard let label = RexParse.nonEmpty(label) else { return nil }
        let parts = label.split(separator: " ")
        if parts.count == 2, parts[0] == "Window", parts[1].count == 8, parts[1].allSatisfy(\.isHexDigit) { return nil }
        return label
    }
}

enum TitleCleaner {
    private static let generic: Set<String> = ["claude", "claude code", "codex", "codex cli", "zsh", "bash", "fish", "sh", "-zsh", "login"]

    /// The topic from a terminal title: no spinner glyphs, no Codex status prefix or project suffix.
    static func topic(_ raw: String?, agent: AgentKind) -> String? {
        guard var text = RexParse.nonEmpty(raw) else { return nil }
        if let range = text.range(of: "Action Required | ") { text = String(text[range.upperBound...]) }
        text = String(text.drop { !$0.isLetter && !$0.isNumber })
        if agent == .codex, let bar = text.range(of: " | ") { text = String(text[..<bar.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || generic.contains(text.lowercased()) { return nil }
        return text
    }
}

/// The current git branch of a directory, read from `.git/HEAD` without running git.
enum GitBranch {
    static func of(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        var url = URL(fileURLWithPath: directory)
        for _ in 0..<12 {
            let git = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                var head = git.appendingPathComponent("HEAD")
                if !isDirectory.boolValue,
                   let pointer = try? String(contentsOf: git, encoding: .utf8),
                   let range = pointer.range(of: "gitdir: ") {
                    // A worktree: .git is a file pointing at the real git dir.
                    let path = pointer[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    head = URL(fileURLWithPath: path, relativeTo: url).appendingPathComponent("HEAD")
                }
                guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
                return String(line.prefix(7))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}
