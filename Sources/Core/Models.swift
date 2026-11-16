import Foundation

enum AgentKind: String, CaseIterable {
    case claude, codex, other

    /// From the `app` a program reports to Rex, e.g. `claude-code` or `codex`.
    init(app: String?) {
        switch app?.lowercased() {
        case "claude-code", "claude", "claude code": self = .claude
        case "codex": self = .codex
        default: self = .other
        }
    }

    /// From the agent name the hook passes to `rexisland-bridge hook <agent>`.
    init(bridgeName: String) {
        self = AgentKind(rawValue: bridgeName) ?? .other
    }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .other: "Agent"
        }
    }
}

/// What a program says it's doing, per Rex's Program Status Protocol (OSC 7501).
enum AgentState: String {
    case idle, working, done, blocked, error

    /// Rex: "Treat a value you don't know as 'idle'."
    init(report: String?) {
        self = AgentState(rawValue: report ?? "") ?? .idle
    }

    /// Lower is more urgent.
    var urgency: Int {
        switch self {
        case .blocked: 0
        case .error: 1
        case .working: 2
        case .done: 3
        case .idle: 4
        }
    }
}

/// What a blocked program waits for. Unknown values are treated as unset.
enum BlockedKind: String {
    case permission, question, auth
}

/// One pane's status record, as Rex reports it.
struct RexStatus: Equatable {
    var state: AgentState
    var kind: BlockedKind?
    var msg: String?
    var app: String?
    var progress: Int?
    var updatedAt: Date
}

/// A Rex terminal pane. Panes without a status record aren't running an agent.
struct Pane: Identifiable, Equatable {
    let id: String
    var sessionID: String
    var sessionLabel: String
    var windowID: String?
    /// Nil when the tab still has Rex's default "Window 1a2b3c4d" name.
    var windowLabel: String?
    /// The conversation topic, cleaned from the terminal title.
    var title: String?
    var cwd: String?
    var branch: String?
    var status: RexStatus?
    var stateSince: Date
    /// From the agent's hooks: the last prompt you sent and the last thing it said.
    var lastPrompt: String?
    var lastMessage: String?

    var agent: AgentKind { AgentKind(app: status?.app) }
    var state: AgentState { status?.state ?? .idle }
    var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    init(id: String, sessionID: String, sessionLabel: String = "", windowID: String? = nil, windowLabel: String? = nil,
         title: String? = nil, cwd: String? = nil, branch: String? = nil, status: RexStatus? = nil, stateSince: Date = Date(),
         lastPrompt: String? = nil, lastMessage: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.sessionLabel = sessionLabel
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.title = title
        self.cwd = cwd
        self.branch = branch
        self.status = status
        self.stateSince = stateSince
        self.lastPrompt = lastPrompt
        self.lastMessage = lastMessage
    }
}

/// A request an agent is waiting on, delivered by its PermissionRequest hook and answered from the notch.
struct Decision: Identifiable, Equatable {
    let id: String
    let agent: AgentKind
    let blockID: String
    let sessionID: String?
    let createdAt: Date
    let content: Content
    /// The tool's raw input, needed to answer questions (`updatedInput`).
    let toolInput: Data
    /// One of the agent's own "allow and remember" options, when it offered one.
    let suggestion: Suggestion?
    /// Rex has reported this pane as blocked since the request arrived. When the pane stops being
    /// blocked, the request was answered in the terminal and the card is out of date.
    var sawBlocked = false

    enum Content: Equatable {
        case permission(Permission)
        case questions([Question])
        case plan(String)
    }

    struct Permission: Equatable {
        var tool: String
        /// "运行命令", "修改文件", …
        var action: String
        /// The command, path or URL, shown monospaced.
        var subject: String
        /// The agent's own description of what the call is for.
        var detail: String?
        var diff: Diff?
        /// Why the command looks dangerous, if it does.
        var risk: String?
    }

    struct Diff: Equatable {
        var removed: [String]
        var added: [String]
    }

    struct Question: Equatable {
        var header: String?
        var text: String
        var options: [Option]
        var multiSelect: Bool
    }

    struct Option: Equatable, Hashable {
        var label: String
        var detail: String?
    }

    struct Suggestion: Equatable {
        var label: String
        /// The agent's own PermissionUpdate object, sent back verbatim.
        var raw: Data
    }
}

/// How the user answered a decision.
enum Resolution: Equatable {
    case allow
    /// Allow, and apply the agent's suggested permission update.
    case allowRemembering
    case deny(String?)
    /// One entry per question: the chosen option labels, or a single typed answer.
    case answers([[String]])
    /// Claude Code ignores a hook's "allow" for its plan prompt, so this one is answered in the pane.
    case approvePlan(autoAccept: Bool)
    case revisePlan(String)
}

/// The face's overall mood, most urgent first.
enum Mood: Int, Comparable {
    case needsYou, error, working, finished, idle, asleep

    static func < (lhs: Mood, rhs: Mood) -> Bool { lhs.rawValue < rhs.rawValue }
}
