import Foundation

func installerTests() {
    let bridge = "/Users/me/Library/Application Support/RexIsland/bin/rexisland-bridge"
    // Shaped like a real settings.json: Rex's own hook, another tool's hooks, and claude-hud's status line.
    let original = json(#"""
    {"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/sh -c 'rex __internal session-start --agent claude'"}]}],
              "Stop":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/session-end.sh"}]}]},
     "statusLine":{"type":"command","command":"bash -c 'exec node hud.js'","padding":0},
     "permissions":{"defaultMode":"auto"}}
    """#)

    let installed = Installer.addingHooks(to: original, agent: .claude, bridge: bridge)
    check(Installer.hasHooks(installed, agent: .claude, bridge: bridge))
    check(!Installer.hasHooks(original, agent: .claude, bridge: bridge))
    let hooks = installed["hooks"] as? [String: Any] ?? [:]
    let stop = hooks["Stop"] as? [[String: Any]] ?? []
    equal(stop.count, 2, "appended after the user's own Stop hook")
    equal(((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String), "bash ~/.claude/hooks/session-end.sh", "existing hook keeps its position")
    let permission = ((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first ?? [:]
    equal(permission["command"] as? String, "\"\(bridge)\" hook claude")
    equal(permission["timeout"] as? Int, Wire.permissionHookTimeout)
    check(sameJSON(installed["permissions"] ?? [:], original["permissions"] ?? [:]), "unrelated settings untouched")

    check(sameJSON(Installer.addingHooks(to: installed, agent: .claude, bridge: bridge), installed), "installing twice changes nothing")
    check(sameJSON(Installer.removingHooks(from: installed), original), "removing restores the original")

    // A moved bridge: the stale entry is replaced, not duplicated.
    let moved = Installer.addingHooks(to: installed, agent: .claude, bridge: "/Applications/Rex Island.app/bridge")
    let movedStop = (moved["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    equal(movedStop.count, 2)
    check(!Installer.hasHooks(moved, agent: .claude, bridge: bridge))

    // A group that mixes the user's hook with ours keeps the user's.
    let mixed = json(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine.sh"},{"type":"command","command":"\"/x/rexisland-bridge\" hook claude"}]}]}}"#)
    check(sameJSON(Installer.removingHooks(from: mixed), json(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine.sh"}]}]}}"#)))
    check(sameJSON(Installer.removingHooks(from: [:]), [String: Any]()))

    // Status line: wrapped once, the user's saved; restored only if still ours.
    let wrapped = Installer.wrappingStatusLine(installed, bridge: bridge)
    check(wrapped.changed)
    check(sameJSON(wrapped.original ?? [:], original["statusLine"] ?? [:]))
    let line = wrapped.settings["statusLine"] as? [String: Any] ?? [:]
    equal(line["command"] as? String, "\"\(bridge)\" statusline")
    equal(line["padding"] as? Int, 0, "other status line options kept")
    let again = Installer.wrappingStatusLine(wrapped.settings, bridge: bridge)
    check(!again.changed && again.original == nil, "wrapping twice doesn't overwrite the saved original")
    let restored = Installer.restoringStatusLine(wrapped.settings, original: wrapped.original)
    check(sameJSON(restored["statusLine"] ?? [:], original["statusLine"] ?? [:]))
    var userChanged = wrapped.settings
    userChanged["statusLine"] = ["type": "command", "command": "my-new-line"]
    check(sameJSON(Installer.restoringStatusLine(userChanged, original: wrapped.original), userChanged), "a line the user changed since stays")
    let none = Installer.wrappingStatusLine([:], bridge: bridge)
    check(sameJSON(Installer.restoringStatusLine(none.settings, original: none.original), [String: Any]()), "no status line before, none after")

    // Config files: invalid JSON is an error, never overwritten; the first write keeps a backup.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rexisland-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let broken = ConfigFile(url: dir.appendingPathComponent("broken.json"))
    try? Data("{ not json".utf8).write(to: broken.url)
    check((try? broken.read()) == nil, "invalid JSON throws")
    equal(try? ConfigFile(url: dir.appendingPathComponent("missing.json")).read().count, 0)

    let file = ConfigFile(url: dir.appendingPathComponent("settings.json"))
    try? Data(#"{"a":1}"#.utf8).write(to: file.url)
    try? file.write(Installer.addingHooks(to: (try? file.read()) ?? [:], agent: .claude, bridge: bridge))
    equal(try? Data(contentsOf: file.backupURL), Data(#"{"a":1}"#.utf8), "backup holds the user's version")
    try? file.write(Installer.removingHooks(from: (try? file.read()) ?? [:]))
    equal(try? Data(contentsOf: file.backupURL), Data(#"{"a":1}"#.utf8), "a file with our entries never replaces the backup")
    check(sameJSON((try? file.read()) ?? [:], ["a": 1]))
}
