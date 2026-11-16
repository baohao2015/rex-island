import AppKit
import Carbon

@main
enum RexIslandMain {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: arguments[index + 1])) }
            return
        }
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var notch: NotchController?
    private var settings: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy at a time: a second one couldn't bind the bridge socket anyway.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            others.first?.activate()
            NSApp.terminate(nil)
            return
        }

        let settings = SettingsWindowController(model: model)
        self.settings = settings
        var notchRef: NotchController?
        let actions = NotchActions(
            resolve: { [weak self] id, resolution in self?.model.resolve(id, resolution) },
            answerInTerminal: { [weak self] id in self?.model.answerInTerminal(id); notchRef?.close() },
            reveal: { [weak self] block in self?.model.reveal(block: block); notchRef?.close() },
            openSettings: { notchRef?.close(); settings.show() },
            openPanel: { notchRef?.open() },
            close: { notchRef?.close() }
        )
        let notch = NotchController(model: model, actions: actions)
        notchRef = notch
        self.notch = notch
        model.onAlert = { [weak notch] alert in notch?.present(alert) }
        model.onTogglePanel = { [weak notch] in notch?.toggle() }
        model.onOpenSettings = { settings.show() }
        model.onResolved = { [weak notch] resolution in
            switch resolution {
            case .deny, .revisePlan: notch?.state.face.react(.deny)
            default: notch?.state.face.react(.approve)
            }
        }
        model.start()
        notch.show()
        setUpStatusItem()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), id: 1) { [weak notch] in
            notch?.toggle()
        }
        if !model.integrations.claudeHooks && !model.integrations.codexHooks {
            settings.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "eyes", accessibilityDescription: "Rex Island")
        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板（⌃⌥N）", action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Rex Island", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() { notch?.toggle() }
    @objc private func openSettings() { settings?.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
