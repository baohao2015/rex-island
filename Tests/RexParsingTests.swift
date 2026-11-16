import Foundation

func rexParsingTests() {
    // Real line captured from `rex events --all --json` (Rex 0.1.0-preview.14).
    let line = #"{"type":"session_event","payload":{"session_id":"session:01a1ca96","event":{"type":"block_event","payload":{"block_id":"block:01a1e37e","creator_name":"com.superlogical.terminal","name":"program_status_changed","payload":{"id":"","record":{"state":"working","app":"claude-code","effective_app":"claude-code","msg":"Summarizing captured Rex events","updated_at":"2026-11-16T21:00:55.860458+08:00","owner":{"pid":10329,"name":"claude.exe"}},"reason":"report"}}}}}"#
    guard case .status(let session, let block, let recordID, let record?) = RexEvent(line: Data(line.utf8)) else {
        check(false, "status event not parsed")
        return
    }
    equal(session, "session:01a1ca96")
    equal(block, "block:01a1e37e")
    equal(recordID, "")
    equal(record.state, .working)
    equal(record.app, "claude-code")
    equal(record.msg, "Summarizing captured Rex events")
    // 2026-11-16T13:00:55.860458Z
    check(abs(record.updatedAt.timeIntervalSince1970 - 1_794_834_055.860458) < 0.01, "microsecond timestamp: \(record.updatedAt.timeIntervalSince1970)")

    let blocked = RexParse.status(record: json(#"{"state":"blocked","kind":"permission","msg":"approve Bash: touch out3.txt","updated_at":"2026-11-16T21:04:02+08:00"}"#))
    equal(blocked?.state, .blocked)
    equal(blocked?.kind, .permission)
    equal(RexParse.status(record: json(#"{"state":"pondering"}"#))?.state, .idle, "unknown state reads as idle")
    equal(RexParse.status(record: json(#"{"state":"blocked","kind":"telepathy"}"#))?.kind, nil, "unknown kind reads as unset")

    // The root record speaks for the pane even when a child is more urgent.
    let records = [json(#"{"id":"build/test","state":"error"}"#), json(#"{"state":"working"}"#)]
    equal(RexParse.paneStatus(records: records)?.state, .working)
    equal(RexParse.paneStatus(records: [json(#"{"id":"a","state":"done"}"#), json(#"{"id":"b","state":"blocked"}"#)])?.state, .blocked)
    equal(RexParse.paneStatus(methodResult: Data(#"{"records":[]}"#.utf8)), nil)

    let client = #"{"type":"session_event","payload":{"session_id":"s","event":{"type":"client_connected","payload":{}}}}"#
    equal(RexEvent(line: Data(client.utf8)), .ignored)
    let layout = #"{"type":"session_event","payload":{"session_id":"s","event":{"type":"window_created","payload":{}}}}"#
    equal(RexEvent(line: Data(layout.utf8)), .layout(session: "s"))
    let title = #"{"type":"session_event","payload":{"session_id":"s","event":{"type":"block_event","payload":{"block_id":"b","name":"title_changed","payload":{"title":"✳ Fix login"}}}}}"#
    equal(RexEvent(line: Data(title.utf8)), .title(session: "s", block: "b", title: "✳ Fix login"))
    equal(RexEvent(line: Data(#"{"type":"session_created","payload":{"session_id":"s2"}}"#.utf8)), .sessions)
    equal(RexEvent(line: Data("not json".utf8)), .ignored)

    // Titles
    equal(TitleCleaner.topic("✳ Touch out3.txt", agent: .claude), "Touch out3.txt")
    equal(TitleCleaner.topic("Mac刘海Agent状态展示与Rex", agent: .claude), "Mac刘海Agent状态展示与Rex")
    equal(TitleCleaner.topic("✳ Claude Code", agent: .claude), nil)
    equal(TitleCleaner.topic("⠋ Fix flaky test | web", agent: .codex), "Fix flaky test")
    equal(TitleCleaner.topic("[ ! ] Action Required | ⠋ Fix flaky test | web", agent: .codex), "Fix flaky test")
    equal(TitleCleaner.topic("  ", agent: .claude), nil)

    equal(RexLayout.userLabel("Window 6f90c115"), nil)
    equal(RexLayout.userLabel("build"), "build")
    equal(RexLayout.userLabel("Window logs"), "Window logs")

    let view = RexLayout.view(Data(#"{"session_id":"s","label":"默认工作空间","active_window_id":"w1","windows":[{"window_id":"w1","label":"Window 6f90c115","focused_block_id":"b1"},{"window_id":"w2","label":"api","focused_block_id":"b2"}]}"#.utf8))
    equal(view?.label, "默认工作空间")
    equal(view?.windows.map(\.label), [nil, "api"])
    equal(view?.windows.first?.focusedBlockID, "b1")
    equal(RexLayout.cwd(Data(#"{"foreground":{"pid":1,"cwd":"/tmp/x"}}"#.utf8)), "/tmp/x")
}
