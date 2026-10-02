import AppKit
import Carbon
import SwiftUI

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let panel = ClipboardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var modalPresented = false
    private var isHidingPanel = false
    private var deactivationObserver: NSObjectProtocol?
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.toggle() }

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = BrandIcon.statusImage
                ?? NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ElegantClipbar")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.toolTip = "ElegantClipbar · \(state.preferences.shortcut.displayString)"
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = "ElegantClipbar"
        panel.identifier = NSUserInterfaceItemIdentifier("ElegantClipbarPanel")
        panel.delegate = self

        state.hidePanel = { [weak self] in self?.hide(preservePreview: true) }
        state.restorePanel = { [weak self] in self?.show(captureTarget: false) }
        state.requestQuit = { [weak self] in self?.confirmQuit() }
        state.setModalPresented = { [weak self] presented in
            self?.modalPresented = presented
            self?.panel.level = presented ? .normal : .statusBar
        }
        state.registerShortcut = { [weak self] shortcut in
            guard let self else { return }
            try self.hotKey.register(shortcut)
            self.statusItem.button?.toolTip = "ElegantClipbar · \(shortcut.displayString)"
        }
        state.suspendShortcut = { [weak self] in self?.hotKey.unregister() }
        if !state.isDemo {
            do { try hotKey.register(state.preferences.shortcut) }
            catch { state.report(error.localizedDescription, isError: true) }
        }
    }

    @objc private func statusItemClicked() { toggle() }

    func toggle() {
        guard !isPresentingDialog else { return }
        if panel.isVisible { hide(returnFocus: true) }
        else { show() }
    }

    func show(captureTarget: Bool = true) {
        if captureTarget {
            if !state.isDemo { state.monitor.poll() }
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                state.targetApplication = frontmost
            }
            state.goBack()
        }
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_024, height: 768)
        let height = min(PanelStyle.height, available.height - 16)
        let x = min(max(anchor.midX - PanelStyle.width / 2, available.minX + 8), available.maxX - PanelStyle.width - 8)
        let y = max(available.minY + 8, min(anchor.minY - height - 6, available.maxY - height))
        panel.setFrame(NSRect(x: x, y: y, width: PanelStyle.width, height: height), display: false)
        if !(panel.contentView is NSHostingView<PanelView>) {
            panel.contentView = NSHostingView(rootView: PanelView(state: state, preferences: state.preferences))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installEventMonitors()
        state.needsAccessibility = !state.pasteService.hasAccessibilityPermission && state.needsAccessibility
        state.reload()
    }

    func hide(returnFocus: Bool = false, preservePreview: Bool = false) {
        guard panel.isVisible, !isPresentingDialog, !isHidingPanel else { return }
        // orderOut also resigns key status; do not dismiss twice or lose a pending paste's preview.
        isHidingPanel = true
        defer { isHidingPanel = false }
        if state.isRecordingShortcut { state.cancelShortcutRecording() }
        removeEventMonitors()
        panel.orderOut(nil)
        panel.contentView = nil
        if !preservePreview { state.goBack() }
        if returnFocus, let target = state.targetApplication, !target.isTerminated {
            target.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func stop() {
        removeEventMonitors()
        hotKey.unregister()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private var isPresentingDialog: Bool {
        modalPresented || state.pendingDeletion != nil || panel.attachedSheet != nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func confirmQuit() {
        guard panel.isVisible, !isPresentingDialog else { return }
        modalPresented = true
        let alert = NSAlert()
        alert.messageText = L10n.text("退出 ElegantClipbar？", "Quit ElegantClipbar?")
        alert.informativeText = L10n.text("退出后将停止记录剪贴板，已保存的历史记录会保留。", "Clipboard capture will stop. Your saved history will be kept.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("取消", "Cancel"))
        alert.addButton(withTitle: L10n.text("退出", "Quit"))
        alert.buttons[0].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalent = ""
        alert.window.defaultButtonCell = alert.buttons[0].cell as? NSButtonCell
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            self.modalPresented = false
            if response == .alertSecondButtonReturn {
                NSApp.terminate(nil)
            } else {
                self.panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func removeEventMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        localMonitor = nil
        globalMonitor = nil
        deactivationObserver = nil
    }

    private func installEventMonitors() {
        removeEventMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
        deactivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                      object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.isPresentingDialog else { return false }
                if event.type != .keyDown {
                    if event.window !== self.panel, event.window !== self.statusItem.button?.window { self.hide() }
                    return false
                }
                guard event.window === self.panel else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        if state.isRecordingShortcut {
            if event.keyCode == 53 { state.cancelShortcutRecording(); return true }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                state.report(L10n.text("组合键至少包含 ⌘、⌥ 或 ⌃。", "Include at least ⌘, ⌥ or ⌃ in the shortcut."), isError: true)
                return true
            }
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            state.updateShortcut(.init(keyCode: UInt32(event.keyCode), modifiers: carbon))
            return true
        }
        if event.keyCode == 53 {
            hide(returnFocus: true)
            return true
        }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            confirmQuit()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
            state.page = .settings
            return true
        }
        guard state.page == .history else { return false }
        switch event.keyCode {
        case 125: state.moveSelection(1); return true
        case 126: state.moveSelection(-1); return true
        case 36, 76:
            if let record = state.selectedRecord { state.paste(record, plainTextOnly: event.modifierFlags.contains(.option)) }
            return true
        default: return false
        }
    }
}
