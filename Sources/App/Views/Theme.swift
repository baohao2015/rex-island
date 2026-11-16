import SwiftUI

enum Theme {
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.16)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.40)
    static let red = Color(red: 1.0, green: 0.32, blue: 0.30)
    static let blue = Color(red: 0.40, green: 0.78, blue: 1.0)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.49, green: 0.53, blue: 1.0)
    static let codexTop = Color(red: 0.66, green: 0.58, blue: 1.0)
    static let codexBottom = Color(red: 0.25, green: 0.32, blue: 1.0)

    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.60)
    static let tertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.08)
    static let card = Color.white.opacity(0.065)
    static let cardHover = Color.white.opacity(0.10)
    static let field = Color.white.opacity(0.08)

    static func color(for agent: AgentKind) -> Color {
        switch agent {
        case .claude: claude
        case .codex: codex
        case .other: secondary
        }
    }

    static func color(for state: AgentState) -> Color {
        switch state {
        case .blocked: amber
        case .error: red
        case .working: blue
        case .done: green
        case .idle: tertiary
        }
    }

    static func color(for mood: Mood) -> Color {
        switch mood {
        case .needsYou: amber
        case .error: red
        case .finished: green
        case .working, .idle, .asleep: .white
        }
    }

    /// Plan-limit color: calm, warning from 70%, alarm from 90%.
    static func color(forUsage percent: Double) -> Color {
        percent >= 90 ? red : percent >= 70 ? amber : Color.white.opacity(0.75)
    }

    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.82)
}

/// A small agent mark, drawn here rather than shipping the vendors' artwork: Claude's orange
/// starburst, and Codex's blue-violet cloud with a `>_` prompt.
struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = 18

    var body: some View {
        Group {
            switch agent {
            case .claude:
                Canvas { gc, canvas in AgentMarks.claude(in: &gc, size: canvas) }
            case .codex:
                Canvas { gc, canvas in AgentMarks.codex(in: &gc, size: canvas) }
            case .other:
                Image(systemName: "terminal").font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.displayName)
    }
}

enum AgentMarks {
    /// Twelve tapered rays of alternating length around the center.
    static func claude(in gc: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for index in 0..<12 {
            let long = index % 2 == 0
            let length = side * (long ? 0.47 : 0.38)
            let width = side * (long ? 0.13 : 0.11)
            var ray = Path(roundedRect: CGRect(x: -width / 2, y: -length, width: width, height: length - side * 0.06),
                           cornerRadius: width / 2)
            ray = ray.applying(CGAffineTransform(rotationAngle: CGFloat(index) * .pi / 6))
                .applying(CGAffineTransform(translationX: center.x, y: center.y))
            gc.fill(ray, with: .color(Theme.claude))
        }
    }

    /// A scalloped cloud (a ring of overlapping circles) with a white prompt on it.
    static func codex(in gc: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var cloud = Path(ellipseIn: CGRect(x: center.x - side * 0.3, y: center.y - side * 0.3, width: side * 0.6, height: side * 0.6))
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            let petal = CGPoint(x: center.x + cos(angle) * side * 0.26, y: center.y + sin(angle) * side * 0.26)
            cloud.addEllipse(in: CGRect(x: petal.x - side * 0.2, y: petal.y - side * 0.2, width: side * 0.4, height: side * 0.4))
        }
        gc.fill(cloud, with: .linearGradient(Gradient(colors: [Theme.codexTop, Theme.codexBottom]),
                                             startPoint: CGPoint(x: center.x, y: 0), endPoint: CGPoint(x: center.x, y: size.height)))
        var prompt = Path()
        prompt.move(to: CGPoint(x: center.x - side * 0.2, y: center.y - side * 0.15))
        prompt.addLine(to: CGPoint(x: center.x - side * 0.06, y: center.y))
        prompt.addLine(to: CGPoint(x: center.x - side * 0.2, y: center.y + side * 0.15))
        prompt.move(to: CGPoint(x: center.x + side * 0.02, y: center.y + side * 0.15))
        prompt.addLine(to: CGPoint(x: center.x + side * 0.22, y: center.y + side * 0.15))
        gc.stroke(prompt, with: .color(.white.opacity(0.95)),
                  style: StrokeStyle(lineWidth: max(1.3, side * 0.085), lineCap: .round, lineJoin: .round))
    }
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: kind == .primary ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .foregroundStyle(foreground)
                .background(Capsule().fill(background))
                .overlay(Capsule().strokeBorder(border, lineWidth: 1))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: .black
            case .danger: Theme.red
            case .secondary, .quiet: Theme.primary
            }
        }

        private var background: Color {
            switch kind {
            case .primary: hovering ? .white : Color.white.opacity(0.9)
            case .secondary: hovering ? Theme.cardHover : Theme.card
            case .quiet: hovering ? Theme.card : .clear
            case .danger: hovering ? Theme.red.opacity(0.22) : Theme.red.opacity(0.12)
            }
        }

        private var border: Color {
            switch kind {
            case .primary, .quiet: .clear
            case .secondary: Theme.hairline
            case .danger: Theme.red.opacity(0.25)
            }
        }
    }
}

/// A key hint like "⏎" or "⌘1" drawn small beside a label.
struct KeyHint: View {
    let text: String
    var dark = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(dark ? Color.black.opacity(0.5) : Theme.tertiary)
    }
}
