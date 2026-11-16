import AppKit
import Combine
import SwiftUI

/// UI state of the notch: how open it is, and which request has the keyboard.
@MainActor
final class NotchState: ObservableObject {
    enum Presentation: Equatable {
        /// Nothing running: only the physical notch.
        case hidden
        /// Ears beside the notch: the face and a count.
        case compact
        /// A short banner for something new; it shrinks back by itself.
        case peek(AppModel.Alert)
        case expanded
    }

    enum KeyCommand: Equatable {
        case primary, deny, option(Int)
    }

    @Published var presentation = Presentation.hidden
    @Published var notchSize: CGSize
    /// The black shape's frame in window coordinates (top-left origin), reported by the view.
    @Published var shapeFrame: CGRect = .zero
    /// The attention item that's open in the panel and takes keyboard shortcuts.
    @Published var selection: String?
    /// Incremented per key press; the selected card reacts to `command`.
    @Published private(set) var commandSequence = 0
    private(set) var command: KeyCommand?
    /// A text field in the panel has focus: stay open, and let keys go to the field.
    @Published var editing = false
    let face = FaceState()

    init(notchSize: CGSize) {
        self.notchSize = notchSize
    }

    func send(_ command: KeyCommand) {
        self.command = command
        commandSequence += 1
    }
}

/// Owns the notch panel: placement, pointer tracking, opening and closing, keyboard.
@MainActor
final class NotchController {
    static let windowSize = CGSize(width: 780, height: 760)
    private static let hoverOpenDelay: TimeInterval = 0.12
    private static let hoverCloseDelay: TimeInterval = 0.5
    private static let clickHold: TimeInterval = 1.5

    let state: NotchState
    private let model: AppModel
    private let panel: NotchPanel
    private var geometry: NotchGeometry?
    private var timer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var hovering = false
    private var holdUntil = Date.distantPast
    /// Opened from the keyboard: stays open until Esc, the shortcut again, or a click elsewhere.
    private var keyboardOpen = false
    private var peek: (alert: AppModel.Alert, until: Date)?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, actions: NotchActions) {
        self.model = model
        let screen = NotchGeometry.preferredScreen()
        geometry = screen.map(NotchGeometry.init)
        state = NotchState(notchSize: geometry?.notchSize ?? CGSize(width: 180, height: 32))
        panel = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.windowSize))
        let root = NotchRootView(model: model, state: state, actions: actions)
        let host = FirstMouseHostingView(rootView: root)
        // The window has a fixed size; don't recompute its constraints on every SwiftUI update.
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: Self.windowSize)
        panel.contentView = host

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.panel { self.holdUntil = Date().addingTimeInterval(Self.clickHold) }
            }
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.keyboardOpen, !self.interactiveRect().contains(NSEvent.mouseLocation) else { return }
                self.close()
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        } as Any)

        model.$board.receive(on: RunLoop.main).sink { [weak self] board in
            MainActor.assumeIsolated { self?.syncSelection(board) }
        }.store(in: &cancellables)
    }

    func show() {
        place()
        panel.orderFrontRegardless()
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Something new needs a moment in the notch.
    func present(_ alert: AppModel.Alert) {
        let duration: TimeInterval
        switch alert {
        case .attention(let id):
            duration = 8
            state.selection = id
        case .finished:
            duration = 3.5
        }
        peek = (alert, Date().addingTimeInterval(duration))
        update()
    }

    /// The keyboard shortcut: open with keyboard focus, or close.
    func toggle() {
        if state.presentation == .expanded {
            close()
        } else {
            keyboardOpen = true
            update()
            panel.makeKey()
        }
    }

    /// Opens the panel and keeps it open, e.g. from a banner's "查看".
    func open() {
        keyboardOpen = true
        update()
        panel.makeKey()
    }

    func close() {
        keyboardOpen = false
        hovering = false
        holdUntil = .distantPast
        peek = nil
        state.editing = false
        update()
        if panel.isKeyWindow {
            // Hand the keyboard back to the app the user was in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: Private

    private func place() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        self.geometry = geometry
        state.notchSize = geometry.notchSize
        let size = Self.windowSize
        panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func tick() {
        let now = Date()
        let pointer = NSEvent.mouseLocation
        let inside = interactiveRect().contains(pointer)
        // Setting this even to the same value invalidates tracking areas, which costs a redraw.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside {
            outsideSince = nil
            let since = insideSince ?? now
            insideSince = since
            if !hovering, now.timeIntervalSince(since) >= Self.hoverOpenDelay { hovering = true }
        } else {
            insideSince = nil
            if hovering {
                let since = outsideSince ?? now
                outsideSince = since
                if now.timeIntervalSince(since) >= Self.hoverCloseDelay, now >= holdUntil, !state.editing {
                    hovering = false
                    outsideSince = nil
                }
            }
        }
        followPointer(pointer)
        update(now: now)
    }

    private func update(now: Date = Date()) {
        let next: NotchState.Presentation
        if hovering || keyboardOpen || now < holdUntil || state.editing {
            next = .expanded
        } else if let peek, peek.until > now, isRelevant(peek.alert) {
            next = .peek(peek.alert)
        } else if model.board.mood != .asleep || model.limitWarning != nil {
            next = .compact
        } else {
            next = .hidden
        }
        if case .peek = next {} else if peek.map({ $0.until <= now }) ?? false { peek = nil }
        if next != state.presentation {
            if next == .expanded, state.presentation != .expanded { state.face.react(.hello) }
            withAnimation(Theme.spring) { state.presentation = next }
        }
    }

    private func isRelevant(_ alert: AppModel.Alert) -> Bool {
        switch alert {
        case .attention(let id): model.board.attention.contains { $0.id == id }
        case .finished(let block): model.board.panes[block]?.state == .done
        }
    }

    private func syncSelection(_ board: Board) {
        let ids = board.attention.map(\.id)
        if let selection = state.selection, ids.contains(selection) { return }
        state.selection = ids.first
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow, state.presentation == .expanded else { return false }
        // While typing in a field, every key belongs to the field.
        if state.editing { return false }
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: // Esc
            close()
            return true
        case 36, 76: // Return, Enter
            state.send(.primary)
            return true
        case 51 where command: // ⌘⌫
            state.send(.deny)
            return true
        case 125, 126: // ↓ ↑
            let ids = model.board.attention.map(\.id)
            guard !ids.isEmpty else { return false }
            let current = state.selection.flatMap { ids.firstIndex(of: $0) } ?? 0
            let next = event.keyCode == 125 ? min(current + 1, ids.count - 1) : max(current - 1, 0)
            state.selection = ids[next]
            return true
        default:
            if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                state.send(.option(digit - 1))
                return true
            }
            return false
        }
    }

    /// The face's eyes follow the pointer when it's near.
    private func followPointer(_ pointer: CGPoint) {
        let frame = panel.frame
        let faceX = frame.minX + state.shapeFrame.minX + 24
        let faceY = frame.maxY - state.notchSize.height / 2
        let dx = pointer.x - faceX, dy = faceY - pointer.y
        var target = CGSize.zero
        if hypot(dx, dy) < 600, panel.screen?.frame.contains(pointer) ?? false {
            target = CGSize(width: max(-1, min(1, dx / 220)), height: max(-1, min(1, dy / 160)))
        }
        let current = state.face.gaze
        let next = CGSize(width: current.width + (target.width - current.width) * 0.3,
                          height: current.height + (target.height - current.height) * 0.3)
        if abs(next.width - current.width) > 0.01 || abs(next.height - current.height) > 0.01 {
            state.face.gaze = next
        }
    }

    private func interactiveRect() -> CGRect {
        let frame = panel.frame
        let shape = state.shapeFrame
        var rect = CGRect(x: frame.minX + shape.minX, y: frame.maxY - shape.maxY, width: shape.width, height: shape.height)
        if let notch = geometry?.notchRect { rect = rect.isEmpty ? notch : rect.union(notch) }
        return rect.insetBy(dx: -4, dy: -4)
    }
}

/// What the notch views can ask for.
struct NotchActions {
    var resolve: (String, Resolution) -> Void
    var answerInTerminal: (String) -> Void
    var reveal: (String) -> Void
    var openSettings: () -> Void
    var openPanel: () -> Void
    var close: () -> Void
}
