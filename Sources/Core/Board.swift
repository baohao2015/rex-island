import Foundation

/// Everything the notch shows, kept as one value so every change goes through these rules:
///
/// - Rex owns pane state (working, blocked, done…). Hooks own decision content.
/// - A decision lives while its hook waits. It ends when it's answered here, when its hook goes away,
///   or when Rex shows its pane is no longer blocked — that means it was answered in the terminal.
///   Claude Code doesn't stop the hook in that case, so Rex's status is the only signal.
struct Board: Equatable {
    private(set) var panes: [String: Pane] = [:]
    /// Oldest first, which is the order agents ask in.
    private(set) var decisions: [Decision] = []

    // MARK: Rex

    /// Applies a fresh read of some sessions. Panes in those sessions that Rex no longer lists are dropped,
    /// keeping what hooks told us about panes that remain. Returns decisions whose pane is gone.
    mutating func replacePanes(_ fresh: [Pane], inSessions sessions: Set<String>, now: Date = Date()) -> [String] {
        let freshIDs = Set(fresh.map(\.id))
        for (id, pane) in panes where sessions.contains(pane.sessionID) && !freshIDs.contains(id) {
            panes[id] = nil
        }
        var stale: [String] = []
        for pane in fresh {
            var merged = pane
            if let old = panes[pane.id] {
                merged.lastPrompt = pane.lastPrompt ?? old.lastPrompt
                merged.lastMessage = pane.lastMessage ?? old.lastMessage
                merged.stateSince = old.stateSince
                merged.status = old.status
            }
            panes[pane.id] = merged
            // Status goes through the same rules as a live report, so a snapshot can retire stale cards too.
            stale += applyStatus(pane.status, block: pane.id, session: pane.sessionID, now: now)
        }
        let live = Set(panes.keys)
        return stale + dropDecisions { !live.contains($0.blockID) }
    }

    /// Drops every pane of sessions that no longer exist.
    mutating func keepSessions(_ sessions: Set<String>) -> [String] {
        panes = panes.filter { sessions.contains($0.value.sessionID) }
        let live = Set(panes.keys)
        return dropDecisions { !live.contains($0.blockID) }
    }

    /// A status report for one pane. Returns decisions that are now out of date.
    mutating func applyStatus(_ status: RexStatus?, block: String, session: String, now: Date = Date()) -> [String] {
        var pane = panes[block] ?? Pane(id: block, sessionID: session, stateSince: now)
        let before = pane.status
        if before?.state != status?.state { pane.stateSince = now }
        pane.status = status
        panes[block] = pane

        guard let after = status else {
            // The agent stopped reporting (it exited): nothing in this pane is waiting anymore.
            return dropDecisions { $0.blockID == block }
        }
        var stale: [String] = []
        // Leaving "blocked", or moving on to a different prompt, means the prompt shown was answered
        // in the terminal: retire the oldest request it showed. Requests queued behind it in the same
        // pane wait for the next "blocked".
        if before?.state == .blocked, after.state != .blocked || after.msg != before?.msg {
            if let index = decisions.firstIndex(where: { $0.blockID == block && $0.sawBlocked }) {
                stale.append(decisions.remove(at: index).id)
            }
            for index in decisions.indices where decisions[index].blockID == block {
                decisions[index].sawBlocked = false
            }
        }
        syncBlocked(block: block)
        return stale
    }

    mutating func updateTitle(_ title: String?, block: String) {
        guard var pane = panes[block] else { return }
        pane.title = TitleCleaner.topic(title, agent: pane.agent)
        panes[block] = pane
    }

    mutating func updateLocation(cwd: String?, branch: String?, block: String) {
        guard var pane = panes[block] else { return }
        pane.cwd = cwd ?? pane.cwd
        pane.branch = branch
        panes[block] = pane
    }

    // MARK: Hooks

    mutating func addDecision(_ decision: Decision) {
        guard !decisions.contains(where: { $0.id == decision.id }) else { return }
        decisions.append(decision)
        syncBlocked(block: decision.blockID)
    }

    @discardableResult
    mutating func removeDecision(_ id: String) -> Decision? {
        guard let index = decisions.firstIndex(where: { $0.id == id }) else { return nil }
        return decisions.remove(at: index)
    }

    /// What the agent's other hooks said: the prompt you sent, or its last reply.
    mutating func note(prompt: String? = nil, message: String? = nil, block: String, session: String, now: Date = Date()) {
        var pane = panes[block] ?? Pane(id: block, sessionID: session, stateSince: now)
        if let prompt = RexParse.nonEmpty(prompt) {
            pane.lastPrompt = prompt
            pane.lastMessage = nil
        }
        if let message = RexParse.nonEmpty(message) { pane.lastMessage = message }
        panes[block] = pane
    }

    // MARK: Reading

    func decision(_ id: String) -> Decision? { decisions.first { $0.id == id } }

    /// What needs the user, oldest first: hook-backed decisions, then panes blocked with nothing to answer here.
    var attention: [Attention] {
        let withDecision = Set(decisions.map(\.blockID))
        let cards = decisions.map { Attention.decision($0, panes[$0.blockID]) }
        let waiting = agentPanes
            .filter { $0.state == .blocked && !withDecision.contains($0.id) }
            .sorted { $0.stateSince < $1.stateSince }
            .map(Attention.waiting)
        return cards + waiting
    }

    /// Panes running an agent, most recently changed first.
    var agentPanes: [Pane] {
        panes.values.filter { $0.status != nil }.sorted { $0.stateSince > $1.stateSince }
    }

    func panes(in state: AgentState) -> [Pane] { agentPanes.filter { $0.state == state } }

    var mood: Mood {
        if !attention.isEmpty { return .needsYou }
        let states = Set(agentPanes.map(\.state))
        if states.isEmpty { return .asleep }
        if states.contains(.error) { return .error }
        if states.contains(.working) { return .working }
        if states.contains(.done) { return .finished }
        return .idle
    }

    // MARK: Private

    /// Marks this pane's decisions as shown in the terminal while Rex says the pane is blocked.
    private mutating func syncBlocked(block: String) {
        guard panes[block]?.state == .blocked else { return }
        for index in decisions.indices where decisions[index].blockID == block {
            decisions[index].sawBlocked = true
        }
    }

    private mutating func dropDecisions(where predicate: (Decision) -> Bool) -> [String] {
        let dropped = decisions.filter(predicate).map(\.id)
        decisions.removeAll(where: predicate)
        return dropped
    }
}

enum Attention: Identifiable, Equatable {
    case decision(Decision, Pane?)
    /// Blocked in Rex, but no hook is waiting (hooks not installed, Codex questions, logins…).
    case waiting(Pane)

    var id: String {
        switch self {
        case .decision(let decision, _): "d:" + decision.id
        case .waiting(let pane): "p:" + pane.id
        }
    }

    var blockID: String {
        switch self {
        case .decision(let decision, _): decision.blockID
        case .waiting(let pane): pane.id
        }
    }
}
