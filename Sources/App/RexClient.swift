import AppKit
import Foundation

/// Talks to Rex through its CLI. Rex is in beta and its socket protocol is private; the CLI is the stable door.
final class RexCLI {
    let executable: URL

    init(executable: URL) {
        self.executable = executable
    }

    /// Finds `rex`: Rex's own install, common bin dirs, then the login shell's PATH.
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
            "/opt/homebrew/bin/rex", "/usr/local/bin/rex", "\(home)/.local/bin/rex",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v rex"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    /// Runs `rex ARGS`; stdout on exit status 0, nil otherwise or after `timeout`.
    func run(_ args: [String], timeout: TimeInterval = 8) async -> Data? {
        guard let output = await execute(args, timeout: timeout), output.status == 0 else { return nil }
        return output.stdout
    }

    /// Runs `rex ARGS` and keeps its exit status and error text. Nil if it couldn't start.
    func execute(_ args: [String], timeout: TimeInterval = 8) async -> Output? {
        let executable = executable
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                var environment = ProcessInfo.processInfo.environment
                // Never inherit a pane's identity from the shell that launched the app.
                for key in ["REX_SESSION", "REX_BLOCK", "REX_CLIENT"] { environment[key] = nil }
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                // Drain stderr on its own thread so a full pipe can never stall stdout.
                let errors = ErrorText()
                let drained = DispatchGroup()
                drained.enter()
                DispatchQueue.global().async {
                    errors.data = err.fileHandleForReading.readDataToEndOfFile()
                    drained.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                drained.wait()
                watchdog.cancel()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: data,
                                                      stderr: String(decoding: errors.data, as: UTF8.self)))
            }
        }
    }

    private final class ErrorText: @unchecked Sendable {
        var data = Data()
    }

    func call(_ method: String, session: String, params: [String: Any] = [:]) async -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: body, encoding: .utf8) else { return nil }
        return await run(["api", "call", "-s", session, method, text])
    }

    func blockMethod(_ method: String, session: String, block: String) async -> Data? {
        await call("block.method", session: session, params: ["block_id": block, "method": method])
    }

    func version() async -> String? {
        guard let data = await run(["version"]) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }

    // MARK: Snapshot

    struct Snapshot {
        var sessionIDs: Set<String>
        var panes: [Pane]
        var views: [String: RexLayout.View]
    }

    /// Reads sessions, their tabs and panes, and every agent pane's status, title and directory.
    /// Nil if Rex can't be reached; `only` limits the read to some sessions.
    func snapshot(only: Set<String>? = nil) async -> Snapshot? {
        guard let list = await run(["ls", "--json"]) else { return nil }
        let sessions = RexLayout.sessions(list).filter { only?.contains($0.id) ?? true }
        var panes: [Pane] = []
        var views: [String: RexLayout.View] = [:]
        await withTaskGroup(of: (RexLayout.View?, [Pane]).self) { group in
            for session in sessions {
                group.addTask { await self.read(session: session.id, label: session.label) }
            }
            for await (view, sessionPanes) in group {
                if let view { views[view.sessionID] = view }
                panes += sessionPanes
            }
        }
        return Snapshot(sessionIDs: Set(sessions.map(\.id)), panes: panes, views: views)
    }

    private func read(session: String, label: String) async -> (RexLayout.View?, [Pane]) {
        async let viewData = call("session.view", session: session)
        async let blockData = run(["block", "ls", "-s", session, "--json"])
        let view = await viewData.flatMap(RexLayout.view)
        let blocks = await blockData.map(RexLayout.blocks) ?? []
        let windows = Dictionary(uniqueKeysWithValues: (view?.windows ?? []).map { ($0.id, $0) })
        var panes: [Pane] = []
        await withTaskGroup(of: Pane?.self) { group in
            for block in blocks where block.isTerminal {
                group.addTask {
                    guard let status = await self.blockMethod("program_status", session: session, block: block.id)
                        .flatMap(RexParse.paneStatus(methodResult:)) else { return nil }
                    async let titleData = self.blockMethod("title", session: session, block: block.id)
                    async let processData = self.blockMethod("process", session: session, block: block.id)
                    let cwd = await processData.flatMap(RexLayout.cwd)
                    let title = await titleData.flatMap(RexLayout.title)
                    let agent = AgentKind(app: status.app)
                    return Pane(id: block.id, sessionID: session, sessionLabel: view?.label ?? label,
                                windowID: block.windowID, windowLabel: block.windowID.flatMap { windows[$0]?.label },
                                title: TitleCleaner.topic(title, agent: agent), cwd: cwd, branch: GitBranch.of(cwd),
                                status: status, stateSince: status.updatedAt)
                }
            }
            for await pane in group { if let pane { panes.append(pane) } }
        }
        return (view, panes)
    }

    // MARK: Navigation

    enum RevealOutcome {
        case shown
        /// The Rex app refuses actions from other programs until Remote Control is on in its settings.
        case needsRemoteControl
        /// No Rex app is connected on this Mac.
        case noApp
    }

    /// Shows a pane in the Rex app on this Mac. Focusing the pane only changes the server's view; which
    /// tab the app shows is the app's own state, so the app is asked to select that session and tab.
    func reveal(session: String, block: String, window: String?) async -> RevealOutcome {
        _ = await call("session.focus_block", session: session, params: ["session_id": session, "block_id": block])
        guard let client = await localAppClient() else { return .noApp }
        var args = ["-C", client, "do", "session.select", "session_id=\(session)"]
        if let window { args.append("window_id=\(window)") }
        if let output = await execute(args), output.status != 0, output.stderr.contains("not accepting actions") {
            return .needsRemoteControl
        }
        _ = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: RexCLI.appBundleID).first?.activate()
        }
        return .shown
    }

    /// Rex's settings page with the Remote Control switch.
    static let serverSettingsURL = URL(string: "rex://settings/server")!

    /// Presses a numbered menu option in a pane, only if Rex says the pane is blocked on a prompt whose
    /// message mentions `subject` and the screen shows the option. True once the pane has moved on.
    func pressMenuOption(session: String, block: String, matching needles: [String], whileWaitingOn subject: String) async -> Bool {
        func waiting() async -> Bool {
            guard let status = await blockMethod("program_status", session: session, block: block).flatMap(RexParse.paneStatus(methodResult:)) else { return false }
            return status.state == .blocked && (status.msg ?? "").lowercased().contains(subject)
        }
        guard await waiting(),
              let screen = await run(["capture", "-s", session, "-b", block, "--trim"]).map({ String(decoding: $0, as: UTF8.self) }),
              let number = TerminalMenu.option(in: screen, matching: needles),
              await run(["send-key", "-s", session, "-b", block, String(number)]) != nil else { return false }
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await !waiting() { return true }
        }
        return false
    }

    static let appBundleID = "com.superlogical.rex"

    /// The Rex app connected from this Mac (over the local socket).
    func localAppClient() async -> String? {
        guard let data = await run(["client", "ls", "--json"]),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let clients = object["clients"] as? [[String: Any]] else { return nil }
        let apps = clients.filter { client in
            let info = client["info"] as? [String: Any]
            let principal = client["principal"] as? [String: Any]
            return info?["kind"] as? String == "app" && info?["platform"] as? String == "macos"
                && principal?["transport"] as? String == "unix"
                && (client["connection_state"] as? String ?? "connected") == "connected"
        }
        return (apps.last ?? apps.first)?["client_id"] as? String
    }

    /// Whether the user is looking at this pane right now: Rex is frontmost and the pane has focus
    /// in its session's active tab. (Which session the app shows isn't exposed; one usually is.)
    func isWatching(session: String, block: String) async -> Bool {
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == RexCLI.appBundleID }
        guard frontmost, let view = await call("session.view", session: session).flatMap(RexLayout.view) else { return false }
        return view.windows.first { $0.id == view.activeWindowID }?.focusedBlockID == block
    }
}

/// `rex events --all --json`, restarted with backoff whenever it ends.
final class RexEventStream {
    private let cli: RexCLI
    private var process: Process?
    private var buffer = Data()
    private var retryDelay: TimeInterval = 1
    private var stopped = false
    private let queue = DispatchQueue(label: "rexisland.events")

    /// Called on the main queue.
    var onEvent: (RexEvent) -> Void = { _ in }
    /// Called on the main queue each time the stream (re)starts, so a fresh snapshot can be read.
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}

    init(cli: RexCLI) {
        self.cli = cli
    }

    func start() {
        queue.async { self.launch() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.process?.terminate()
        }
    }

    private func launch() {
        guard !stopped else { return }
        let process = Process()
        process.executableURL = cli.executable
        process.arguments = ["events", "--all", "--json"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["REX_SESSION", "REX_BLOCK", "REX_CLIENT"] { environment[key] = nil }
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            DispatchQueue.main.async { self.onStop() }
            self.queue.asyncAfter(deadline: .now() + self.retryDelay) {
                self.retryDelay = min(self.retryDelay * 2, 30)
                self.buffer = Data()
                self.launch()
            }
        }
        do {
            try process.run()
            self.process = process
            DispatchQueue.main.async { self.onStart() }
        } catch {
            queue.asyncAfter(deadline: .now() + retryDelay) {
                self.retryDelay = min(self.retryDelay * 2, 30)
                self.launch()
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            retryDelay = 1
            let event = RexEvent(line: line)
            if event != .ignored {
                DispatchQueue.main.async { self.onEvent(event) }
            }
        }
    }
}
