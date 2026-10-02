import AppKit

@MainActor
final class ClipboardMonitor {
    static let maximumCaptureBytes = ClipboardPayload.maximumByteCount
    static let supportedTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .html, .rtf, .png, .tiff, .fileURL, .URL,
        NSPasteboard.PasteboardType("public.url-name"),
        NSPasteboard.PasteboardType("public.utf16-plain-text"),
        NSPasteboard.PasteboardType("public.utf16-external-plain-text")
    ]

    var excludedBundleIdentifiers: Set<String> = []
    var isPaused = false {
        didSet {
            if oldValue && !isPaused { ignoreCurrentChange() }
        }
    }

    private let pasteboard: NSPasteboard
    private let onCapture: (ClipboardPayload, ClipboardSource?) -> Void
    private let sourceProvider: () -> ClipboardSource?
    private var lastChangeCount: Int
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?

    init(
        pasteboard: NSPasteboard = .general,
        sourceProvider: @escaping () -> ClipboardSource? = {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return ClipboardSource(name: app.localizedName ?? "", bundleIdentifier: app.bundleIdentifier)
        },
        onCapture: @escaping (ClipboardPayload, ClipboardSource?) -> Void
    ) {
        self.pasteboard = pasteboard
        self.sourceProvider = sourceProvider
        self.onCapture = onCapture
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let source = ClipboardSource(name: app.localizedName ?? "", bundleIdentifier: app.bundleIdentifier)
            MainActor.assumeIsolated { self?.poll(sourceOverride: source) }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }

    deinit {
        timer?.invalidate()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    func ignoreCurrentChange() {
        lastChangeCount = pasteboard.changeCount
    }

    func poll() {
        poll(sourceOverride: nil)
    }

    func poll(sourceOverride: ClipboardSource?) {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard !isPaused else { return }
        // A pending copy belongs to the departing app even after frontmostApplication has changed.
        let source = sourceOverride ?? sourceProvider()
        if let identifier = source?.bundleIdentifier, excludedBundleIdentifiers.contains(identifier) { return }
        guard let rawItems = pasteboard.pasteboardItems, !rawItems.isEmpty else { return }
        let allTypes = Set((pasteboard.types ?? []) + rawItems.flatMap(\.types))
        guard !allTypes.contains(where: Self.isPrivateType) else { return }

        var byteCount = 0
        var items: [ClipboardPayloadItem] = []
        var searchText: [String] = []
        var capturedTypes: Set<NSPasteboard.PasteboardType> = []
        for rawItem in rawItems {
            var representations: [String: Data] = [:]
            for type in rawItem.types where Self.supportedTypes.contains(type) {
                guard let data = rawItem.data(forType: type) else { continue }
                guard data.count <= Self.maximumCaptureBytes - byteCount else { return }
                byteCount += data.count
                representations[type.rawValue] = data
                capturedTypes.insert(type)
            }
            guard !representations.isEmpty else { continue }
            items.append(ClipboardPayloadItem(representations: representations))
            if let text = Self.searchableText(representations), !text.isEmpty { searchText.append(text) }
        }
        // A lazy pasteboard provider may replace its contents while fulfilling a representation.
        guard !items.isEmpty, byteCount > 0, pasteboard.changeCount == changeCount else { return }
        let kind: ClipboardKind
        if capturedTypes.contains(.fileURL) { kind = .file }
        else if capturedTypes.contains(.png) || capturedTypes.contains(.tiff) { kind = .image }
        else if capturedTypes.contains(.html) || capturedTypes.contains(.rtf) { kind = .richText }
        else if capturedTypes.contains(.URL) || Self.isWebURL(searchText.joined(separator: "\n")) { kind = .link }
        else { kind = .text }
        onCapture(ClipboardPayload(items: items, plainText: searchText.joined(separator: "\n"), kind: kind), source)
    }

    private static func isPrivateType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let name = type.rawValue.lowercased()
        return name == "org.nspasteboard.concealedtype"
            || name == "org.nspasteboard.transienttype"
            || name == "org.nspasteboard.autogeneratedtype"
            || name == "de.petermaurer.transientpasteboardtype"
            || name.hasPrefix("com.agilebits.onepassword")
            || name.hasPrefix("com.1password.")
    }

    private static func searchableText(_ representations: [String: Data]) -> String? {
        if let data = representations[NSPasteboard.PasteboardType.fileURL.rawValue],
           let value = String(data: data, encoding: .utf8), let url = URL(string: value), url.isFileURL {
            return url.path
        }
        if let data = representations[NSPasteboard.PasteboardType.string.rawValue],
           let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
        for type in ["public.utf16-plain-text", "public.utf16-external-plain-text"] {
            if let data = representations[type], let text = String(data: data, encoding: .utf16), !text.isEmpty { return text }
        }
        if let data = representations[NSPasteboard.PasteboardType.rtf.rawValue],
           let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string, !text.isEmpty { return text }
        if let data = representations[NSPasteboard.PasteboardType.html.rawValue],
           let html = String(data: data, encoding: .utf8) {
            // AppKit's HTML importer can load external resources and block the main run loop.
            // Search indexing only needs text; the original HTML stays untouched for pasting.
            return html
                .replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li|/tr|/h[1-6])\\s*>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = representations[NSPasteboard.PasteboardType.URL.rawValue] { return String(data: data, encoding: .utf8) }
        return nil
    }

    private static func isWebURL(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        return scheme == "https" || scheme == "http"
    }
}
