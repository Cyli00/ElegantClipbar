import AppKit

@main
enum ElegantClipbarApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var panel: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("--demo")
        let directory: URL
        if let index = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else if demo {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ElegantClipbar-Demo-\(UUID().uuidString)")
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ElegantClipbar", isDirectory: true)
        }
        let defaults = demo ? UserDefaults(suiteName: "app.elegantclipbar.demo.\(UUID().uuidString)")! : .standard
        let state = AppState(directory: directory, isDemo: demo, preferences: Preferences(defaults: defaults))
        self.state = state
        let panel = PanelController(state: state)
        self.panel = panel
        if demo {
            seedDemo(state)
            if arguments.contains("--demo-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            DispatchQueue.main.async { panel.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.stop()
        panel?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return false
    }

    private func seedDemo(_ state: AppState) {
        let examples: [(String, ClipboardKind, String)] = [
            ("项目笔记\n下一步：检查搜索、置顶和键盘选择。", .text, "Notes"),
            ("https://developer.apple.com/swift/", .link, "Safari"),
            ("let clipboard = NSPasteboard.general", .text, "Xcode"),
            ("会议安排\n星期五 15:00 · 产品讨论", .text, "Calendar")
        ]
        for (text, kind, source) in examples {
            let payload = ClipboardPayload(items: [ClipboardPayloadItem(representations: [
                NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)
            ])], plainText: text, kind: kind)
            state.capture(payload, source: ClipboardSource(name: source, bundleIdentifier: nil))
        }
    }
}
