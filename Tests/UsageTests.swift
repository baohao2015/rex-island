import Foundation

private func append(_ text: String, to url: URL) {
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: url)
    }
}

func usageTests() {
    // Status line snapshots: the newest report wins; windows that already reset are dropped.
    let now = Date(timeIntervalSince1970: 1_794_834_000)
    let snapshot = ClaudeSessionStatus.parse(Data(#"{"at":1794833000,"session_id":"a","block":"b1","model":"Opus 5.5","context_used_percentage":34.5,"cost_usd":1.25,"rate_limits":{"five_hour":{"used_percentage":17,"resets_at":1794835680},"seven_day":{"used_percentage":4,"resets_at":1795080000}}}"#.utf8))
    equal(snapshot?.block, "b1")
    equal(snapshot?.contextPercent, 34.5)
    equal(snapshot?.limits.map(\.span), [.fiveHour, .weekly])
    let older = ClaudeSessionStatus(sessionID: "b", block: nil, at: Date(timeIntervalSince1970: 1_794_000_000), model: nil, contextPercent: nil, costUSD: nil,
                                    limits: [LimitWindow(span: .fiveHour, usedPercent: 99, resetsAt: nil)])
    let current = ClaudeSessionStatus.currentLimits([older, snapshot!], now: now)
    equal(current.first?.usedPercent, 17)
    let afterReset = ClaudeSessionStatus.currentLimits([snapshot!], now: Date(timeIntervalSince1970: 1_794_840_000))
    equal(afterReset.map(\.span), [.fiveHour, .weekly], "a reset window stays, so columns don't shift")
    equal(afterReset.first?.usedPercent, 0, "5h window reset: nothing used in the new one yet")
    equal(afterReset.first?.resetsAt, nil)
    equal(afterReset.last?.usedPercent, 4)

    // Pace: 89% used with 86.5% of the week gone runs 2.5 points ahead.
    let week = LimitWindow(span: .weekly, usedPercent: 89, resetsAt: now.addingTimeInterval(0.135 * 7 * 86400))
    check(abs((week.pace(now: now) ?? 0) - 0.025) < 0.001)

    // Transcripts, read incrementally.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rexisland-usage-\(UUID().uuidString)")
    let claude = root.appendingPathComponent("claude/projects/p")
    let codex = root.appendingPathComponent("codex/sessions/2026/11/16")
    try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let scanNow = RexParse.date("2026-11-16T21:00:00+08:00")!
    let transcript = claude.appendingPathComponent("s.jsonl")
    append("""
    {"type":"user","timestamp":"2026-11-16T10:00:00+08:00","message":{"content":"hi"}}
    {"type":"assistant","timestamp":"2026-11-15T23:59:00+08:00","requestId":"r0","message":{"id":"m0","usage":{"input_tokens":999,"output_tokens":999}}}
    {"type":"assistant","timestamp":"2026-11-16T10:00:01+08:00","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}}
    {"type":"assistant","timestamp":"2026-11-16T10:00:02+08:00","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}}

    """, to: transcript)

    let rollout = codex.appendingPathComponent("rollout-x.jsonl")
    append("""
    {"timestamp":"2026-11-15T23:00:00+08:00","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100}}}}
    {"timestamp":"2026-11-16T09:00:00+08:00","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":1200,"output_tokens":150}},"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1794838584},"secondary":{"used_percent":89.0,"window_minutes":10080,"resets_at":1794916049},"plan_type":"plus"}}}
    {"timestamp":"2026-11-16T09:00:01+08:00","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":1200,"output_tokens":150}}}}

    """, to: rollout)

    let scanner = UsageScanner(claudeRoot: root.appendingPathComponent("claude/projects"), codexRoot: root.appendingPathComponent("codex/sessions"))
    scanner.scan(now: scanNow, calendar: calendar)
    equal(scanner.claudeToday, TokenTotals(input: 10, output: 20, cacheRead: 300, cacheWrite: 40), "yesterday's line skipped, repeated message counted once")
    equal(scanner.codexToday, TokenTotals(input: 100, output: 50, cacheRead: 400, cacheWrite: 0), "only today's increase; a repeated total adds nothing")
    equal(scanner.codexLimits.map(\.span), [.fiveHour, .weekly])
    equal(scanner.codexLimits.last?.usedPercent, 89)
    equal(scanner.codexPlan, "plus")

    // Appended lines are read once; a half-written line waits for the next scan.
    append(#"{"type":"assistant","timestamp":"2026-11-16T11:00:00+08:00","requestId":"r2","message":{"id":"m2","usage":{"input_tokens":1,"output_tokens":2}}}"#, to: transcript)
    scanner.scan(now: scanNow, calendar: calendar)
    equal(scanner.claudeToday.output, 20, "partial line not read yet")
    append("\n", to: transcript)
    scanner.scan(now: scanNow, calendar: calendar)
    equal(scanner.claudeToday.output, 22)
    scanner.scan(now: scanNow, calendar: calendar)
    equal(scanner.claudeToday.output, 22, "scanning again adds nothing")

    // A new day starts from zero.
    scanner.scan(now: RexParse.date("2026-11-17T08:00:00+08:00")!, calendar: calendar)
    equal(scanner.claudeToday, TokenTotals())
}

func formatTests() {
    equal(Format.tokens(950), "950")
    equal(Format.tokens(32_500), "32.5K")
    equal(Format.tokens(999_950), "1M")
    equal(Format.tokens(1_400_000), "1.4M")
    equal(Format.tokens(12_000_000), "12M")
    equal(Format.span(45), "45秒")
    equal(Format.span(3720), "1时02分")
    equal(Format.span(2 * 86400 + 20 * 3600 + 59), "2天20时")
    equal(Format.ago(Date().addingTimeInterval(-10)), "刚刚")
    equal(Format.resets(Date().addingTimeInterval(-1)), "已重置")
    equal(Format.oneLine("first line\nsecond"), "first line")
    equal(Format.oneLine("  \n"), nil)
}

func markdownTests() {
    let blocks = MarkdownBlock.parse("""
    # Title
    Some text
    continues here.

    ## Steps
    1. First
      - nested
    - [ ] todo
    - [x] done
    > careful
    ```
    let x = 1
    ```
    ---
    """)
    equal(blocks, [
        .heading(1, "Title"),
        .paragraph("Some text continues here."),
        .heading(2, "Steps"),
        .item(indent: 0, marker: "1.", text: "First"),
        .item(indent: 1, marker: "•", text: "nested"),
        .item(indent: 0, marker: "☐", text: "todo"),
        .item(indent: 0, marker: "☑", text: "done"),
        .quote("careful"),
        .code("let x = 1"),
        .rule,
    ])
    equal(MarkdownBlock.parse("#hashtag not a heading"), [.paragraph("#hashtag not a heading")])
    equal(MarkdownBlock.parse("```\nunclosed"), [.code("unclosed")])
}
