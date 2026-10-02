import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    enum Page { case history, settings, preview }

    let preferences: Preferences
    let directory: URL
    let isDemo: Bool
    let pasteService = PasteService()
    private let io = DispatchQueue(label: "app.elegantclipbar.storage", qos: .userInitiated)
    private var store: ClipboardStore?
    private var subscriptions = Set<AnyCancellable>()
    private var requestID = UUID()
    private var visibleLimit = 100
    private var cleanupTimer: Timer?

    @Published var page: Page = .history
    @Published var records: [ClipboardRecord] = []
    @Published var totalCount = 0
    @Published var selectedID: UUID?
    @Published var query = ""
    @Published var isLoading = false
    @Published var isPasting = false
    @Published var isPaused = false { didSet { monitor.isPaused = isPaused } }
    @Published var status: String?
    @Published var statusIsError = false
    @Published var needsAccessibility = false
    @Published var previewRecord: ClipboardRecord?
    @Published var previewPayload: ClipboardPayload?
    @Published var pendingDeletion: ClipboardRecord?
    @Published var isRecordingShortcut = false
    @Published var loginEnabled = false
    @Published var backupBusy = false

    var targetApplication: NSRunningApplication?
    var hidePanel: (() -> Void)?
    var restorePanel: (() -> Void)?
    var requestQuit: (() -> Void)?
    var setModalPresented: ((Bool) -> Void)?
    var registerShortcut: ((GlobalHotKey.Shortcut) throws -> Void)?
    var suspendShortcut: (() -> Void)?

    lazy var monitor = ClipboardMonitor { [weak self] payload, source in
        self?.capture(payload, source: source)
    }

    init(directory: URL, isDemo: Bool, preferences: Preferences) {
        self.directory = directory
        self.isDemo = isDemo
        self.preferences = preferences
        do { store = try ClipboardStore(directory: directory) }
        catch { report(error.localizedDescription, isError: true) }
        preferences.$excludedApps.sink { [weak self] apps in
            self?.monitor.excludedBundleIdentifiers = Set(apps.map(\.id))
        }.store(in: &subscriptions)
        if !isDemo {
            loginEnabled = SMAppService.mainApp.status == .enabled
            monitor.start()
            cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pruneHistory() }
            }
        }
        pruneHistory()
    }

    func stop() {
        monitor.stop()
        cleanupTimer?.invalidate()
    }

    var selectedRecord: ClipboardRecord? { records.first { $0.id == selectedID } }

    func report(_ text: String, isError: Bool = false) {
        status = text
        statusIsError = isError
    }

    func reload(resetLimit: Bool = false) {
        if resetLimit { visibleLimit = 100 }
        let token = UUID()
        requestID = token
        let search = query
        let limit = visibleLimit
        isLoading = true
        perform({ store in
            (try store.records(query: search, limit: limit), try store.count(query: search))
        }) { [weak self] result in
            guard let self, self.requestID == token else { return }
            self.isLoading = false
            switch result {
            case .success(let value):
                self.records = value.0
                self.totalCount = value.1
                if !self.records.contains(where: { $0.id == self.selectedID }) {
                    self.selectedID = self.records.first?.id
                }
            case .failure(let error): self.report(error.localizedDescription, isError: true)
            }
        }
    }

    func loadMore() {
        guard !isLoading, records.count < totalCount else { return }
        visibleLimit += 100
        reload()
    }

    func moveSelection(_ delta: Int) {
        guard !records.isEmpty else { return }
        let current = records.firstIndex { $0.id == selectedID } ?? 0
        selectedID = records[min(max(current + delta, 0), records.count - 1)].id
    }

    func capture(_ payload: ClipboardPayload, source: ClipboardSource?) {
        let count = preferences.maxCount
        let days = preferences.maxAgeDays
        perform({ store in
            _ = try store.record(payload: payload, source: source)
            try store.prune(maxCount: count, maxAgeDays: days)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                SoundService.record(isEnabled: self.preferences.recordSound)
                self.reload()
            case .failure(let error): self.report(error.localizedDescription, isError: true)
            }
        }
    }

    func pruneHistory() {
        let count = preferences.maxCount
        let days = preferences.maxAgeDays
        perform({ try $0.prune(maxCount: count, maxAgeDays: days) }) { [weak self] result in
            if case .failure(let error) = result { self?.report(error.localizedDescription, isError: true) }
            self?.reload()
        }
    }

    func togglePin(_ record: ClipboardRecord) {
        perform({ try $0.setPinned(!record.isPinned, id: record.id) }) { [weak self] result in
            if case .failure(let error) = result { self?.report(error.localizedDescription, isError: true) }
            self?.pruneHistory()
        }
    }

    func delete(_ record: ClipboardRecord) {
        pendingDeletion = nil
        perform({ try $0.remove(id: record.id) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.report(L10n.text("已删除历史记录。", "History entry deleted."))
                if self.previewRecord?.id == record.id { self.goBack() }
                self.reload()
            case .failure(let error): self.report(error.localizedDescription, isError: true)
            }
        }
    }

    func showPreview(_ record: ClipboardRecord) {
        previewRecord = record
        previewPayload = nil
        selectedID = record.id
        page = .preview
        perform({ try $0.payload(for: record.id) }) { [weak self] result in
            guard let self, self.page == .preview, self.previewRecord?.id == record.id else { return }
            switch result {
            case .success(let payload): self.previewPayload = payload
            case .failure(let error): self.report(error.localizedDescription, isError: true)
            }
        }
    }

    func goBack() {
        if isRecordingShortcut { cancelShortcutRecording() }
        page = .history
        previewRecord = nil
        previewPayload = nil
    }

    func paste(_ record: ClipboardRecord, plainTextOnly: Bool = false, copyOnly: Bool = false) {
        guard !isPasting, !isLoading else { return }
        isPasting = true
        let target = targetApplication
        perform({ try $0.payload(for: record.id) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.isPasting = false
                self.report(error.localizedDescription, isError: true)
            case .success(let payload):
                if copyOnly {
                    defer { self.isPasting = false }
                    do {
                        try self.pasteService.write(payload, plainTextOnly: plainTextOnly)
                        self.monitor.ignoreCurrentChange()
                        self.report(L10n.text("已复制。", "Copied."))
                    } catch { self.report(error.localizedDescription, isError: true) }
                    return
                }
                Task { @MainActor in
                    if self.pasteService.hasAccessibilityPermission, target != nil { self.hidePanel?() }
                    let outcome = await self.pasteService.paste(payload, to: target, plainTextOnly: plainTextOnly) {
                        self.monitor.ignoreCurrentChange()
                    }
                    self.isPasting = false
                    switch outcome {
                    case .pasted:
                        self.needsAccessibility = false
                        self.status = nil
                        self.goBack()
                        SoundService.paste(isEnabled: self.preferences.pasteSound)
                    case .copiedOnly(let reason):
                        self.needsAccessibility = !self.pasteService.hasAccessibilityPermission
                        self.report(reason)
                        self.restorePanel?()
                    case .failure(let reason):
                        self.report(reason, isError: true)
                        self.restorePanel?()
                    }
                }
            }
        }
    }

    func requestAccessibility() {
        _ = pasteService.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func startShortcutRecording() {
        suspendShortcut?()
        isRecordingShortcut = true
    }

    func cancelShortcutRecording() {
        isRecordingShortcut = false
        do { try registerShortcut?(preferences.shortcut) }
        catch { report(error.localizedDescription, isError: true) }
    }

    func updateShortcut(_ value: GlobalHotKey.Shortcut) {
        do {
            try registerShortcut?(value)
            preferences.shortcut = value
            isRecordingShortcut = false
            report(L10n.text("唤醒快捷键已更新。", "Shortcut updated."))
        } catch {
            isRecordingShortcut = false
            try? registerShortcut?(preferences.shortcut)
            report(error.localizedDescription, isError: true)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled {
                report(L10n.text("请在系统设置的登录项中允许 ElegantClipbar。", "Allow ElegantClipbar in System Settings → Login Items."))
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { report(error.localizedDescription, isError: true) }
    }

    func chooseExcludedApplication() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        setModalPresented?(true)
        picker.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.setModalPresented?(false)
                guard response == .OK else { return }
                for url in picker.urls {
                    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                    if !self.preferences.excludedApps.contains(where: { $0.id == id }) {
                        self.preferences.excludedApps.append(ExcludedApp(id: id, name: url.deletingPathExtension().lastPathComponent))
                    }
                }
            }
        }
    }

    func exportBackup() {
        guard !backupBusy else { return }
        let picker = NSSavePanel()
        picker.nameFieldStringValue = "ElegantClipbar.clipbar"
        picker.allowedContentTypes = [UTType(filenameExtension: "clipbar") ?? .data]
        setModalPresented?(true)
        picker.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.setModalPresented?(false)
                guard response == .OK, let url = picker.url else { return }
                self.backupBusy = true
                self.perform({ try $0.exportBackup(to: url) }) { [weak self] result in
                    self?.backupBusy = false
                    switch result {
                    case .success: self?.report(L10n.text("备份已导出。", "Backup exported."))
                    case .failure(let error): self?.report(error.localizedDescription, isError: true)
                    }
                }
            }
        }
    }

    func importBackup() {
        guard !backupBusy else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [UTType(filenameExtension: "clipbar") ?? .data]
        picker.allowsMultipleSelection = false
        setModalPresented?(true)
        picker.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.setModalPresented?(false)
                guard response == .OK, let url = picker.url else { return }
                self.backupBusy = true
                self.perform({ try $0.importBackup(from: url) }) { [weak self] result in
                    guard let self else { return }
                    self.backupBusy = false
                    switch result {
                    case .success(let count):
                        self.report(L10n.text("已合并 \(count) 条新记录。", "Merged \(count) new entries."))
                        self.pruneHistory()
                    case .failure(let error): self.report(error.localizedDescription, isError: true)
                    }
                }
            }
        }
    }

    func retryStorage() {
        if store == nil {
            do { store = try ClipboardStore(directory: directory) }
            catch { report(error.localizedDescription, isError: true); return }
        }
        status = nil
        reload()
    }

    private func perform<Value>(_ operation: @escaping (ClipboardStore) throws -> Value,
                                completion: @escaping (Result<Value, Error>) -> Void) {
        guard let store else {
            isLoading = false
            completion(.failure(NSError(domain: "ElegantClipbar", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.text("无法打开历史存储，请检查数据目录权限后重试。", "Cannot open history. Check folder permissions and retry.")
            ])))
            return
        }
        io.async {
            let result = Result { try operation(store) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
