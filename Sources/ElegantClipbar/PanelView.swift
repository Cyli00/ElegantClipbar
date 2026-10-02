import SwiftUI

struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var preferences: Preferences
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.page != .history { pageHeading }
            Group {
                switch state.page {
                case .history: history
                case .settings: SettingsView(state: state, preferences: preferences)
                case .preview: PreviewView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            feedback
            Divider()
            footer
        }
        .font(PanelStyle.body)
        .background(PanelStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous)
                .strokeBorder(PanelStyle.border.opacity(0.7), lineWidth: PanelStyle.stroke)
                .allowsHitTesting(false)
        }
        .frame(width: PanelStyle.width)
        .onAppear { searchFocused = state.page == .history }
        .onChange(of: state.page) { page in searchFocused = page == .history }
        .onChange(of: state.pendingDeletion != nil) { presented in state.setModalPresented?(presented) }
        .alert(L10n.text("删除这条历史记录？", "Delete this history entry?"), isPresented: Binding(
            get: { state.pendingDeletion != nil },
            set: { if !$0 { state.pendingDeletion = nil } }
        ), presenting: state.pendingDeletion) { record in
            Button(L10n.text("取消", "Cancel"), role: .cancel) { state.pendingDeletion = nil }
            Button(L10n.text("删除", "Delete"), role: .destructive) { state.delete(record) }
        } message: { _ in
            Text(L10n.text("删除后无法恢复。文件记录对应的原文件会保留。", "This cannot be undone. Original files are kept."))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if let image = BrandIcon.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "clipboard.fill")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                }
            }
                .frame(width: PanelStyle.logoSize, height: PanelStyle.logoSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("ElegantClipbar")
                    .font(PanelStyle.title)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(state.isPaused ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(state.isDemo ? L10n.text("演示模式", "Demo mode") : state.isPaused ? L10n.text("已暂停记录", "Capture paused") :
                            L10n.text("正在记录剪贴板", "Capturing clipboard"))
                        .font(PanelStyle.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            HStack(spacing: 0) {
                PanelIconButton(symbol: state.isPaused ? "play.circle" : "pause.circle",
                                label: state.isPaused ? L10n.text("继续记录", "Resume capture") : L10n.text("暂停记录", "Pause capture")) {
                    state.isPaused.toggle()
                }
                PanelIconButton(symbol: "gearshape", label: L10n.text("设置（⌘,）", "Settings (⌘,)")) {
                    if state.page == .settings { state.goBack() }
                    else { state.page = .settings }
                }
                .foregroundStyle(state.page == .settings ? Color.accentColor : Color.secondary)
                PanelIconButton(symbol: "power", label: L10n.text("退出 ElegantClipbar（⌘Q）", "Quit ElegantClipbar (⌘Q)")) {
                    state.requestQuit?()
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelStyle.padding)
    }

    private var pageHeading: some View {
        HStack(spacing: 4) {
            PanelIconButton(symbol: "chevron.left", label: L10n.text("返回历史", "Back to history")) { state.goBack() }
            Text(state.page == .settings ? L10n.text("设置", "Settings") : L10n.text("预览", "Preview"))
                .font(PanelStyle.body.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, PanelStyle.padding)
        .padding(.bottom, 4)
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("搜索历史", "Search history"), text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel(L10n.text("搜索历史", "Search history"))
                    .onChange(of: state.query) { _ in state.reload(resetLimit: true) }
                if !state.query.isEmpty {
                    Button {
                        state.query = ""
                        searchFocused = true
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help(L10n.text("清除搜索", "Clear search"))
                        .accessibilityLabel(L10n.text("清除搜索", "Clear search"))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(PanelStyle.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                    .strokeBorder(searchFocused ? Color.accentColor.opacity(0.5) : PanelStyle.border.opacity(0.5), lineWidth: PanelStyle.stroke)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            HStack(spacing: 6) {
                Text(L10n.text("历史记录", "History")).fontWeight(.semibold)
                Text(state.totalCount.formatted())
                    .font(PanelStyle.caption)
                    .padding(.horizontal, 5)
                    .background(PanelStyle.hover, in: Capsule())
                Spacer()
                Text(L10n.text("↑↓ 选择 · ↵ 粘贴", "↑↓ Select · ↵ Paste"))
                    .font(PanelStyle.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.records) { record in
                            HistoryRow(record: record, selected: state.selectedID == record.id,
                                       paste: { state.paste(record) },
                                       preview: { state.showPreview(record) },
                                       pin: { state.togglePin(record) })
                                .disabled(state.isLoading || state.isPasting)
                                .id(record.id)
                                .contextMenu {
                                    Button(L10n.text("粘贴", "Paste")) { state.paste(record) }
                                    Button(L10n.text("复制", "Copy")) { state.paste(record, copyOnly: true) }
                                    if record.kind != .image {
                                        Button(L10n.text("粘贴为纯文本", "Paste as plain text")) { state.paste(record, plainTextOnly: true) }
                                    }
                                    Button(L10n.text("预览", "Preview")) { state.showPreview(record) }
                                    Button(record.isPinned ? L10n.text("取消置顶", "Unpin") : L10n.text("置顶", "Pin")) { state.togglePin(record) }
                                    Divider()
                                    Button(L10n.text("删除…", "Delete…"), role: .destructive) { state.pendingDeletion = record }
                                }
                        }
                        if state.records.count < state.totalCount {
                            Button(L10n.text("加载更多", "Load more")) { state.loadMore() }
                                .disabled(state.isLoading)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, PanelStyle.padding)
                    .padding(.bottom, PanelStyle.padding)
                }
                .overlay {
                    if state.records.isEmpty {
                        if state.isLoading { ProgressView().controlSize(.small) }
                        else { emptyState }
                    }
                }
                .onChange(of: state.selectedID) { id in
                    if let id { scroll.scrollTo(id) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: state.query.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(state.query.isEmpty ? L10n.text("还没有历史记录", "No clipboard history yet") : L10n.text("没有匹配的记录", "No matching entries"))
            Text(state.query.isEmpty ? L10n.text("复制一段文字、图片或文件，即可在这里找到。", "Copy text, an image or a file to find it here.") :
                    L10n.text("试试其他关键词，或清除搜索。", "Try another keyword, or clear the search."))
                .font(PanelStyle.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
    }

    @ViewBuilder private var feedback: some View {
        if let status = state.status {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: state.statusIsError ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(state.statusIsError ? Color.orange : Color.secondary)
                    Text(status).font(PanelStyle.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { state.status = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.text("关闭提示", "Dismiss message"))
                }
                if state.needsAccessibility {
                    Button(L10n.text("开启辅助功能权限…", "Enable Accessibility…")) { state.requestAccessibility() }
                        .font(PanelStyle.caption)
                } else if state.statusIsError {
                    Button(L10n.text("重试读取历史", "Retry loading history")) { state.retryStorage() }
                        .font(PanelStyle.caption)
                }
            }
            .padding(PanelStyle.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelStyle.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
            Text(preferences.shortcut.displayString)
            Spacer(minLength: 0)
            if state.isPasting { ProgressView().controlSize(.mini) }
            Text(L10n.text("esc 收起", "esc Hide"))
        }
        .font(PanelStyle.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

private struct HistoryRow: View {
    let record: ClipboardRecord
    let selected: Bool
    let paste: () -> Void
    let preview: () -> Void
    let pin: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 3) {
            Button(action: paste) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: record.kind.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(record.kind.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.preview.isEmpty ? record.kind.title : record.preview)
                            .font(.system(size: PanelStyle.bodySize, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            Text(record.source?.name ?? record.kind.title)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .background(PanelStyle.hover, in: Capsule())
                            Spacer(minLength: 2)
                            Text(record.lastCopiedAt, style: .time)
                        }
                        .font(PanelStyle.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: PanelStyle.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("粘贴：", "Paste: ") + (record.preview.isEmpty ? record.kind.title : record.preview))
            VStack(spacing: 0) {
                PanelIconButton(symbol: record.isPinned ? "pin.fill" : "pin",
                                label: record.isPinned ? L10n.text("取消置顶", "Unpin") : L10n.text("置顶", "Pin"), action: pin)
                    .foregroundStyle(record.isPinned ? Color.accentColor : Color.secondary)
                PanelIconButton(symbol: "eye", label: L10n.text("预览", "Preview"), action: preview)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .background(selected ? PanelStyle.selection : hovered ? PanelStyle.hover : .clear,
                    in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 2, height: 22) }
        }
        .onHover { hovered = $0 }
    }
}
