import Foundation
import Darwin

// rexisland-bridge hook <claude|codex>   agent hook: forwards the payload to Rex Island, waits for approvals
// rexisland-bridge statusline            Claude Code status line: records plan limits, then runs the user's own
// rexisland-bridge ctl list|status|decide|answer   talk to the running app from a terminal or a script
//
// Every failure path exits 0 with no output, so the agent behaves as if no hook were installed.

signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "hook": runHook(agent: arguments.count > 1 ? arguments[1] : "claude")
case "statusline": runStatusLine()
case "ctl": runCtl(Array(arguments.dropFirst()))
default:
    FileHandle.standardError.write(Data("usage: rexisland-bridge hook <claude|codex> | statusline | ctl list|decide <id> allow|deny\n".utf8))
    exit(64)
}

func runHook(agent: String) -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let env = ProcessInfo.processInfo.environment
    // Rex Island only follows agents in Rex panes; anywhere else it stays out of the way.
    guard let block = env["REX_BLOCK"], !block.isEmpty,
          let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    else { exit(0) }

    let event = payload["hook_event_name"] as? String ?? ""
    let blocking = Wire.blockingEvents.contains(event)
    var rex: [String: Any] = ["block": block]
    rex["session"] = env["REX_SESSION"]
    rex["server"] = env["REX_SERVER"]
    let envelope: [String: Any] = [
        "v": Wire.version, "type": "hook", "agent": agent, "event": event, "blocking": blocking,
        "rex": rex, "cwd": FileManager.default.currentDirectoryPath, "payload": payload,
    ]
    guard let line = SocketIO.line(envelope) else { exit(0) }
    let fd = SocketIO.connect(to: RIPaths.socket)
    guard fd >= 0 else { exit(0) }
    guard SocketIO.writeAll(fd, line), blocking else {
        close(fd)
        exit(0)
    }
    // The app closes the connection when the question is answered elsewhere; that reads as "no answer".
    guard let reply = SocketIO.readLine(fd, timeout: Wire.replyTimeout),
          let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
          let decision = object["decision"] as? [String: Any]
    else {
        close(fd)
        exit(0)
    }
    close(fd)
    let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": event, "decision": decision]]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes]) {
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

// MARK: Status line

func runStatusLine() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let status = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    record(status)
    if let command = savedStatusLineCommand(), let output = runShell(command, input: input) {
        FileHandle.standardOutput.write(output)
    } else {
        FileHandle.standardOutput.write(Data(defaultLine(status).utf8))
    }
    exit(0)
}

/// One small file per session: limits are account-wide, context and cost belong to the session.
/// Each session writes only its own file, so concurrent sessions never race on one file.
func record(_ status: [String: Any]) {
    guard let sessionID = status["session_id"] as? String,
          !sessionID.isEmpty,
          sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return }
    var snapshot: [String: Any] = ["at": Date().timeIntervalSince1970, "session_id": sessionID]
    snapshot["block"] = ProcessInfo.processInfo.environment["REX_BLOCK"]
    snapshot["rate_limits"] = status["rate_limits"]
    snapshot["model"] = (status["model"] as? [String: Any])?["display_name"]
    snapshot["context_used_percentage"] = (status["context_window"] as? [String: Any])?["used_percentage"]
    snapshot["cost_usd"] = (status["cost"] as? [String: Any])?["total_cost_usd"]
    snapshot["cwd"] = (status["workspace"] as? [String: Any])?["current_dir"] ?? status["cwd"]
    guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
    let dir = RIPaths.claudeStatusDir
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: dir.appendingPathComponent("\(sessionID).json"), options: .atomic)
}

func savedStatusLineCommand() -> String? {
    guard let data = try? Data(contentsOf: RIPaths.savedStatusLine),
          let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let original = saved["original"] as? [String: Any],
          let command = original["command"] as? String, !command.isEmpty
    else { return nil }
    return command
}

/// Runs the user's own status line with the same input; nil if it fails or takes over 5 seconds.
func runShell(_ command: String, input: Data) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? output : nil
}

/// "Opus 5.5 · ctx 34% · 5h 23% · 周 41%", used when the user had no status line of their own.
func defaultLine(_ status: [String: Any]) -> String {
    var parts: [String] = []
    if let model = (status["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    if let used = ((status["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
        parts.append("ctx \(Int(used.rounded()))%")
    }
    let limits = status["rate_limits"] as? [String: Any] ?? [:]
    for (key, label) in [("five_hour", "5h"), ("seven_day", "周")] {
        if let used = ((limits[key] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
            parts.append("\(label) \(Int(used.rounded()))%")
        }
    }
    return parts.joined(separator: " · ")
}

// MARK: Control

func runCtl(_ args: [String]) -> Never {
    let fd = SocketIO.connect(to: RIPaths.socket)
    guard fd >= 0 else {
        FileHandle.standardError.write(Data("Rex Island isn't running.\n".utf8))
        exit(1)
    }
    guard let line = SocketIO.line(["v": Wire.version, "type": "ctl", "args": args]),
          SocketIO.writeAll(fd, line),
          let reply = SocketIO.readLine(fd, timeout: 10),
          let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    else {
        close(fd)
        FileHandle.standardError.write(Data("No answer from Rex Island.\n".utf8))
        exit(1)
    }
    close(fd)
    let text = object["text"] as? String ?? ""
    let ok = object["ok"] as? Bool ?? false
    (ok ? FileHandle.standardOutput : FileHandle.standardError).write(Data((text + "\n").utf8))
    exit(ok ? 0 : 1)
}
