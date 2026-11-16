import Foundation

/// Turns a PermissionRequest hook payload into a card, and the user's answer back into what the agent expects.
enum DecisionParser {
    static func decision(id: String, agent: AgentKind, block: String, session: String?, payload: [String: Any], now: Date = Date()) -> Decision {
        let tool = payload["tool_name"] as? String ?? "Tool"
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)

        let content: Decision.Content
        if agent == .claude, tool == "AskUserQuestion", let questions = questions(input), !questions.isEmpty {
            content = .questions(questions)
        } else if agent == .claude, tool == "ExitPlanMode" {
            content = .plan(RexParse.nonEmpty(input["plan"] as? String) ?? "（计划内容请在 Rex 里查看）")
        } else {
            content = .permission(permission(tool: tool, input: input))
        }
        // Codex rejects updatedPermissions, so only Claude gets "allow and remember".
        let suggestion = agent == .claude ? suggestion(payload["permission_suggestions"]) : nil
        return Decision(id: id, agent: agent, blockID: block, sessionID: session, createdAt: now,
                        content: content, toolInput: inputData, suggestion: suggestion)
    }

    static func questions(_ input: [String: Any]) -> [Decision.Question]? {
        guard let raw = input["questions"] as? [[String: Any]] else { return nil }
        return raw.compactMap { item in
            guard let text = RexParse.nonEmpty(item["question"] as? String) else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> Decision.Option? in
                guard let label = RexParse.nonEmpty(option["label"] as? String) else { return nil }
                return Decision.Option(label: label, detail: RexParse.nonEmpty(option["description"] as? String))
            }
            return Decision.Question(header: RexParse.nonEmpty(item["header"] as? String), text: text,
                                     options: options, multiSelect: item["multiSelect"] as? Bool ?? false)
        }
    }

    static func permission(tool: String, input: [String: Any]) -> Decision.Permission {
        let detail = RexParse.nonEmpty(input["description"] as? String)
        func string(_ key: String) -> String? { RexParse.nonEmpty(input[key] as? String) }

        switch tool {
        case "Bash", "shell", "exec_command", "local_shell", "unified_exec":
            let command = commandText(input["command"]) ?? compact(input)
            return .init(tool: tool, action: "运行命令", subject: command, detail: detail, risk: RiskCheck.reason(command))
        case "Edit", "MultiEdit":
            let edit = (input["edits"] as? [[String: Any]])?.first ?? input
            let diff = Decision.Diff(removed: lines(edit["old_string"] as? String), added: lines(edit["new_string"] as? String))
            return .init(tool: tool, action: "修改文件", subject: string("file_path") ?? compact(input), detail: detail, diff: diff)
        case "Write":
            let diff = Decision.Diff(removed: [], added: lines(input["content"] as? String))
            return .init(tool: tool, action: "写入文件", subject: string("file_path") ?? compact(input), detail: detail, diff: diff)
        case "NotebookEdit":
            return .init(tool: tool, action: "修改 Notebook", subject: string("notebook_path") ?? compact(input), detail: detail)
        case "Read":
            return .init(tool: tool, action: "读取文件", subject: string("file_path") ?? compact(input), detail: detail)
        case "WebFetch":
            return .init(tool: tool, action: "访问网页", subject: string("url") ?? compact(input), detail: string("prompt"))
        case "WebSearch":
            return .init(tool: tool, action: "搜索网页", subject: string("query") ?? compact(input), detail: detail)
        case "apply_patch":
            let patch = string("patch") ?? string("input") ?? compact(input)
            return .init(tool: tool, action: "应用补丁", subject: lines(patch, limit: 12).joined(separator: "\n"), detail: detail)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                let name = parts.count >= 3 ? "\(parts[1]) · \(parts[2...].joined(separator: "_"))" : tool
                return .init(tool: tool, action: "调用 \(name)", subject: compact(input), detail: detail)
            }
            return .init(tool: tool, action: "使用 \(tool)", subject: compact(input), detail: detail)
        }
    }

    /// The first "remember this" option the agent offered that is safe to offer in one click.
    static func suggestion(_ value: Any?) -> Decision.Suggestion? {
        guard let suggestions = value as? [[String: Any]] else { return nil }
        for item in suggestions {
            let label: String?
            switch item["type"] as? String {
            case "addRules" where (item["behavior"] as? String ?? "allow") == "allow":
                let rule = (item["rules"] as? [[String: Any]])?.first
                let tool = rule?["toolName"] as? String
                let content = RexParse.nonEmpty(rule?["ruleContent"] as? String)
                label = tool.map { tool in content.map { "总是允许 \(tool)(\(truncate($0, 36)))" } ?? "总是允许 \(tool)" }
            case "addDirectories":
                label = "允许，并信任此目录"
            case "setMode" where item["mode"] as? String == "acceptEdits":
                label = "允许，并自动接受编辑"
            default:
                label = nil
            }
            if let label, let raw = try? JSONSerialization.data(withJSONObject: item) {
                return Decision.Suggestion(label: label, raw: raw)
            }
        }
        return nil
    }

    static func commandText(_ value: Any?) -> String? {
        if let text = value as? String { return RexParse.nonEmpty(text) }
        if let parts = value as? [String], !parts.isEmpty {
            // Codex sends argv; `bash -lc "<script>"` reads better as just the script.
            if parts.count == 3, ["bash", "zsh", "sh"].contains(parts[0]), parts[1].hasPrefix("-") { return parts[2] }
            return parts.joined(separator: " ")
        }
        return nil
    }

    static func lines(_ text: String?, limit: Int = 8) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let all = text.components(separatedBy: "\n")
        var shown = Array(all.prefix(limit))
        if all.count > limit { shown.append("… 还有 \(all.count - limit) 行") }
        return shown
    }

    static func compact(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return truncate(text, 400)
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

enum DecisionReply {
    static let deniedMessage = "The user declined this in Rex Island."

    /// The object the agent reads under `hookSpecificOutput.decision`.
    static func object(for decision: Decision, _ resolution: Resolution) -> [String: Any] {
        switch resolution {
        case .allow:
            return ["behavior": "allow"]
        case .allowRemembering:
            return allow(remembering: decision)
        case .approvePlan:
            // Only reached by agents that honor it; Claude Code's plan prompt is answered in the pane.
            return ["behavior": "allow"]
        case .deny(let message):
            return ["behavior": "deny", "message": RexParse.nonEmpty(message) ?? deniedMessage]
        case .revisePlan(let feedback):
            return ["behavior": "deny", "message": RexParse.nonEmpty(feedback) ?? deniedMessage]
        case .answers(let answers):
            guard case .questions(let questions) = decision.content else { return ["behavior": "allow"] }
            var input = (try? JSONSerialization.jsonObject(with: decision.toolInput)) as? [String: Any] ?? [:]
            // Claude Code looks answers up by question text, and needs `questions` kept in the input.
            var byQuestion: [String: String] = [:]
            for (question, picked) in zip(questions, answers) where !picked.isEmpty {
                byQuestion[question.text] = picked.joined(separator: ", ")
            }
            input["answers"] = byQuestion
            return ["behavior": "allow", "updatedInput": input]
        }
    }

    private static func allow(remembering decision: Decision) -> [String: Any] {
        guard let raw = decision.suggestion?.raw,
              let update = try? JSONSerialization.jsonObject(with: raw) else { return ["behavior": "allow"] }
        return ["behavior": "allow", "updatedPermissions": [update]]
    }
}

/// A short, explainable list of commands worth a second look. Not a security boundary.
enum RiskCheck {
    private static let rules: [(pattern: String, reason: String)] = [
        (#"\bsudo\b"#, "需要管理员权限"),
        (#"\bgit\s+push\b.*(--force\b|\s-f\b|--force-with-lease)"#, "强制推送"),
        (#"\bgit\s+reset\s+--hard\b"#, "丢弃本地改动"),
        (#"\bgit\s+clean\s+-[a-zA-Z]*f"#, "删除未跟踪文件"),
        (#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "下载后直接执行"),
        (#"\bdd\s+if="#, "直接写磁盘"),
        (#"\bmkfs(\.\w+)?\b"#, "格式化磁盘"),
        (#"\bchmod\s+(-R\s+)?0?777\b"#, "放开全部权限"),
        (#"(?i)\bdrop\s+(table|database)\b"#, "删除数据表"),
        (#"\bkubectl\s+delete\b"#, "删除集群资源"),
        (#"\bterraform\s+destroy\b"#, "销毁基础设施"),
    ]

    static func reason(_ command: String) -> String? {
        if isRecursiveForceRemove(command) { return "递归强制删除" }
        for rule in rules where command.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.reason
        }
        return nil
    }

    /// `rm` with both a recursive and a force flag, in any spelling: `-rf`, `-fR`, `-r -f`, `--recursive --force`.
    static func isRecursiveForceRemove(_ command: String) -> Bool {
        let separators = CharacterSet(charactersIn: ";&|\n")
        for segment in command.components(separatedBy: separators) {
            let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let rm = words.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { continue }
            var recursive = false, force = false
            for word in words[(rm + 1)...] {
                if word == "--" { break }
                if word == "--recursive" { recursive = true } else if word == "--force" { force = true }
                else if word.hasPrefix("-"), !word.hasPrefix("--") {
                    recursive = recursive || word.contains("r") || word.contains("R")
                    force = force || word.contains("f")
                }
            }
            if recursive && force { return true }
        }
        return false
    }
}

/// Reads a numbered menu off a terminal screen, e.g. Claude Code's plan approval:
/// "❯ 1. Yes, and use auto mode" / "2. Yes, manually approve edits".
enum TerminalMenu {
    /// The number of the last menu option whose text contains one of `needles` (case-insensitive).
    /// The last match, because the live menu is at the bottom of the screen.
    static func option(in screen: String, matching needles: [String]) -> Int? {
        var found: Int?
        for line in screen.components(separatedBy: "\n") {
            var text = Substring(line.trimmingCharacters(in: .whitespaces))
            if text.hasPrefix("❯") || text.hasPrefix(">") { text = text.dropFirst().drop { $0 == " " } }
            guard let dot = text.firstIndex(of: "."), let number = Int(text[..<dot]), (1...9).contains(number) else { continue }
            let label = text[text.index(after: dot)...].lowercased()
            if needles.contains(where: { label.contains($0.lowercased()) }) { found = number }
        }
        return found
    }
}
