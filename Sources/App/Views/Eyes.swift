import SwiftUI

/// The notch's face: two eyes that say how the agents are doing at a glance.
/// Drawing adapted from Pip (github.com/Kikatsu/pip-notch, MIT).
struct Eyes: View {
    let mood: Mood
    var eyeWidth: CGFloat = 4.5
    @ObservedObject var face: FaceState

    var body: some View {
        TimelineView(.animation(minimumInterval: mood == .asleep || mood == .idle ? 1 / 6 : 1 / 10)) { context in
            Canvas { gc, size in
                let t = context.date.timeIntervalSinceReferenceDate
                var gc = gc
                gc.translateBy(x: face.gaze.width * eyeWidth * 0.6, y: face.gaze.height * eyeWidth * 0.35)
                EyeDrawing.draw(mood, reaction: face.reaction(at: context.date), time: t, in: &gc, size: size,
                                eyeWidth: eyeWidth, color: Theme.color(for: mood))
            }
        }
        .accessibilityLabel(label)
    }

    private var label: String {
        switch mood {
        case .needsYou: "有 agent 在等你"
        case .error: "有 agent 出错了"
        case .working: "agent 在干活"
        case .finished: "agent 干完了"
        case .idle: "agent 都闲着"
        case .asleep: "没有 agent 在运行"
        }
    }
}

/// Where the eyes look and how they just reacted. Kept apart from the rest so pointer tracking
/// only redraws the face.
@MainActor
final class FaceState: ObservableObject {
    enum Reaction { case approve, deny, hello }

    @Published var gaze: CGSize = .zero
    @Published private(set) var lastReaction: (Reaction, Date)?

    func react(_ reaction: Reaction) { lastReaction = (reaction, Date()) }

    func reaction(at date: Date) -> Reaction? {
        guard let (reaction, start) = lastReaction, date.timeIntervalSince(start) < 1.1 else { return nil }
        return reaction
    }
}

enum EyeDrawing {
    static func draw(_ mood: Mood, reaction: FaceState.Reaction?, time t: Double, in gc: inout GraphicsContext,
                     size: CGSize, eyeWidth w: CGFloat, color: Color) {
        let h = w * 1.4
        let cx = size.width / 2, cy = size.height / 2
        let spread = w * 1.2
        let fill = GraphicsContext.Shading.color(color)
        let stroke = StrokeStyle(lineWidth: max(1.4, w * 0.34), lineCap: .round, lineJoin: .round)

        func oval(_ x: CGFloat, _ y: CGFloat, _ ow: CGFloat, _ oh: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x - ow / 2, y: y - oh / 2, width: ow, height: oh))
        }
        func happyArcs(hop: CGFloat, tint: GraphicsContext.Shading) {
            for side in [-1.0, 1.0] {
                let x = cx + side * spread
                var arc = Path()
                arc.move(to: CGPoint(x: x - w * 0.6, y: cy + h * 0.18 + hop))
                arc.addQuadCurve(to: CGPoint(x: x + w * 0.6, y: cy + h * 0.18 + hop), control: CGPoint(x: x, y: cy - h * 0.55 + hop))
                gc.stroke(arc, with: tint, style: stroke)
            }
        }

        switch reaction {
        case .approve:
            happyArcs(hop: -abs(CGFloat(sin(t * 9))) * h * 0.15, tint: .color(Theme.green))
            return
        case .deny:
            for side in [-1.0, 1.0] {
                var line = Path()
                line.move(to: CGPoint(x: cx + side * spread - w * 0.55, y: cy))
                line.addLine(to: CGPoint(x: cx + side * spread + w * 0.55, y: cy))
                gc.stroke(line, with: fill, style: stroke)
            }
            return
        case .hello, nil:
            break
        }

        switch mood {
        case .idle:
            let blink = t.truncatingRemainder(dividingBy: 4.6) < 0.14
            let look = CGFloat(sin(t * 0.45)) * w * 0.25
            for side in [-1.0, 1.0] {
                gc.fill(oval(cx + side * spread + look, cy, w, h * (blink ? 0.12 : 1)), with: fill)
            }
        case .working:
            let look = CGFloat(sin(t * 2.6)) * w * 0.55
            for side in [-1.0, 1.0] {
                gc.fill(oval(cx + side * spread + look, cy + h * 0.05, w * 0.9, h * 0.8), with: fill)
            }
        case .needsYou:
            let bounce = -abs(CGFloat(sin(t * 4.2))) * h * 0.12
            for side in [-1.0, 1.0] {
                let x = cx + side * spread * 1.1
                gc.fill(oval(x, cy + bounce, w * 1.15, h * 1.15), with: fill)
                gc.fill(oval(x, cy + bounce + h * 0.2, w * 0.5, w * 0.5), with: .color(.black))
            }
        case .error:
            let jitter = t.truncatingRemainder(dividingBy: 2.2) < 0.5 ? CGFloat(sin(t * 48)) * w * 0.15 : 0
            let r = w * 0.5
            for side in [-1.0, 1.0] {
                let x = cx + side * spread + jitter
                var cross = Path()
                cross.move(to: CGPoint(x: x - r, y: cy - r))
                cross.addLine(to: CGPoint(x: x + r, y: cy + r))
                cross.move(to: CGPoint(x: x + r, y: cy - r))
                cross.addLine(to: CGPoint(x: x - r, y: cy + r))
                gc.stroke(cross, with: fill, style: stroke)
            }
        case .finished:
            happyArcs(hop: -abs(CGFloat(sin(t * 5))) * h * 0.18, tint: fill)
        case .asleep:
            let alpha = 0.35 + 0.35 * (sin(t * 1.4) + 1) / 2
            for side in [-1.0, 1.0] {
                let x = cx + side * spread
                var lid = Path()
                lid.move(to: CGPoint(x: x - w * 0.6, y: cy))
                lid.addQuadCurve(to: CGPoint(x: x + w * 0.6, y: cy), control: CGPoint(x: x, y: cy + h * 0.45))
                gc.stroke(lid, with: .color(color.opacity(alpha)), style: stroke)
            }
        }
    }
}
