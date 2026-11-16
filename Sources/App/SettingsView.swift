import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        let status = model.integrations
        Form {
            Section {
                IntegrationRow(title: "Claude Code：审批、问答、计划",
                               detail: "在 ~/.claude/settings.json 加 PermissionRequest、UserPromptSubmit、Stop 三个 hook。只对 Rex 里的会话生效；Rex Island 没开时 Claude Code 照常在终端里问你。",
                               present: status.claudePresent, connected: status.claudeHooks) { model.setClaudeHooks($0) }
                IntegrationRow(title: "Claude Code：额度",
                               detail: "Claude Code 只把套餐额度交给状态栏，所以 Rex Island 会包一层状态栏命令：先记下额度，再原样运行你现在的状态栏（比如 claude-hud）。断开时恢复原样。",
                               present: status.claudePresent, connected: status.claudeStatusLine) { model.setClaudeStatusLine($0) }
                IntegrationRow(title: "Codex：审批",
                               detail: "在 ~/.codex/hooks.json 加同样三个 hook。接入后，在 Codex 里运行一次 /hooks 信任它们，否则 Codex 会静默跳过。Codex 的提问暂时只能在终端里回答。",
                               present: status.codexPresent, connected: status.codexHooks) { model.setCodexHooks($0) }
                if let error = status.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Note(text: "只增删 Rex Island 自己的条目。每个文件第一次被改动前，会在旁边留一份 .rexisland-backup。")
            } header: {
                Text("接入")
            }

            Section("Rex") {
                LabeledContent("状态") { Text(rexText) }
            }

            Section("通用") {
                Toggle("需要你时播放提示音", isOn: Binding(get: { model.soundsEnabled }, set: { model.soundsEnabled = $0 }))
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section {
                ShortcutRow(title: "打开或收起面板（任何地方）", keys: ["⌃", "⌥", "N"])
                ShortcutRow(title: "允许 / 提交回答 / 批准计划", keys: ["⏎"])
                ShortcutRow(title: "拒绝", keys: ["⌘", "⌫"])
                ShortcutRow(title: "选择第几个选项", keys: ["1", "–", "9"])
                ShortcutRow(title: "切换请求", keys: ["↑", "↓"])
                ShortcutRow(title: "收起面板", keys: ["Esc"])
                Note(text: "除第一项外，其余快捷键只在用快捷键或点击打开面板后才生效，不会抢走你在别的应用里的输入。")
            } header: {
                Text("快捷键")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshIntegrations() }
    }

    private var rexText: String {
        switch model.rexHealth {
        case .connecting: "连接中…"
        case .connected(let version): "已连接" + (version.map { " · \($0)" } ?? "")
        case .unreachable: "连不上 Rex 服务，会自动重连"
        case .missing: "找不到 rex 命令"
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// A gray explanatory line inside a section. (A Form footer wraps at half width and centers its lines.)
private struct Note: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: [String]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if key == "–" {
                        Text("–").foregroundStyle(.secondary)
                    } else {
                        Text(key)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .frame(minWidth: 20, minHeight: 20)
                            .padding(.horizontal, key.count > 1 ? 4 : 0)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                    }
                }
            }
        }
    }
}

private struct IntegrationRow: View {
    let title: String
    let detail: String
    let present: Bool
    let connected: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    if connected {
                        Label("已接入", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                            .font(.caption).foregroundStyle(.green)
                    } else if !present {
                        Text("未安装").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(connected ? "断开" : "接入") { set(!connected) }
                .disabled(!present && !connected)
        }
        .padding(.vertical, 2)
    }
}

/// A plain window for the settings, brought to the front when opened.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = "Rex Island 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // An accessory app isn't always granted activation; still put the window in front.
        window?.orderFrontRegardless()
    }
}
