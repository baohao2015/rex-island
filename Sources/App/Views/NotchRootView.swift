import SwiftUI

/// The whole notch. Three sizes: ears while agents run, a banner when something new happens,
/// and the panel on hover or from the keyboard.
struct NotchRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    let actions: NotchActions

    static let earWidth: CGFloat = 58
    /// Both ears widen together when the limit warning shows, so the black shape stays centered on
    /// the physical notch and nothing slides under it.
    static let wideEarWidth: CGFloat = 96
    static let peekWidth: CGFloat = 480
    static let panelWidth: CGFloat = 580

    var body: some View {
        let presentation = state.presentation
        let expanded = presentation == .expanded
        let topRadius: CGFloat = expanded ? 14 : 8

        ZStack(alignment: .top) {
            switch presentation {
            case .hidden:
                Color.clear.frame(width: state.notchSize.width, height: state.notchSize.height)
            case .compact:
                compact.transition(.opacity)
            case .peek(let alert):
                PeekView(model: model, state: state, alert: alert, actions: actions)
                    .frame(width: Self.peekWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            case .expanded:
                PanelView(model: model, state: state, actions: actions)
                    .frame(width: Self.panelWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(.horizontal, topRadius)
        .background(
            NotchShape(topRadius: topRadius, bottomRadius: expanded ? 24 : presentation == .compact ? 11 : 20)
                .fill(Color.black)
                .opacity(presentation == .hidden ? 0 : 1)
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 18, y: 8)
        )
        .background(
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named("notch"))
                Color.clear
                    .onAppear { state.shapeFrame = frame }
                    .onChange(of: frame) { _, newFrame in state.shapeFrame = newFrame }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "notch")
        .environment(\.colorScheme, .dark)
    }

    private var compact: some View {
        let height = state.notchSize.height
        let warning = model.limitWarning
        let board = model.board
        let ear = warning == nil ? Self.earWidth : Self.wideEarWidth
        return HStack(spacing: 0) {
            Eyes(mood: board.mood, face: state.face)
                .frame(width: ear, height: height)
            Color.clear.frame(width: state.notchSize.width, height: height)
            HStack(spacing: 8) {
                if let warning { LimitBadge(warning: warning) }
                EarIndicator(board: board)
            }
            .frame(width: ear, height: height)
        }
    }
}

/// The right ear: what's waiting, else what's running, else what just finished.
struct EarIndicator: View {
    let board: Board

    var body: some View {
        let waiting = board.attention.count
        let working = board.panes(in: .working).count
        let done = board.panes(in: .done).count
        Group {
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Capsule().fill(Theme.amber))
                    .accessibilityLabel("\(waiting) 个在等你")
            } else if working > 0 {
                HStack(spacing: 4) {
                    Spinner(size: 10)
                    Text("\(working)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondary)
                }
                .accessibilityLabel("\(working) 个在干活")
            } else if done > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                    Text("\(done)").font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Theme.green)
                .accessibilityLabel("\(done) 个刚完成")
            }
        }
    }
}

struct Spinner: View {
    var size: CGFloat = 12
    var color: Color = Theme.blue

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 10)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size * 0.16), lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
    }
}

/// The fullest plan window, beside the notch: a ring and its percentage.
struct LimitBadge: View {
    let warning: AppModel.LimitWarning

    var body: some View {
        HStack(spacing: 4) {
            LimitRing(percent: warning.window.usedPercent, size: 12)
            Text(Format.percent(warning.window.usedPercent))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.color(forUsage: warning.window.usedPercent))
        }
        .help("\(warning.provider.displayName) \(warning.window.span == .fiveHour ? "5 小时" : "本周")额度已用 \(Format.percent(warning.window.usedPercent))")
    }
}

/// A ring for one plan limit.
struct LimitRing: View {
    let percent: Double
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(1, percent / 100))
                .stroke(Theme.color(forUsage: percent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("额度已用 \(Format.percent(percent))")
    }
}

// MARK: Peek

/// A banner for one new thing. Permission requests can be answered right here; anything else opens the panel.
struct PeekView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    let alert: AppModel.Alert
    let actions: NotchActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Eyes(mood: model.board.mood, face: state.face).frame(width: NotchRootView.earWidth, height: state.notchSize.height)
                Spacer()
                EarIndicator(board: model.board).frame(width: NotchRootView.earWidth)
            }
            .frame(height: state.notchSize.height)
            content
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
    }

    @ViewBuilder private var content: some View {
        switch alert {
        case .attention(let id):
            if let item = model.board.attention.first(where: { $0.id == id }) {
                attention(item)
            }
        case .finished(let block):
            if let pane = model.board.panes[block] {
                HStack(spacing: 10) {
                    AgentBadge(agent: pane.agent, size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("收工了 · \(PaneText.title(pane))")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.green).lineLimit(1)
                        Text(PaneText.activity(pane)).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("查看") { actions.reveal(block) }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
        }
    }

    @ViewBuilder private func attention(_ item: Attention) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .decision(let decision, let pane):
                AgentBadge(agent: decision.agent, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(DecisionText.headline(decision)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.amber)
                        if let pane { Text(PaneText.place(pane)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                    }
                    Text(DecisionText.summary(decision)).font(.system(size: 12.5)).foregroundStyle(Theme.primary).lineLimit(1)
                }
                Spacer(minLength: 8)
                // A risky command is never one click away: it opens the full card first.
                if case .permission(let permission) = decision.content, permission.risk == nil {
                    Button("拒绝") { actions.resolve(decision.id, .deny(nil)) }.buttonStyle(PillButtonStyle(kind: .secondary))
                    Button("允许") { actions.resolve(decision.id, .allow) }.buttonStyle(PillButtonStyle(kind: .primary))
                } else {
                    Button("查看") { state.selection = item.id; actions.openPanel() }.buttonStyle(PillButtonStyle(kind: .primary))
                }
            case .waiting(let pane):
                AgentBadge(agent: pane.agent, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(DecisionText.waiting(pane)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.amber)
                        Text(PaneText.place(pane)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    Text(pane.status?.msg ?? PaneText.title(pane)).font(.system(size: 12.5)).foregroundStyle(Theme.primary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("到 Rex 处理") { actions.reveal(pane.id) }.buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
    }
}

/// Words for a pane, shared by rows, banners and cards.
enum PaneText {
    static func title(_ pane: Pane) -> String {
        pane.title ?? Format.oneLine(pane.lastPrompt, limit: 80) ?? pane.project ?? pane.agent.displayName
    }

    /// "rex-island · main · api"
    static func place(_ pane: Pane) -> String {
        let tab = pane.windowLabel == pane.project ? nil : pane.windowLabel
        return [pane.project, pane.branch, tab].compactMap { $0 }.joined(separator: " · ")
    }

    static func activity(_ pane: Pane) -> String {
        switch pane.state {
        // Codex reports no message while it works; the prompt you gave it says more than "working".
        case .working: pane.status?.msg ?? Format.oneLine(pane.lastPrompt, limit: 80).map { "在做：" + $0 } ?? "在干活…"
        case .done: Format.oneLine(pane.lastMessage) ?? pane.status?.msg ?? "做完了"
        case .blocked: pane.status?.msg ?? DecisionText.waiting(pane)
        case .error: pane.status?.msg ?? "冒烟了"
        case .idle: Format.oneLine(pane.lastMessage) ?? "等你下一句"
        }
    }
}
