import SwiftUI

/// One thing waiting on you. The selected card is open and takes the keyboard; others stay one line.
struct AttentionCard: View {
    let item: Attention
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    let actions: NotchActions
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if selected { content }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected || hovering ? Theme.cardHover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Theme.amber.opacity(0.35) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { if !selected { withAnimation(Theme.spring) { state.selection = item.id } } }
        .onHover { hovering = $0 }
    }

    private var pane: Pane? { model.board.panes[item.blockID] }

    private var header: some View {
        HStack(spacing: 8) {
            AgentBadge(agent: agent, size: 20)
            Text(headline).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.amber)
            if let pane {
                Text(PaneText.place(pane).isEmpty ? PaneText.title(pane) : PaneText.place(pane))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !selected {
                Text(summary).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(Format.ago(since, now: context.date)).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .decision(let decision, _):
            switch decision.content {
            case .permission(let permission):
                PermissionBody(decision: decision, permission: permission, state: state, actions: actions)
            case .questions(let questions):
                QuestionBody(decision: decision, questions: questions, state: state, actions: actions)
            case .plan(let plan):
                PlanBody(decision: decision, plan: plan, state: state, actions: actions)
            }
        case .waiting(let pane):
            WaitingBody(pane: pane, state: state, actions: actions)
        }
    }

    private var agent: AgentKind {
        switch item {
        case .decision(let decision, _): decision.agent
        case .waiting(let pane): pane.agent
        }
    }

    private var headline: String {
        switch item {
        case .decision(let decision, _): DecisionText.headline(decision)
        case .waiting(let pane): DecisionText.waiting(pane)
        }
    }

    private var summary: String {
        switch item {
        case .decision(let decision, _): DecisionText.summary(decision)
        case .waiting(let pane): pane.status?.msg ?? PaneText.title(pane)
        }
    }

    private var since: Date {
        switch item {
        case .decision(let decision, _): decision.createdAt
        case .waiting(let pane): pane.stateSince
        }
    }
}

/// Runs a card's keyboard command when that card is the selected one.
private struct KeyCommands: ViewModifier {
    @ObservedObject var state: NotchState
    let id: String
    let handle: (NotchState.KeyCommand) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: state.commandSequence) { _, _ in
            guard state.selection == id, let command = state.command else { return }
            handle(command)
        }
    }
}

private extension View {
    func keyCommands(_ state: NotchState, id: String, handle: @escaping (NotchState.KeyCommand) -> Void) -> some View {
        modifier(KeyCommands(state: state, id: id, handle: handle))
    }
}

// MARK: Permission

private struct PermissionBody: View {
    let decision: Decision
    let permission: Decision.Permission
    @ObservedObject var state: NotchState
    let actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("想\(permission.action)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                if let risk = permission.risk {
                    Label(risk, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.red)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.red.opacity(0.14)))
                }
                Spacer()
                Text(permission.tool).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
            }
            CodeBox(text: permission.subject)
            if let detail = permission.detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let diff = permission.diff, !(diff.removed.isEmpty && diff.added.isEmpty) { DiffBox(diff: diff) }
            HStack(spacing: 8) {
                Button("到 Rex 查看") { actions.answerInTerminal(decision.id) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .help("在终端里回答；这张卡片会关掉")
                Spacer()
                Button { actions.resolve(decision.id, .deny(nil)) } label: { HStack(spacing: 5) { Text("拒绝"); KeyHint(text: "⌘⌫") } }
                    .buttonStyle(PillButtonStyle(kind: permission.risk == nil ? .secondary : .danger))
                if let suggestion = decision.suggestion {
                    Button(suggestion.label) { actions.resolve(decision.id, .allowRemembering) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Button { actions.resolve(decision.id, .allow) } label: { HStack(spacing: 5) { Text("允许一次"); KeyHint(text: "⏎", dark: true) } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .keyCommands(state, id: "d:" + decision.id) { command in
            switch command {
            case .primary: actions.resolve(decision.id, .allow)
            case .deny: actions.resolve(decision.id, .deny(nil))
            case .option: break
            }
        }
    }
}

struct CodeBox: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
        }
        .frame(maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct DiffBox: View {
    let diff: Decision.Diff

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(diff.removed.enumerated()), id: \.offset) { line($0.element, sign: "−", color: Theme.red) }
            ForEach(Array(diff.added.enumerated()), id: \.offset) { line($0.element, sign: "+", color: Theme.green) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func line(_ text: String, sign: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign).foregroundStyle(color)
            Text(text.isEmpty ? " " : text).foregroundStyle(Theme.primary.opacity(0.85)).lineLimit(1)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

// MARK: Questions

private struct QuestionBody: View {
    let decision: Decision
    let questions: [Decision.Question]
    @ObservedObject var state: NotchState
    let actions: NotchActions
    @State private var index = 0
    @State private var picked: [[String]] = []
    @State private var typed: [String] = []
    @FocusState private var typing: Bool

    var body: some View {
        let question = questions[min(index, questions.count - 1)]
        VStack(alignment: .leading, spacing: 8) {
            if questions.count > 1 { steps }
            Text(question.text)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            if question.multiSelect {
                Text("可多选").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            }
            VStack(spacing: 3) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { offset, option in
                    OptionRow(number: offset + 1, option: option, multi: question.multiSelect,
                              chosen: current.contains(option.label)) { choose(offset) }
                }
            }
            TextField(question.options.isEmpty ? "输入回答…" : "其他回答…", text: typedBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                .focused($typing)
                .onSubmit(next)
            HStack(spacing: 8) {
                Button("到 Rex 回答") { actions.answerInTerminal(decision.id) }.buttonStyle(PillButtonStyle(kind: .quiet))
                Spacer()
                if index > 0 { Button("上一题") { index -= 1 }.buttonStyle(PillButtonStyle(kind: .secondary)) }
                Button { next() } label: {
                    HStack(spacing: 5) { Text(isLast ? "提交回答" : "下一题"); KeyHint(text: "⏎", dark: true) }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(answer(at: index).isEmpty)
            }
        }
        .onAppear {
            picked = Array(repeating: [], count: questions.count)
            typed = Array(repeating: "", count: questions.count)
        }
        .onChange(of: typing) { _, focused in state.editing = focused }
        .keyCommands(state, id: "d:" + decision.id) { command in
            switch command {
            case .primary: next()
            case .option(let offset): choose(offset)
            case .deny: break
            }
        }
    }

    private var isLast: Bool { index >= questions.count - 1 }
    private var current: [String] { picked.indices.contains(index) ? picked[index] : [] }

    private var typedBinding: Binding<String> {
        Binding(get: { typed.indices.contains(index) ? typed[index] : "" },
                set: { if typed.indices.contains(index) { typed[index] = $0 } })
    }

    private var steps: some View {
        HStack(spacing: 6) {
            ForEach(questions.indices, id: \.self) { offset in
                let done = !answer(at: offset).isEmpty
                Text(questions[offset].header ?? "问题 \(offset + 1)")
                    .font(.system(size: 10.5, weight: offset == index ? .semibold : .regular))
                    .foregroundStyle(offset == index ? Color.black : done ? Theme.primary : Theme.tertiary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(offset == index ? Color.white.opacity(0.9) : Theme.card))
                    .onTapGesture { index = offset }
            }
        }
    }

    /// A typed answer wins over picked options.
    private func answer(at offset: Int) -> [String] {
        if typed.indices.contains(offset), let text = RexParse.nonEmpty(typed[offset]) { return [text] }
        return picked.indices.contains(offset) ? picked[offset] : []
    }

    private func choose(_ offset: Int) {
        let question = questions[index]
        guard question.options.indices.contains(offset), picked.indices.contains(index) else { return }
        let label = question.options[offset].label
        typed[index] = ""
        if question.multiSelect {
            if let at = picked[index].firstIndex(of: label) { picked[index].remove(at: at) } else { picked[index].append(label) }
            return
        }
        picked[index] = [label]
        // One single-choice question: picking is answering, as in the terminal.
        if questions.count == 1 { submit() } else if !isLast {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { index += 1 }
        }
    }

    private func next() {
        guard !answer(at: index).isEmpty else { return }
        if isLast { submit() } else { index += 1 }
    }

    private func submit() {
        let answers = questions.indices.map(answer(at:))
        guard answers.allSatisfy({ !$0.isEmpty }) else {
            index = answers.firstIndex(where: \.isEmpty) ?? index
            return
        }
        state.editing = false
        actions.resolve(decision.id, .answers(answers))
    }
}

private struct OptionRow: View {
    let number: Int
    let option: Decision.Option
    let multi: Bool
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(chosen ? Color.black : Theme.secondary)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: multi ? 4 : 9).fill(chosen ? Theme.amber : Theme.card))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primary)
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.amber) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || chosen ? Theme.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Plan

private struct PlanBody: View {
    let decision: Decision
    let plan: String
    @ObservedObject var state: NotchState
    let actions: NotchActions
    @State private var feedback = ""
    @State private var full = false
    @FocusState private var typing: Bool

    private static let chips = ["先补测试", "改得更小一点", "先说风险和回滚", "分几步提交"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical) {
                MarkdownView(text: plan).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: full ? 380 : 190)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
            HStack(spacing: 6) {
                ForEach(Self.chips, id: \.self) { chip in
                    Button(chip) { feedback = feedback.isEmpty ? chip : feedback + "；" + chip }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Spacer(minLength: 0)
                Button(full ? "收起" : "展开") { withAnimation(Theme.spring) { full.toggle() } }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            TextField("修改意见…（会发给 agent，让它改计划）", text: $feedback)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                .focused($typing)
                .onSubmit { if !feedback.isEmpty { actions.resolve(decision.id, .revisePlan(feedback)) } }
            HStack(spacing: 8) {
                Button("到 Rex 查看") { actions.answerInTerminal(decision.id) }.buttonStyle(PillButtonStyle(kind: .quiet))
                Spacer()
                Button("提修改意见") { actions.resolve(decision.id, .revisePlan(feedback)) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(RexParse.nonEmpty(feedback) == nil)
                Button("批准，自动执行") { actions.resolve(decision.id, .approvePlan(autoAccept: true)) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("等于终端里的 “Yes, and use auto mode / auto-accept edits”")
                Button { actions.resolve(decision.id, .approvePlan(autoAccept: false)) } label: {
                    HStack(spacing: 5) { Text("批准计划"); KeyHint(text: "⏎", dark: true) }
                }
                .help("等于终端里的 “Yes, manually approve edits”")
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .onChange(of: typing) { _, focused in state.editing = focused }
        .keyCommands(state, id: "d:" + decision.id) { command in
            if command == .primary { actions.resolve(decision.id, .approvePlan(autoAccept: false)) }
        }
    }
}

// MARK: Waiting without a hook

private struct WaitingBody: View {
    let pane: Pane
    @ObservedObject var state: NotchState
    let actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pane.status?.msg ?? PaneText.title(pane))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(reason).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button { actions.reveal(pane.id) } label: { HStack(spacing: 5) { Text("到 Rex 处理"); KeyHint(text: "⏎", dark: true) } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .keyCommands(state, id: "p:" + pane.id) { command in
            if command == .primary { actions.reveal(pane.id) }
        }
    }

    private var reason: String {
        switch pane.status?.kind {
        case .auth: "要输入密码或登录，只能在终端里完成。"
        case .question where pane.agent == .codex: "Codex 的提问还不能在刘海里回答。"
        default: "这个请求没有经过 Rex Island 的 hook（可能还没接入），需要在 Rex 里处理。"
        }
    }
}
