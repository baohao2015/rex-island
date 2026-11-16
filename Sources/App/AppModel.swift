import AppKit
import Combine
import Foundation

/// The app's state and everything that changes it. Views read it; only these methods write it.
@MainActor
final class AppModel: ObservableObject {
    enum RexHealth: Equatable {
        case connecting
        case connected(version: String?)
        case unreachable
        case missing
    }

    struct IntegrationStatus: Equatable {
        var claudeHooks = false
        var claudeStatusLine = false
        var codexHooks = false
        var claudePresent = false
        var codexPresent = false
        var lastError: String?
    }

    /// Something that deserves a moment in the notch.
    enum Alert: Equatable {
        case attention(String)
        case finished(String)
    }

    @Published private(set) var board = Board()
    @Published private(set) var claudeUsage: ProviderUsage?
    @Published private(set) var codexUsage: ProviderUsage?
    /// Context and cost per pane, from the Claude Code status line.
    @Published private(set) var claudeSessions: [String: ClaudeSessionStatus] = [:]
    @Published private(set) var rexHealth = RexHealth.connecting
    @Published private(set) var integrations = IntegrationStatus()
    /// The last jump to a pane failed because Rex's Remote Control is off.
    @Published var revealNeedsRemoteControl = false

    struct LimitWarning: Equatable {
        var provider: AgentKind
        var window: LimitWindow
    }

    /// The fullest plan window at 80% or more, shown as a ring beside the notch.
    var limitWarning: LimitWarning? {
        [claudeUsage, codexUsage].compactMap { $0 }
            .flatMap { usage in usage.windows.map { LimitWarning(provider: usage.provider, window: $0) } }
            .filter { $0.window.usedPercent >= 80 }
            .max { $0.window.usedPercent < $1.window.usedPercent }
    }

    var soundsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds"); objectWillChange.send() }
    }

    /// Set by the notch controller.
    var onAlert: (Alert) -> Void = { _ in }
    var onTogglePanel: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onResolved: (Resolution) -> Void = { _ in }

    private var claudePlan: String?
    private var rex: RexCLI?
    private var stream: RexEventStream?
    private let server = BridgeServer(path: RIPaths.socket)
    private var connections: [String: BridgeConnection] = [:]
    private var pendingSessionReads = Set<String>()
    private var timers: [Timer] = []
    private let usageQueue = DispatchQueue(label: "rexisland.usage", qos: .utility)
    private let scanner: UsageScanner
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        scanner = UsageScanner(claudeRoot: home.appendingPathComponent(".claude/projects"),
                               codexRoot: home.appendingPathComponent(".codex/sessions"))
    }

    // MARK: Lifecycle

    func start() {
        installBridgeCopy()
        refreshIntegrations()
        server.onHook = { [weak self] envelope, connection in self?.handleHook(envelope, connection: connection) }
        server.onControl = { [weak self] args, reply in self?.handleControl(args, reply: reply) }
        do { try server.start() } catch {
            integrations.lastError = "无法监听 \(RIPaths.socket)：\(error.localizedDescription)"
        }
        connectRex()
        refreshUsage(scanTranscripts: true)
        timers = [
            Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshUsage(scanTranscripts: false) } },
            Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshUsage(scanTranscripts: true) } },
            // A safety net for anything the event stream missed.
            Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readRex(only: nil) } },
        ]
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
    }

    func stop() {
        stream?.stop()
        server.stop()
        connections.values.forEach { $0.cancel() }
        connections = [:]
    }

    private func connectRex() {
        Task.detached(priority: .userInitiated) {
            let located = RexCLI.locate()
            await MainActor.run {
                guard let located else {
                    self.rexHealth = .missing
                    return
                }
                let cli = RexCLI(executable: located)
                self.rex = cli
                let stream = RexEventStream(cli: cli)
                stream.onEvent = { [weak self] event in self?.handle(event) }
                stream.onStart = { [weak self] in self?.readRex(only: nil) }
                stream.onStop = { [weak self] in
                    if self?.rexHealth != .missing { self?.rexHealth = .unreachable }
                }
                self.stream = stream
                stream.start()
            }
        }
    }

    // MARK: Rex

    private func handle(_ event: RexEvent) {
        switch event {
        case .status(let session, let block, let recordID, let record):
            guard recordID.isEmpty else {
                // A child record: re-read the pane so the root-or-most-urgent rule applies.
                readPane(session: session, block: block)
                return
            }
            let known = board.panes[block] != nil
            apply(record, block: block, session: session)
            if !known { readRex(only: [session]) }
        case .statusRemoved(let session, let block):
            readPane(session: session, block: block)
        case .title(_, let block, let title):
            board.updateTitle(title, block: block)
        case .process(let session, let block):
            guard board.panes[block]?.status != nil, let rex else { return }
            Task {
                let cwd = await rex.blockMethod("process", session: session, block: block).flatMap(RexLayout.cwd)
                board.updateLocation(cwd: cwd, branch: GitBranch.of(cwd), block: block)
            }
        case .layout(let session):
            readRex(only: [session])
        case .sessions:
            readRex(only: nil)
        case .ignored:
            break
        }
    }

    private func apply(_ status: RexStatus?, block: String, session: String) {
        let before = board.panes[block]?.state
        retire(board.applyStatus(status, block: block, session: session))
        let after = board.panes[block]?.state
        guard before != after, let after else { return }
        if after == .blocked, !board.decisions.contains(where: { $0.blockID == block }) {
            // Give the hook a moment: if a card arrives, it gets the alert instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.board.panes[block]?.state == .blocked,
                      !self.board.decisions.contains(where: { $0.blockID == block }) else { return }
                self.alert(.attention("p:" + block), block: block)
            }
        } else if after == .done, before == .working {
            alert(.finished(block), block: block)
        }
    }

    private func readPane(session: String, block: String) {
        guard let rex else { return }
        Task {
            let status = await rex.blockMethod("program_status", session: session, block: block).flatMap(RexParse.paneStatus(methodResult:))
            apply(status, block: block, session: session)
        }
    }

    /// Re-reads some sessions (or all), coalescing requests that arrive while a read is running.
    func readRex(only sessions: Set<String>?) {
        guard let rex, !demo else { return }
        let key = sessions.map { $0.sorted().joined(separator: ",") } ?? "*"
        guard pendingSessionReads.insert(key).inserted else { return }
        Task {
            defer { pendingSessionReads.remove(key) }
            guard let snapshot = await rex.snapshot(only: sessions) else {
                rexHealth = .unreachable
                return
            }
            if case .connected = rexHealth {} else {
                let version = await rex.version()
                rexHealth = .connected(version: version)
            }
            let before = Dictionary(uniqueKeysWithValues: board.panes.map { ($0.key, $0.value.state) })
            retire(board.replacePanes(snapshot.panes, inSessions: sessions ?? snapshot.sessionIDs))
            if sessions == nil { retire(board.keepSessions(snapshot.sessionIDs)) }
            for pane in snapshot.panes where pane.state == .blocked && before[pane.id] != .blocked
                && !board.decisions.contains(where: { $0.blockID == pane.id }) {
                alert(.attention("p:" + pane.id), block: pane.id)
            }
        }
    }

    // MARK: Hooks

    private func handleHook(_ envelope: [String: Any], connection: BridgeConnection?) {
        guard let rexInfo = envelope["rex"] as? [String: Any], let block = rexInfo["block"] as? String else {
            connection?.cancel()
            return
        }
        let session = rexInfo["session"] as? String ?? board.panes[block]?.sessionID ?? ""
        let agent = AgentKind(bridgeName: envelope["agent"] as? String ?? "")
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        if board.panes[block] == nil, !session.isEmpty { readRex(only: [session]) }

        switch envelope["event"] as? String {
        case "PermissionRequest":
            guard let connection else { return }
            let decision = DecisionParser.decision(id: UUID().uuidString, agent: agent, block: block, session: session, payload: payload)
            connections[decision.id] = connection
            connection.onHangUp = { [weak self] in
                guard let self else { return }
                self.connections[decision.id] = nil
                self.board.removeDecision(decision.id)
            }
            connection.watchForHangUp()
            board.addDecision(decision)
            alert(.attention("d:" + decision.id), block: block)
        case "UserPromptSubmit":
            board.note(prompt: payload["prompt"] as? String, block: block, session: session)
        case "Stop":
            board.note(message: payload["last_assistant_message"] as? String, block: block, session: session)
        default:
            connection?.cancel()
        }
    }

    /// Sends the answer to the waiting hook and drops the card.
    func resolve(_ id: String, _ resolution: Resolution) {
        if case .approvePlan(let autoAccept) = resolution, let decision = board.decision(id), decision.agent == .claude {
            approvePlanInPane(decision, autoAccept: autoAccept)
            return
        }
        guard let decision = board.removeDecision(id) else { return }
        connections.removeValue(forKey: id)?.send(["decision": DecisionReply.object(for: decision, resolution)])
        onResolved(resolution)
    }

    /// Claude Code keeps its plan prompt open whatever the hook answers, so the choice is made in the
    /// pane itself: the menu option is read off the screen and pressed only while Rex still shows that
    /// prompt. Anything unexpected falls back to showing the pane.
    private func approvePlanInPane(_ decision: Decision, autoAccept: Bool) {
        guard let rex, let pane = board.panes[decision.blockID] else { return }
        let needles = autoAccept ? ["auto-accept", "auto mode"] : ["manually approve"]
        Task {
            let pressed = await rex.pressMenuOption(session: pane.sessionID, block: pane.id, matching: needles, whileWaitingOn: "plan")
            if pressed {
                board.removeDecision(decision.id)
                connections.removeValue(forKey: decision.id)?.cancel()
                onResolved(.approvePlan(autoAccept: autoAccept))
            } else {
                await answerInTerminal(decision.id)
            }
        }
    }

    /// Lets the agent ask in the terminal instead, and shows that pane. True if Rex now shows it.
    @discardableResult
    func answerInTerminal(_ id: String) async -> Bool {
        guard let decision = board.removeDecision(id) else { return false }
        connections.removeValue(forKey: id)?.cancel()
        return await reveal(block: decision.blockID)
    }

    private func retire(_ ids: [String]) {
        for id in ids { connections.removeValue(forKey: id)?.cancel() }
    }

    private func alert(_ alert: Alert, block: String) {
        guard !demo else { return }
        guard let rex, let session = board.panes[block]?.sessionID else {
            deliver(alert)
            return
        }
        Task {
            // No ping for the pane you're already looking at.
            if await rex.isWatching(session: session, block: block) { return }
            deliver(alert)
        }
    }

    private func deliver(_ alert: Alert) {
        if case .attention = alert, soundsEnabled { NSSound(named: "Tink")?.play() }
        onAlert(alert)
    }

    /// Switches the Rex app to a pane. True if it did; false leaves the panel open to explain why.
    func reveal(block: String) async -> Bool {
        guard let rex, let pane = board.panes[block] else { return false }
        switch await rex.reveal(session: pane.sessionID, block: pane.id, window: pane.windowID) {
        case .shown:
            revealNeedsRemoteControl = false
            return true
        case .needsRemoteControl:
            revealNeedsRemoteControl = true
            return false
        case .noApp:
            return false
        }
    }

    func openRexServerSettings() {
        NSWorkspace.shared.open(RexCLI.serverSettingsURL)
    }

    // MARK: Control (`rexisland-bridge ctl`)

    private func handleControl(_ args: [String], reply: @escaping ([String: Any]) -> Void) {
        switch args.first {
        case "list":
            let lines = board.decisions.map { decision -> String in
                let pane = board.panes[decision.blockID]
                return "\(decision.id.prefix(8))  \(decision.agent.displayName)  \(pane?.project ?? "-")  \(DecisionText.summary(decision))"
            }
            reply(["ok": true, "text": lines.isEmpty ? "没有等你处理的请求" : lines.joined(separator: "\n")])
        case "open" where args.count >= 2:
            // Same path as clicking a row: rexisland-bridge ctl open <block id or its end>
            let matches = board.agentPanes.filter { $0.id.hasSuffix(args[1]) || $0.id.hasPrefix(args[1]) }
            guard matches.count == 1, let pane = matches.first else {
                reply(["ok": false, "text": matches.isEmpty ? "找不到面板 \(args[1])" : "\(args[1]) 匹配多个面板"])
                return
            }
            Task {
                let shown = await reveal(block: pane.id)
                if !shown, revealNeedsRemoteControl { onTogglePanel() }
                reply(["ok": shown, "text": shown ? "已在 Rex 里打开 \(PaneText.title(pane))" : revealNeedsRemoteControl ? "Rex 没打开 Remote Control" : "没有找到 Rex App"])
            }
        case "settings":
            onOpenSettings()
            reply(["ok": true, "text": "已打开设置"])
        case "panel":
            onTogglePanel()
            reply(["ok": true, "text": "已切换面板"])
        case "status":
            var lines = board.agentPanes.map { pane -> String in
                let note = [pane.lastPrompt.map { "prompt: \(Format.oneLine($0, limit: 60) ?? "")" },
                            pane.lastMessage.map { "reply: \(Format.oneLine($0, limit: 60) ?? "")" }].compactMap { $0 }
                return "\(pane.state.rawValue)\t\(pane.agent.displayName)\t\(PaneText.title(pane))\t\(PaneText.place(pane))"
                    + (note.isEmpty ? "" : "\t" + note.joined(separator: " | "))
            }
            for usage in [claudeUsage, codexUsage].compactMap({ $0 }) {
                let windows = usage.windows.map { "\($0.span.rawValue) \(Format.percent($0.usedPercent))" }.joined(separator: ", ")
                lines.append("usage\t\(usage.provider.displayName)\t\(windows.isEmpty ? "-" : windows)\ttoday \(Format.tokens(usage.today.total))")
            }
            lines.append("rex\t\(rexHealth)")
            reply(["ok": true, "text": lines.joined(separator: "\n")])
        case "decide" where args.count >= 3:
            let matches = board.decisions.filter { $0.id.hasPrefix(args[1]) }
            guard matches.count == 1, let decision = matches.first else {
                reply(["ok": false, "text": matches.isEmpty ? "找不到 \(args[1])" : "\(args[1]) 匹配多个请求"])
                return
            }
            let reason = args.count > 3 ? args[3...].joined(separator: " ") : nil
            let isPlan = { if case .plan = decision.content { return true } else { return false } }()
            switch args[2] {
            case "allow": resolve(decision.id, isPlan ? .approvePlan(autoAccept: false) : .allow)
            case "deny": resolve(decision.id, isPlan ? .revisePlan(reason ?? "") : .deny(reason))
            default:
                reply(["ok": false, "text": "用 allow 或 deny"])
                return
            }
            reply(["ok": true, "text": "已处理 \(decision.id.prefix(8))"])
        case "answer" where args.count >= 3:
            // ctl answer <id> <answer for question 1> [<answer for question 2> …]; "a, b" picks several.
            let matches = board.decisions.filter { $0.id.hasPrefix(args[1]) }
            guard matches.count == 1, let decision = matches.first, case .questions(let questions) = decision.content,
                  args.count - 2 == questions.count else {
                reply(["ok": false, "text": "找不到这个提问，或答案个数和问题个数不一致"])
                return
            }
            let answers = args[2...].map { $0.components(separatedBy: ", ").filter { !$0.isEmpty } }
            resolve(decision.id, .answers(Array(answers)))
            reply(["ok": true, "text": "已回答 \(decision.id.prefix(8))"])
        default:
            reply(["ok": false, "text": "用法：ctl list | ctl status | ctl open <面板> | ctl panel | ctl settings | ctl decide <id> allow|deny [理由] | ctl answer <id> <答案>…"])
        }
    }

    // MARK: Usage

    private func refreshUsage(scanTranscripts: Bool) {
        guard !demo else { return }
        let scanner = scanner
        let statusDir = RIPaths.claudeStatusDir
        let claudeConfig = home.appendingPathComponent(".claude.json")
        usageQueue.async {
            if scanTranscripts { scanner.scan() }
            // ~/.claude.json can be megabytes; read it with the slow scan only.
            let plan: String?? = scanTranscripts ? .some((try? Data(contentsOf: claudeConfig)).flatMap(ClaudeAccount.plan(fromConfig:))) : .none
            let sessions = ClaudeSessionStatus.loadAll(in: statusDir)
            let limits = ClaudeSessionStatus.currentLimits(sessions)
            let claudeToday = scanner.claudeToday, codexToday = scanner.codexToday
            let codexLimits = scanner.codexLimits, codexPlan = scanner.codexPlan
            DispatchQueue.main.async {
                var byBlock: [String: ClaudeSessionStatus] = [:]
                for session in sessions {
                    guard let block = session.block else { continue }
                    if byBlock[block].map({ $0.at < session.at }) ?? true { byBlock[block] = session }
                }
                if self.claudeSessions != byBlock { self.claudeSessions = byBlock }
                if case .some(let plan) = plan { self.claudePlan = plan }
                let claude = ProviderUsage(provider: .claude, plan: self.claudePlan, windows: limits, today: claudeToday)
                let codex = ProviderUsage(provider: .codex, plan: codexPlan, windows: codexLimits, today: codexToday)
                if self.claudeUsage != claude { self.claudeUsage = claude }
                if self.codexUsage != codex { self.codexUsage = codex }
            }
        }
    }

    // MARK: Integrations

    private var bridgePath: String { RIPaths.installedBridge.path }
    private var claudeSettings: ConfigFile { ConfigFile(url: home.appendingPathComponent(".claude/settings.json")) }
    private var codexHooks: ConfigFile { ConfigFile(url: home.appendingPathComponent(".codex/hooks.json")) }

    /// Hooks call a stable copy of the bridge; refresh it from the app bundle when it differs.
    private func installBridgeCopy() {
        guard !demo else { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rexisland-bridge")
        guard let fresh = try? Data(contentsOf: bundled) else { return }
        let target = RIPaths.installedBridge
        if (try? Data(contentsOf: target)) == fresh { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.appendingPathExtension("new")
        try? fm.removeItem(at: temporary)
        do {
            try fresh.write(to: temporary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
        } catch {
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: temporary, to: target) }
        }
    }

    func refreshIntegrations() {
        var status = IntegrationStatus(lastError: integrations.lastError)
        status.claudePresent = FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
        status.codexPresent = FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
        if let settings = try? claudeSettings.read() {
            status.claudeHooks = Installer.hasHooks(settings, agent: .claude, bridge: bridgePath)
            status.claudeStatusLine = Installer.isOurs(settings["statusLine"])
        }
        if let hooks = try? codexHooks.read() {
            status.codexHooks = Installer.hasHooks(hooks, agent: .codex, bridge: bridgePath)
        }
        integrations = status
    }

    func setClaudeHooks(_ on: Bool) {
        edit(claudeSettings) { config in
            on ? Installer.addingHooks(to: config, agent: .claude, bridge: self.bridgePath) : Installer.removingHooks(from: config)
        }
    }

    func setCodexHooks(_ on: Bool) {
        edit(codexHooks) { config in
            on ? Installer.addingHooks(to: config, agent: .codex, bridge: self.bridgePath) : Installer.removingHooks(from: config)
        }
    }

    func setClaudeStatusLine(_ on: Bool) {
        edit(claudeSettings) { config in
            if on {
                let wrapped = Installer.wrappingStatusLine(config, bridge: self.bridgePath)
                if let original = wrapped.original {
                    let saved = try JSONSerialization.data(withJSONObject: ["original": original])
                    RIPaths.ensureSupportDirectory()
                    try saved.write(to: RIPaths.savedStatusLine, options: .atomic)
                }
                return wrapped.settings
            }
            let saved = (try? Data(contentsOf: RIPaths.savedStatusLine))
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["original"] as? [String: Any]
            return Installer.restoringStatusLine(config, original: saved)
        }
    }

    private func edit(_ file: ConfigFile, _ change: ([String: Any]) throws -> [String: Any]) {
        do {
            let current = try file.read()
            let updated = try change(current)
            try file.write(updated)
            integrations.lastError = nil
        } catch {
            integrations.lastError = error.localizedDescription
        }
        refreshIntegrations()
    }

    // MARK: Demo data (screenshots)

    func loadDemo(_ build: (inout Board) -> Void, claude: ProviderUsage?, codex: ProviderUsage?, sessions: [String: ClaudeSessionStatus] = [:]) {
        var board = Board()
        build(&board)
        self.board = board
        claudeUsage = claude
        codexUsage = codex
        claudeSessions = sessions
        rexHealth = .connected(version: "rex 0.1.0-preview.14")
        integrations = IntegrationStatus(claudeHooks: true, claudeStatusLine: true, codexHooks: true, claudePresent: true, codexPresent: true)
    }

    func disconnectForDemo() {
        integrations = IntegrationStatus(claudePresent: true, codexPresent: true)
        claudeUsage = nil
    }
}

/// Short words for a decision, shared by the notch and `ctl list`.
enum DecisionText {
    static func summary(_ decision: Decision) -> String {
        switch decision.content {
        case .permission(let permission): "\(permission.action)：\(Format.oneLine(permission.subject, limit: 80) ?? "")"
        case .questions(let questions): "问你：\(Format.oneLine(questions.first?.text, limit: 80) ?? "")"
        case .plan: "计划写好了，等你批准"
        }
    }

    /// The playful headline above a request. The buttons stay literal.
    static func headline(_ decision: Decision) -> String {
        switch decision.content {
        case .permission(let permission): permission.risk == nil ? "人类，签个字" : "这个要你亲自看看"
        case .questions: "问你个事"
        case .plan: "计划写好了"
        }
    }

    static func waiting(_ pane: Pane) -> String {
        switch pane.status?.kind {
        case .permission: "在等你授权"
        case .question: "有问题问你"
        case .auth: "在等你登录"
        case nil: "在等你"
        }
    }
}
