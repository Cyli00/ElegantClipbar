import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var preferences: Preferences
    @State private var count = ""
    @State private var days = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(L10n.text("常规", "General")) {
                    settingToggle(L10n.text("开机启动", "Launch at login"), isOn: Binding(
                        get: { state.loginEnabled }, set: { state.setLaunchAtLogin($0) }
                    )).disabled(state.isDemo)
                    HStack {
                        Text(L10n.text("唤醒快捷键", "Shortcut"))
                        Spacer(minLength: 4)
                        Button(state.isRecordingShortcut ? L10n.text("按下组合键…", "Press shortcut…") : preferences.shortcut.displayString) {
                            if state.isRecordingShortcut { state.cancelShortcutRecording() }
                            else { state.startShortcutRecording() }
                        }
                        .help(L10n.text("点击录制，Esc 取消", "Click to record; Escape cancels"))
                        .disabled(state.isDemo)
                    }
                    Button(L10n.text("恢复 ⌥⌘V", "Restore ⌥⌘V")) { state.updateShortcut(.default) }
                        .font(PanelStyle.caption)
                        .disabled(state.isDemo)
                    caption(L10n.text("外观跟随系统明暗模式。", "Appearance follows the system."))
                }

                section(L10n.text("自动粘贴", "Automatic paste")) {
                    Label(state.pasteService.hasAccessibilityPermission ? L10n.text("辅助功能已授权", "Accessibility enabled") :
                            L10n.text("需要辅助功能权限", "Accessibility permission needed"),
                          systemImage: state.pasteService.hasAccessibilityPermission ? "checkmark.circle" : "hand.raised")
                    Button(L10n.text("打开辅助功能设置…", "Open Accessibility Settings…")) { state.requestAccessibility() }
                    caption(L10n.text("未授权时仍可复制，再按 ⌘V 粘贴。", "You can still copy and press ⌘V without permission."))
                }

                section(L10n.text("历史保留", "History retention")) {
                    valueField(L10n.text("最多条数", "Maximum entries"), value: $count)
                    valueField(L10n.text("保留天数", "Retention days"), value: $days)
                    Button(L10n.text("保存保留设置", "Save retention settings")) { saveRetention() }
                    caption(L10n.text("置顶记录不自动清理。普通记录超过任一限制即清理。", "Pinned entries are kept. Other entries are removed when either limit is exceeded."))
                }

                section(L10n.text("音效", "Sounds")) {
                    HStack {
                        settingToggle(L10n.text("记录成功", "Capture sound"), isOn: $preferences.recordSound)
                        PanelIconButton(symbol: "play.circle", label: L10n.text("试听记录音效", "Preview capture sound")) { SoundService.previewRecord() }
                    }
                    HStack {
                        settingToggle(L10n.text("执行粘贴", "Paste sound"), isOn: $preferences.pasteSound)
                        PanelIconButton(symbol: "play.circle", label: L10n.text("试听粘贴音效", "Preview paste sound")) { SoundService.previewPaste() }
                    }
                }

                section(L10n.text("排除应用", "Excluded apps")) {
                    if preferences.excludedApps.isEmpty {
                        caption(L10n.text("当前没有排除应用。", "No apps excluded."))
                    }
                    ForEach(preferences.excludedApps) { app in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).lineLimit(1)
                                Text(app.id).font(PanelStyle.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            PanelIconButton(symbol: "minus.circle", label: L10n.text("移除排除应用：", "Remove exclusion: ") + app.name) {
                                preferences.excludedApps.removeAll { $0.id == app.id }
                            }
                        }
                    }
                    Button(L10n.text("添加应用…", "Add app…")) { state.chooseExcludedApplication() }
                    caption(L10n.text("这些应用新复制的内容不会记录。", "New copies from these apps will not be recorded."))
                }

                section(L10n.text("本地备份", "Local backup")) {
                    HStack {
                        Button(L10n.text("导出…", "Export…")) { state.exportBackup() }
                        Button(L10n.text("导入…", "Import…")) { state.importBackup() }
                        if state.backupBusy { ProgressView().controlSize(.small) }
                    }
                    .disabled(state.backupBusy)
                    caption(L10n.text("备份包含历史正文和图片。导入会合并记录；仅支持 Swift 版备份。", "Backups contain clipboard text and images. Import merges entries; only native-version backups are supported."))
                    caption(L10n.text("文件仅保留位置；原文件移动或删除后将不可用。", "Files are stored as paths; moved or deleted files become unavailable."))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(12)
        }
        .onAppear {
            count = String(preferences.maxCount)
            days = String(preferences.maxAgeDays)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(PanelStyle.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(PanelStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func valueField(_ title: String, value: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: value)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 92)
                .accessibilityLabel(title)
        }
    }

    private func saveRetention() {
        guard let maxCount = Int(count), (1...100_000).contains(maxCount),
              let maxDays = Int(days), (1...36_500).contains(maxDays) else {
            state.report(L10n.text("条数请输入 1–100000，天数请输入 1–36500。", "Enter 1–100000 entries and 1–36500 days."), isError: true)
            return
        }
        preferences.maxCount = maxCount
        preferences.maxAgeDays = maxDays
        state.pruneHistory()
        state.report(L10n.text("保留设置已保存。", "Retention settings saved."))
    }
}
