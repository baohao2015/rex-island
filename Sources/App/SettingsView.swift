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
            } header: {
                Text("接入")
            } footer: {
                Text("每个文件第一次被改动前，会在旁边留一份 .rexisland-backup。只增删 Rex Island 自己的条目。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Rex") {
                LabeledContent("状态") { Text(rexText) }
            }

            Section("通用") {
                Toggle("需要你时播放提示音", isOn: Binding(get: { model.soundsEnabled }, set: { model.soundsEnabled = $0 }))
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                LabeledContent("快捷键") {
                    Text("⌃⌥N 打开或收起面板。面板里：⏎ 允许/提交，⌘⌫ 拒绝，1–9 选选项，↑↓ 切换请求，Esc 收起")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
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
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
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
    }
}
