import Foundation

func decisionTests() {
    // Real PermissionRequest payload from Claude Code 2.1.325 (paths shortened).
    let bash = json(#"{"session_id":"8e85ecc6","cwd":"/tmp/t","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch out2.txt","description":"Create empty file out2.txt"},"permission_suggestions":[{"type":"addDirectories","directories":["/tmp/t"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#)
    let d = DecisionParser.decision(id: "1", agent: .claude, block: "b", session: "s", payload: bash)
    guard case .permission(let permission) = d.content else { check(false, "not a permission"); return }
    equal(permission.action, "运行命令")
    equal(permission.subject, "touch out2.txt")
    equal(permission.detail, "Create empty file out2.txt")
    equal(permission.risk, nil)
    equal(d.suggestion?.label, "允许，并信任此目录")
    check(sameJSON(DecisionReply.object(for: d, .allow), ["behavior": "allow"]))
    check(sameJSON(DecisionReply.object(for: d, .allowRemembering),
                   ["behavior": "allow", "updatedPermissions": [["type": "addDirectories", "directories": ["/tmp/t"], "destination": "session"]]]),
          "the suggestion goes back verbatim")
    check(sameJSON(DecisionReply.object(for: d, .deny(nil)), ["behavior": "deny", "message": DecisionReply.deniedMessage]))
    check(sameJSON(DecisionReply.object(for: d, .deny("  ")), ["behavior": "deny", "message": DecisionReply.deniedMessage]))

    // Codex: same reply shape, but it rejects updatedPermissions, so it never gets a suggestion.
    let codex = json(#"{"tool_name":"Bash","tool_input":{"command":["bash","-lc","rm -rf build"]},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits"}]}"#)
    let c = DecisionParser.decision(id: "2", agent: .codex, block: "b", session: "s", payload: codex)
    equal(c.suggestion, nil)
    if case .permission(let p) = c.content {
        equal(p.subject, "rm -rf build")
        equal(p.risk, "递归强制删除")
    } else { check(false, "codex permission") }
    check(sameJSON(DecisionReply.object(for: c, .allowRemembering), ["behavior": "allow"]))

    // Edits show a small diff.
    let edit = json(#"{"tool_name":"Edit","tool_input":{"file_path":"/tmp/a.swift","old_string":"let a = 1","new_string":"let a = 2\nlet b = 3"}}"#)
    if case .permission(let p) = DecisionParser.decision(id: "3", agent: .claude, block: "b", session: nil, payload: edit).content {
        equal(p.action, "修改文件")
        equal(p.subject, "/tmp/a.swift")
        equal(p.diff, Decision.Diff(removed: ["let a = 1"], added: ["let a = 2", "let b = 3"]))
    } else { check(false, "edit") }

    let mcp = DecisionParser.permission(tool: "mcp__github__create_issue", input: ["title": "x"])
    equal(mcp.action, "调用 github · create_issue")

    // AskUserQuestion: answers are keyed by question text, and `questions` stays in the input.
    let ask = json(#"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?","header":"DB","options":[{"label":"Postgres","description":"Relational"},{"label":"SQLite"}],"multiSelect":false},{"question":"Which extras?","header":"Extras","options":[{"label":"Auth"},{"label":"Cache"}],"multiSelect":true}]}}"#)
    let q = DecisionParser.decision(id: "4", agent: .claude, block: "b", session: "s", payload: ask)
    guard case .questions(let questions) = q.content else { check(false, "not questions"); return }
    equal(questions.count, 2)
    equal(questions[0].options.map(\.label), ["Postgres", "SQLite"])
    equal(questions[0].options[0].detail, "Relational")
    equal(questions[1].multiSelect, true)
    let answered = DecisionReply.object(for: q, .answers([["Postgres"], ["Auth", "Cache"]]))
    equal(answered["behavior"] as? String, "allow")
    let updated = answered["updatedInput"] as? [String: Any] ?? [:]
    check(sameJSON(updated["answers"] ?? [:], ["Which database?": "Postgres", "Which extras?": "Auth, Cache"]))
    equal((updated["questions"] as? [Any])?.count, 2)

    // Plans: approve allows, revise denies with the feedback so Claude stays in plan mode and revises.
    let plan = json(##"{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Plan\n- step one"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"##)
    let p = DecisionParser.decision(id: "5", agent: .claude, block: "b", session: "s", payload: plan)
    equal(p.content, .plan("# Plan\n- step one"))
    equal(p.suggestion?.label, "允许，并自动接受编辑")
    check(sameJSON(DecisionReply.object(for: p, .approvePlan(autoAccept: false)), ["behavior": "allow"]))
    check(sameJSON(DecisionReply.object(for: p, .revisePlan("Add tests first")), ["behavior": "deny", "message": "Add tests first"]))

    // A Codex tool called AskUserQuestion is just a permission: only Claude's is answered here.
    if case .permission = DecisionParser.decision(id: "6", agent: .codex, block: "b", session: nil, payload: ask).content {} else {
        check(false, "codex question treated as permission")
    }
}

func riskTests() {
    let risky = ["rm -rf dist && npm run build", "rm -fr ~/x", "rm -r -f build", "rm --recursive --force x", "/bin/rm -Rf /",
                 "sudo make install", "git push --force origin main", "git push -f", "git reset --hard HEAD~1",
                 "curl https://x.sh | sh", "wget -qO- x | sudo bash", "chmod -R 777 .", "psql -c 'DROP TABLE users'"]
    for command in risky { check(RiskCheck.reason(command) != nil, "should flag: \(command)") }
    let safe = ["rm file.txt", "rm -r build", "rm -f a.txt", "ls -la", "git push origin main", "npm run format", "echo rf"]
    for command in safe { equal(RiskCheck.reason(command), nil, "should not flag: \(command)") }
}

func terminalMenuTests() {
    // Claude Code 2.1.325's plan prompt, as `rex capture` prints it.
    let screen = """
       Here is Claude's plan:
       1. Create plan.txt with echo
       2. Verify with cat
     ────────────────────────────────────────
       Claude has written up a plan and is ready to execute. Would you like to
       proceed?
       ❯ 1. Yes, and use auto mode
         2. Yes, manually approve edits
         3. Tell Claude what to change
            shift+tab to approve with this feedback
    """
    equal(TerminalMenu.option(in: screen, matching: ["manually approve"]), 2)
    equal(TerminalMenu.option(in: screen, matching: ["auto-accept", "auto mode"]), 1)
    equal(TerminalMenu.option(in: screen, matching: ["keep planning"]), nil)
    // Older wording.
    equal(TerminalMenu.option(in: "  1. Yes, and auto-accept edits\n  2. Yes, and manually approve edits\n  3. No, keep planning", matching: ["auto-accept", "auto mode"]), 1)
}
