import SwiftUI

/// The open panel: what needs you first, then what's running, then plan limits.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    let actions: NotchActions
    @State private var contentHeight: CGFloat = 0
    @State private var showAllIdle = false
    @AppStorage("setupHintDismissed") private var setupHintDismissed = false

    private static let maxContentHeight: CGFloat = 540

    var body: some View {
        let board = model.board
        VStack(spacing: 0) {
            header(board)
            ScrollView(.vertical, showsIndicators: contentHeight > Self.maxContentHeight) {
                sections(board)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { contentHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in contentHeight = height }
                    })
            }
            .frame(height: min(max(contentHeight, 1), Self.maxContentHeight))
            UsageFooter(model: model, actions: actions)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func header(_ board: Board) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Eyes(mood: board.mood, face: state.face).frame(width: 30, height: state.notchSize.height)
                Text(summary(board))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(board.attention.isEmpty ? Theme.secondary : Theme.amber)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: state.notchSize.width)
            HStack(spacing: 2) {
                Spacer()
                IconButton(symbol: model.soundsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                           help: model.soundsEnabled ? "静音" : "打开提示音") { model.soundsEnabled.toggle() }
                IconButton(symbol: "gearshape.fill", help: "设置") { actions.openSettings() }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: state.notchSize.height)
    }

    @ViewBuilder private func sections(_ board: Board) -> some View {
        let attention = board.attention
        let working = board.panes(in: .working)
        let errored = board.panes(in: .error)
        let done = board.panes(in: .done)
        let idle = board.panes(in: .idle)

        VStack(alignment: .leading, spacing: 12) {
            banners
            if board.agentPanes.isEmpty && attention.isEmpty {
                EmptyState(rexHealth: model.rexHealth)
            }
            if !attention.isEmpty {
                Section(title: "等你", count: attention.count, tint: Theme.amber) {
                    ForEach(attention) { item in
                        AttentionCard(item: item, model: model, state: state, actions: actions,
                                      selected: state.selection == item.id)
                    }
                }
            }
            if !working.isEmpty {
                Section(title: "在忙", count: working.count, tint: Theme.blue) {
                    ForEach(working) { PaneRow(pane: $0, model: model, actions: actions) }
                }
            }
            if !errored.isEmpty {
                Section(title: "出错", count: errored.count, tint: Theme.red) {
                    ForEach(errored) { PaneRow(pane: $0, model: model, actions: actions) }
                }
            }
            if !done.isEmpty {
                Section(title: "刚完成", count: done.count, tint: Theme.green) {
                    ForEach(done) { PaneRow(pane: $0, model: model, actions: actions) }
                }
            }
            if !idle.isEmpty {
                Section(title: "空闲", count: idle.count, tint: Theme.tertiary) {
                    let shown = showAllIdle ? idle : Array(idle.prefix(3))
                    ForEach(shown) { PaneRow(pane: $0, model: model, actions: actions) }
                    if idle.count > 3 {
                        Button(showAllIdle ? "收起" : "还有 \(idle.count - 3) 个") { showAllIdle.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.leading, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        let status = model.integrations
        if case .missing = model.rexHealth {
            Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, title: "找不到 rex 命令",
                   detail: "装好 Rex 后重开 Rex Island。", button: nil, action: {})
        } else if case .unreachable = model.rexHealth {
            Banner(symbol: "bolt.horizontal.circle", tint: Theme.amber, title: "连不上 Rex 服务",
                   detail: "Rex 没在运行时会自动重连。", button: nil, action: {})
        }
        let missing = [status.claudePresent && !status.claudeHooks ? "Claude Code" : nil,
                       status.codexPresent && !status.codexHooks ? "Codex" : nil].compactMap { $0 }
        if !missing.isEmpty, !setupHintDismissed {
            Banner(symbol: "hand.raised.fill", tint: Theme.blue, title: "现在只能看状态，还不能在这里审批",
                   detail: "\(missing.joined(separator: " 和 ")) 还没装上 Rex Island 的 hook。装上以后，授权、提问和计划都能直接在刘海里处理。",
                   button: "打开设置", action: actions.openSettings, onDismiss: { setupHintDismissed = true })
        }
        if let error = status.lastError {
            Banner(symbol: "xmark.octagon.fill", tint: Theme.red, title: "出了点问题", detail: error, button: "设置", action: actions.openSettings)
        }
    }

    private func summary(_ board: Board) -> String {
        var parts: [String] = []
        let waiting = board.attention.count
        if waiting > 0 { parts.append("\(waiting) 等你") }
        let working = board.panes(in: .working).count
        if working > 0 { parts.append("\(working) 在忙") }
        let done = board.panes(in: .done).count
        if done > 0 { parts.append("\(done) 完成") }
        if parts.isEmpty { return board.agentPanes.isEmpty ? "Rex Island" : "都歇着呢" }
        return parts.joined(separator: " · ")
    }
}

private struct Section<Content: View>: View {
    let title: String
    let count: Int
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text("\(count)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.tertiary)
            }
            .padding(.leading, 6)
            content
        }
    }
}

private struct Banner: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let button: String?
    let action: () -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let button { Button(button, action: action).buttonStyle(PillButtonStyle(kind: .secondary)) }
            if let onDismiss { IconButton(symbol: "xmark", help: "不再提示", action: onDismiss) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

private struct EmptyState: View {
    let rexHealth: AppModel.RexHealth

    var body: some View {
        VStack(spacing: 6) {
            Text("Rex 里还没有 agent 在跑").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
            Text("在 Rex 里启动 claude 或 codex，它们会出现在这里。")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(hovering ? Color.white : Theme.secondary)
                .frame(width: 28, height: 24)
                .background(Circle().fill(hovering ? Theme.card : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Rows

/// One agent pane. Click to jump to it in Rex.
struct PaneRow: View {
    let pane: Pane
    @ObservedObject var model: AppModel
    let actions: NotchActions
    @State private var hovering = false

    var body: some View {
        Button { actions.reveal(pane.id) } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    AgentBadge(agent: pane.agent, size: 22)
                    Circle().fill(Theme.color(for: pane.state))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(PaneText.title(pane))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(pane.state == .idle ? Theme.secondary : Theme.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let context = model.claudeSessions[pane.id]?.contextPercent {
                            Text("ctx \(Format.percent(context))")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.color(forUsage: context))
                        }
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(Format.ago(pane.stateSince, now: context.date))
                                .font(.system(size: 10.5, design: .rounded))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    HStack(spacing: 6) {
                        if pane.state == .working { Spinner(size: 9) }
                        Text(PaneText.activity(pane))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(PaneText.place(pane))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("在 Rex 里打开")
    }
}

// MARK: Usage

/// Plan limits and today's tokens, one row per agent, in columns so the two rows line up.
struct UsageFooter: View {
    @ObservedObject var model: AppModel
    let actions: NotchActions

    var body: some View {
        VStack(spacing: 8) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                // Limits in a grid on the left, today's tokens pinned right; fixed row heights keep the two in step.
                HStack(alignment: .top, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: Self.rowSpacing) {
                        row(.claude, model.claudeUsage, now: context.date,
                            empty: model.integrations.claudeStatusLine ? "等 Claude Code 下次刷新状态栏" : "接入状态栏后显示额度",
                            setup: model.integrations.claudeStatusLine ? nil : actions.openSettings)
                        row(.codex, model.codexUsage, now: context.date, empty: "用一次 Codex 后显示额度", setup: nil)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: Self.rowSpacing) {
                        today(model.claudeUsage)
                        today(model.codexUsage)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func row(_ agent: AgentKind, _ usage: ProviderUsage?, now: Date, empty: String, setup: (() -> Void)?) -> some View {
        GridRow(alignment: .center) {
            HStack(spacing: 6) {
                AgentBadge(agent: agent, size: 16)
                Text(agent == .claude ? "Claude" : "Codex").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.primary)
                if let plan = usage?.plan {
                    Text(plan.capitalized).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).stroke(Theme.hairline))
                }
            }
            .fixedSize()
            .frame(height: Self.rowHeight)
            .padding(.trailing, 6)
            if let usage, !usage.windows.isEmpty {
                cells(usage.window(.fiveHour), label: "5h", now: now)
                cells(usage.window(.weekly), label: "本周", now: now)
            } else {
                HStack(spacing: 8) {
                    Text(empty).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    if let setup {
                        Button("接入", action: setup).buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.blue)
                    }
                }
                .gridCellColumns(8)
            }
        }
    }

    private static let rowHeight: CGFloat = 18
    private static let rowSpacing: CGFloat = 8

    private func today(_ usage: ProviderUsage?) -> some View {
        Group {
            if let today = usage?.today, today.total > 0 {
                Text("今日 \(Format.tokens(today.total))")
                    .help("输入 \(Format.tokens(today.input)) · 输出 \(Format.tokens(today.output)) · 缓存读 \(Format.tokens(today.cacheRead)) · 缓存写 \(Format.tokens(today.cacheWrite))")
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 11, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Theme.secondary)
        .fixedSize()
        .frame(height: Self.rowHeight)
    }

    /// Four grid cells for one window: label, bar, percent (with a pace mark), time to reset.
    @ViewBuilder
    private func cells(_ window: LimitWindow?, label: String, now: Date) -> some View {
        if let window {
            let pace = window.pace(now: now) ?? 0
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).fixedSize()
            UsageBar(percent: window.usedPercent)
            HStack(spacing: 3) {
                Text(Format.percent(window.usedPercent))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.color(forUsage: window.usedPercent))
                if pace > 0.1, window.usedPercent < 100 {
                    Text("偏快").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.amber)
                }
            }
            .monospacedDigit()
            .fixedSize()
            .gridColumnAlignment(.trailing)
            .help(helpText(window, now: now, pace: pace))
            Text(window.resetsAt.map { Format.span($0.timeIntervalSince(now)) } ?? "")
                .font(.system(size: 10.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiary)
                .fixedSize()
                .padding(.trailing, 8)
        } else {
            Color.clear.frame(width: 0, height: 0)
            Color.clear.frame(width: 0, height: 0)
            Color.clear.frame(width: 0, height: 0)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func helpText(_ window: LimitWindow, now: Date, pace: Double) -> String {
        var text = "\(window.span == .fiveHour ? "5 小时窗口" : "本周")已用 \(Format.percent(window.usedPercent))"
        if let resets = Format.resets(window.resetsAt, now: now) { text += "，\(resets)" }
        if pace > 0.1 { text += "。用量比时间快 \(Int((pace * 100).rounded())) 个百分点" }
        return text
    }
}

struct UsageBar: View {
    let percent: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            Capsule().fill(Theme.color(forUsage: percent)).frame(width: max(2, 44 * min(1, percent / 100)))
        }
        .frame(width: 44, height: 5)
    }
}
