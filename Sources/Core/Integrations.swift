import Foundation

/// Adds and removes Rex Island's own entries in agent config files, and nothing else.
///
/// Installing is convergent: entries already in place are left exactly where they are, so running it
/// twice changes nothing. That matters for Codex, which remembers which hooks you trusted by position.
enum Installer {
    static let marker = "rexisland-bridge"

    struct HookSpec {
        var event: String
        var blocking: Bool
    }

    /// Same events for both agents: approvals, plus the prompt you sent and the agent's last reply.
    static let events: [HookSpec] = [
        HookSpec(event: "PermissionRequest", blocking: true),
        HookSpec(event: "UserPromptSubmit", blocking: false),
        HookSpec(event: "Stop", blocking: false),
    ]

    static func hookCommand(bridge: String, agent: AgentKind) -> String {
        "\"\(bridge)\" hook \(agent.rawValue)"
    }

    static func statusLineCommand(bridge: String) -> String {
        "\"\(bridge)\" statusline"
    }

    // MARK: Hooks (`{"hooks": {Event: [{"matcher"?, "hooks": [{"type","command","timeout"}]}]}}`)

    static func addingHooks(to config: [String: Any], agent: AgentKind, bridge: String) -> [String: Any] {
        let command = hookCommand(bridge: bridge, agent: agent)
        var config = removingHooks(from: config) { $0 != command }
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        for spec in events {
            var groups = hooks[spec.event] as? [[String: Any]] ?? []
            let present = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
            if !present {
                let entry: [String: Any] = [
                    "type": "command", "command": command,
                    "timeout": spec.blocking ? Wire.permissionHookTimeout : 5,
                ]
                groups.append(["hooks": [entry]])
            }
            hooks[spec.event] = groups
        }
        config["hooks"] = hooks
        return config
    }

    /// Removes Rex Island's hook entries (those `matching` their command), dropping groups and events left empty.
    static func removingHooks(from config: [String: Any], matching: (String) -> Bool = { _ in true }) -> [String: Any] {
        guard var hooks = config["hooks"] as? [String: Any] else { return config }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else { kept.append(group); continue }
                let remaining = entries.filter { entry in
                    guard let command = entry["command"] as? String, command.contains(marker) else { return true }
                    return !matching(command)
                }
                if remaining.count == entries.count { kept.append(group); continue }
                if remaining.isEmpty { continue }
                group["hooks"] = remaining
                kept.append(group)
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var config = config
        config["hooks"] = hooks.isEmpty ? nil : hooks
        return config
    }

    static func hasHooks(_ config: [String: Any], agent: AgentKind, bridge: String) -> Bool {
        let command = hookCommand(bridge: bridge, agent: agent)
        let hooks = config["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { spec in
            (hooks[spec.event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
    }

    // MARK: Claude Code status line

    static func isOurs(_ statusLine: Any?) -> Bool {
        ((statusLine as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    /// Points the status line at the bridge, which records plan limits and then runs the user's own
    /// status line with the same input. Returns the status line to save, or nil when already wrapped.
    static func wrappingStatusLine(_ settings: [String: Any], bridge: String) -> (settings: [String: Any], original: [String: Any]?, changed: Bool) {
        let current = settings["statusLine"] as? [String: Any]
        if isOurs(current) {
            var settings = settings
            var line = current ?? [:]
            line["command"] = statusLineCommand(bridge: bridge)
            settings["statusLine"] = line
            return (settings, nil, false)
        }
        var line = current ?? [:]
        line["type"] = "command"
        line["command"] = statusLineCommand(bridge: bridge)
        var settings = settings
        settings["statusLine"] = line
        return (settings, current ?? [:], true)
    }

    /// Puts the user's status line back. Leaves it alone if they changed it since.
    static func restoringStatusLine(_ settings: [String: Any], original: [String: Any]?) -> [String: Any] {
        guard isOurs(settings["statusLine"]) else { return settings }
        var settings = settings
        if let original, !original.isEmpty {
            settings["statusLine"] = original
        } else {
            settings["statusLine"] = nil
        }
        return settings
    }
}

/// A JSON config file read and written whole. Unreadable JSON is an error, never overwritten.
struct ConfigFile {
    let url: URL

    var backupURL: URL { url.appendingPathExtension("rexisland-backup") }

    func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.notAnObject(url.path)
        }
        return object
    }

    /// Writes atomically. The first time, and whenever the file has none of Rex Island's entries,
    /// keeps a copy beside it as `<name>.rexisland-backup`.
    func write(_ object: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: url),
           !String(decoding: existing, as: UTF8.self).contains(Installer.marker) {
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

enum ConfigError: LocalizedError {
    case notAnObject(String)

    var errorDescription: String? {
        switch self {
        case .notAnObject(let path): "\(path) 不是 JSON 对象，没有改动它。"
        }
    }
}
