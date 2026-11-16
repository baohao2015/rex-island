import Foundation

/// Where Rex Island keeps its files. Shared by the app and `rexisland-bridge`.
enum RIPaths {
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RexIsland", isDirectory: true)
    }

    /// The app listens here; hooks connect to it. Kept short: a Unix socket path must fit in 104 bytes.
    static var socket: String { support.appendingPathComponent("bridge.sock").path }

    /// Hooks point at this stable copy of the bridge, so moving the app doesn't break them.
    static var installedBridge: URL { support.appendingPathComponent("bin/rexisland-bridge") }

    /// One file per Claude Code session, written by the status line wrapper.
    static var claudeStatusDir: URL { support.appendingPathComponent("claude-status", isDirectory: true) }

    /// The user's own status line, saved when Rex Island wrapped it.
    static var savedStatusLine: URL { support.appendingPathComponent("claude-statusline-original.json") }

    static func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}
