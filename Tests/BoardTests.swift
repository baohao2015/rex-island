import Foundation

private func status(_ state: AgentState, msg: String? = nil, app: String = "claude-code") -> RexStatus {
    RexStatus(state: state, kind: state == .blocked ? .permission : nil, msg: msg, app: app, progress: nil, updatedAt: Date())
}

private func decision(_ id: String, block: String = "b1", at offset: TimeInterval = 0) -> Decision {
    let payload = json(#"{"tool_name":"Bash","tool_input":{"command":"touch out.txt"}}"#)
    return DecisionParser.decision(id: id, agent: .claude, block: block, session: "s", payload: payload, now: Date(timeIntervalSince1970: 1000 + offset))
}

func boardTests() {
    // Answered in the terminal: the hook keeps waiting, so leaving "blocked" retires the card.
    do {
        var board = Board()
        _ = board.applyStatus(status(.working), block: "b1", session: "s")
        board.addDecision(decision("d1"))
        equal(board.decisions.first?.sawBlocked, false, "hook arrived before Rex reported blocked")
        equal(board.applyStatus(status(.working, msg: "still thinking"), block: "b1", session: "s"), [], "working → working keeps the card")
        equal(board.applyStatus(status(.blocked, msg: "approve Bash: touch out.txt"), block: "b1", session: "s"), [])
        equal(board.decisions.first?.sawBlocked, true)
        equal(board.applyStatus(status(.working), block: "b1", session: "s"), ["d1"], "answered in terminal")
        check(board.decisions.isEmpty)
    }

    // Answered in the notch: the card is removed first, so Rex moving on retires nothing else.
    do {
        var board = Board()
        _ = board.applyStatus(status(.blocked, msg: "approve Bash: x"), block: "b1", session: "s")
        board.addDecision(decision("d1"))
        equal(board.decisions.first?.sawBlocked, true, "hook arrived after Rex reported blocked")
        equal(board.removeDecision("d1")?.id, "d1")
        equal(board.applyStatus(status(.working), block: "b1", session: "s"), [])
    }

    // Two requests queued in one pane: only the one the terminal showed (the oldest) is retired.
    do {
        var board = Board()
        _ = board.applyStatus(status(.blocked, msg: "approve Bash: a"), block: "b1", session: "s")
        board.addDecision(decision("d1", at: 0))
        board.addDecision(decision("d2", at: 1))
        equal(board.applyStatus(status(.working), block: "b1", session: "s"), ["d1"])
        equal(board.decisions.map(\.id), ["d2"])
        equal(board.decisions.first?.sawBlocked, false)
        _ = board.applyStatus(status(.blocked, msg: "approve Bash: b"), block: "b1", session: "s")
        equal(board.applyStatus(status(.done), block: "b1", session: "s"), ["d2"])
    }

    // Still blocked, but on a different prompt: the earlier one was answered.
    do {
        var board = Board()
        _ = board.applyStatus(status(.blocked, msg: "approve Bash: a"), block: "b1", session: "s")
        board.addDecision(decision("d1", at: 0))
        board.addDecision(decision("d2", at: 1))
        equal(board.applyStatus(status(.blocked, msg: "approve Bash: a"), block: "b1", session: "s"), [], "same prompt reported again")
        equal(board.applyStatus(status(.blocked, msg: "approve Bash: b"), block: "b1", session: "s"), ["d1"])
        equal(board.decisions.first?.sawBlocked, true, "the next prompt is the one on screen now")
    }

    // The agent stopped reporting, or its pane closed: nothing there is waiting.
    do {
        var board = Board()
        _ = board.applyStatus(status(.blocked), block: "b1", session: "s")
        board.addDecision(decision("d1"))
        equal(board.applyStatus(nil, block: "b1", session: "s"), ["d1"])

        _ = board.applyStatus(status(.blocked), block: "b2", session: "s")
        board.addDecision(decision("d2", block: "b2"))
        let other = Pane(id: "b3", sessionID: "s", status: status(.working))
        equal(board.replacePanes([other], inSessions: ["s"]), ["d2"], "pane b2 closed")
        equal(board.panes.keys.sorted(), ["b3"])
    }

    // A snapshot after reconnecting retires cards the same way a live report does.
    do {
        var board = Board()
        _ = board.applyStatus(status(.blocked), block: "b1", session: "s")
        board.addDecision(decision("d1"))
        board.note(prompt: "fix it", block: "b1", session: "s")
        let fresh = Pane(id: "b1", sessionID: "s", title: "Fix it", status: status(.working))
        equal(board.replacePanes([fresh], inSessions: ["s"]), ["d1"])
        equal(board.panes["b1"]?.lastPrompt, "fix it", "hook facts survive a snapshot")
        equal(board.panes["b1"]?.title, "Fix it")
    }

    // Attention and mood.
    do {
        var board = Board()
        equal(board.mood, .asleep)
        _ = board.applyStatus(status(.working), block: "b1", session: "s")
        equal(board.mood, .working)
        _ = board.applyStatus(status(.done), block: "b1", session: "s")
        equal(board.mood, .finished)
        _ = board.applyStatus(status(.blocked, app: "codex"), block: "b2", session: "s")
        equal(board.attention.map(\.id), ["p:b2"], "blocked with no hook waiting")
        equal(board.mood, .needsYou)
        board.addDecision(decision("d1", block: "b2"))
        equal(board.attention.map(\.id), ["d:d1"], "the card replaces the bare blocked row")
        board.note(prompt: "new task", block: "b1", session: "s")
        board.note(message: "Done: fixed it", block: "b1", session: "s")
        equal(board.panes["b1"]?.lastMessage, "Done: fixed it")
        board.note(prompt: "next", block: "b1", session: "s")
        equal(board.panes["b1"]?.lastMessage, nil, "a new prompt clears the last reply")
        equal(board.keepSessions([]), ["d1"])
        equal(board.mood, .asleep)
    }
}
