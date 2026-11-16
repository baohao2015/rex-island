import AppKit
import SwiftUI

/// `RexIsland --snapshot DIR`: renders each notch state with demo data to PNGs, for design review and the README.
@MainActor
enum Snapshots {
    static func render(to directory: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notch = CGSize(width: 185, height: 37)
        let now = Date()

        struct Scene {
            var name: String
            var presentation: NotchState.Presentation
            var height: CGFloat
            var selection: String?
            var connected = true
            var build: (inout Board) -> Void
        }

        let scenes: [Scene] = [
            Scene(name: "1-compact-working", presentation: .compact, height: 70) { busy(&$0, now: now) },
            Scene(name: "2-compact-waiting", presentation: .compact, height: 70) { busy(&$0, now: now); permission(&$0, now: now) },
            Scene(name: "3-peek-permission", presentation: .peek(.attention("d:perm")), height: 150, selection: "d:perm") {
                busy(&$0, now: now); permission(&$0, now: now)
            },
            Scene(name: "4-panel-permission", presentation: .expanded, height: 760, selection: "d:perm") {
                busy(&$0, now: now); permission(&$0, now: now); question(&$0, now: now)
            },
            Scene(name: "5-panel-question", presentation: .expanded, height: 760, selection: "d:ask") {
                busy(&$0, now: now); question(&$0, now: now)
            },
            Scene(name: "6-panel-plan", presentation: .expanded, height: 760, selection: "d:plan") {
                busy(&$0, now: now); plan(&$0, now: now)
            },
            Scene(name: "7-peek-finished", presentation: .peek(.finished("b:done")), height: 150) { busy(&$0, now: now) },
            Scene(name: "8-panel-empty", presentation: .expanded, height: 360, connected: false) { _ in },
        ]

        for scene in scenes {
            let model = AppModel(demo: true)
            model.loadDemo(scene.build, claude: claudeUsage(now: now), codex: codexUsage(now: now),
                           sessions: ["b:work1": ClaudeSessionStatus(sessionID: "a", block: "b:work1", at: now, model: "Opus 5.5",
                                                                     contextPercent: 34, costUSD: 1.2, limits: [])])
            if !scene.connected { model.disconnectForDemo() }
            let state = NotchState(notchSize: notch)
            state.presentation = scene.presentation
            state.selection = scene.selection
            let actions = NotchActions(resolve: { _, _ in }, answerInTerminal: { _ in }, reveal: { _ in },
                                       openSettings: {}, openPanel: {}, close: {})
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.55), Color(red: 0.62, green: 0.55, blue: 0.62)],
                               startPoint: .top, endPoint: .bottom)
                NotchRootView(model: model, state: state, actions: actions)
            }
            .frame(width: NotchController.windowSize.width, height: scene.height)
            write(view, size: CGSize(width: NotchController.windowSize.width, height: scene.height),
                  to: directory.appendingPathComponent(scene.name + ".png"))
        }
        print("wrote \(scenes.count) snapshots to \(directory.path)")
    }

    private static func write<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Demo data

    private static func status(_ state: AgentState, _ msg: String?, app: String = "claude-code", kind: BlockedKind? = nil, ago: TimeInterval, now: Date) -> RexStatus {
        RexStatus(state: state, kind: kind ?? (state == .blocked ? .permission : nil), msg: msg, app: app, progress: nil, updatedAt: now.addingTimeInterval(-ago))
    }

    private static func pane(_ id: String, _ title: String?, cwd: String, branch: String?, tab: String? = nil, _ status: RexStatus) -> Pane {
        Pane(id: id, sessionID: "s", sessionLabel: "默认工作空间", windowLabel: tab, title: title, cwd: cwd, branch: branch,
             status: status, stateSince: status.updatedAt)
    }

    private static func busy(_ board: inout Board, now: Date) {
        _ = board.replacePanes([
            pane("b:work1", "Rex 刘海工具第一版", cwd: "/Users/me/rex-island", branch: "main",
                 status(.working, "Writing the notch panel view", ago: 240, now: now)),
            pane("b:work2", "修复登录重定向", cwd: "/Users/me/web", branch: "fix/login", tab: "web",
                 status(.working, nil, app: "codex", ago: 65, now: now)),
            pane("b:done", "清理过期的 feature flag", cwd: "/Users/me/api", branch: "chore/flags",
                 status(.done, nil, ago: 320, now: now)),
            pane("b:idle", nil, cwd: "/Users/me/notes", branch: nil, status(.idle, nil, ago: 3600, now: now)),
        ], inSessions: ["s"], now: now)
        board.note(message: "删掉了 6 个已全量的开关，测试都过了，没有提交。", block: "b:done", session: "s")
    }

    private static func permission(_ board: inout Board, now: Date) {
        _ = board.replacePanes(board.panes.values.map { $0 } + [
            pane("b:perm", "发布前构建", cwd: "/Users/me/site", branch: "release", status(.blocked, "approve Bash: rm -rf dist && npm run build", ago: 25, now: now)),
        ], inSessions: ["s"], now: now)
        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf dist && npm run build", "description": "Clean the build output and rebuild the site"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm run build:*"]], "behavior": "allow", "destination": "localSettings"]],
        ]
        board.addDecision(DecisionParser.decision(id: "perm", agent: .claude, block: "b:perm", session: "s", payload: payload, now: now.addingTimeInterval(-25)))
    }

    private static func question(_ board: inout Board, now: Date) {
        _ = board.replacePanes(board.panes.values.map { $0 } + [
            pane("b:ask", "设计缓存层", cwd: "/Users/me/api", branch: "feat/cache", status(.blocked, "Which cache backend?", kind: .question, ago: 70, now: now)),
        ], inSessions: ["s"], now: now)
        let payload: [String: Any] = [
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [
                ["question": "缓存放在哪一层？", "header": "缓存层", "multiSelect": false, "options": [
                    ["label": "Redis", "description": "多实例共享，过期策略成熟"],
                    ["label": "进程内 LRU", "description": "最快，但每个实例各自一份"],
                    ["label": "先不加缓存", "description": "先把慢查询修掉再看"],
                ]],
                ["question": "要同时做哪些？", "header": "附带", "multiSelect": true, "options": [
                    ["label": "命中率指标"], ["label": "手动清缓存的接口"],
                ]],
            ]],
        ]
        board.addDecision(DecisionParser.decision(id: "ask", agent: .claude, block: "b:ask", session: "s", payload: payload, now: now.addingTimeInterval(-70)))
    }

    private static func plan(_ board: inout Board, now: Date) {
        _ = board.replacePanes(board.panes.values.map { $0 } + [
            pane("b:plan", "迁移到新的支付 SDK", cwd: "/Users/me/pay", branch: "feat/sdk-v3", status(.blocked, nil, ago: 40, now: now)),
        ], inSessions: ["s"], now: now)
        let plan = """
        # 迁移到支付 SDK v3
        ## 步骤
        1. 在 `PaymentClient` 外面包一层适配器，新旧 SDK 并存
        2. 回调签名校验改用 v3 的 `verify()`
        3. 灰度：先切 5% 流量，观察成功率
        - [ ] 补充回调的集成测试
        - [x] 确认 v3 支持现有的币种
        > 风险：v3 的退款接口是异步的，需要改对账任务。
        """
        let payload: [String: Any] = ["tool_name": "ExitPlanMode", "tool_input": ["plan": plan],
                                      "permission_suggestions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]]
        board.addDecision(DecisionParser.decision(id: "plan", agent: .claude, block: "b:plan", session: "s", payload: payload, now: now.addingTimeInterval(-40)))
    }

    private static func claudeUsage(now: Date) -> ProviderUsage {
        ProviderUsage(provider: .claude, plan: nil, windows: [
            LimitWindow(span: .fiveHour, usedPercent: 17, resetsAt: now.addingTimeInterval(28 * 60)),
            LimitWindow(span: .weekly, usedPercent: 4, resetsAt: now.addingTimeInterval(2 * 86400 + 20 * 3600)),
        ], today: TokenTotals(input: 120_000, output: 310_000, cacheRead: 2_600_000, cacheWrite: 180_000))
    }

    private static func codexUsage(now: Date) -> ProviderUsage {
        ProviderUsage(provider: .codex, plan: "plus", windows: [
            LimitWindow(span: .fiveHour, usedPercent: 1, resetsAt: now.addingTimeInterval(4 * 3600 + 12 * 60)),
            LimitWindow(span: .weekly, usedPercent: 89, resetsAt: now.addingTimeInterval(0.11 * 7 * 86400)),
        ], today: TokenTotals(input: 380_000, output: 24_000, cacheRead: 3_400_000, cacheWrite: 0))
    }
}
