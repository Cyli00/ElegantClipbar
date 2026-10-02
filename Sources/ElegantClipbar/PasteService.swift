import AppKit
import ApplicationServices

enum PasteOutcome: Equatable {
    case pasted
    case copiedOnly(String)
    case failure(String)
}

@MainActor
final class PasteService {
    private let pasteboard: NSPasteboard
    private var isPasting = false

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func write(_ payload: ClipboardPayload, plainTextOnly: Bool = false) throws {
        var objects: [NSPasteboardItem] = []
        if plainTextOnly {
            guard !payload.plainText.isEmpty else { throw PasteError.emptyText }
            let item = NSPasteboardItem()
            item.setString(payload.plainText, forType: .string)
            objects = [item]
        } else {
            for storedItem in payload.items {
                let item = NSPasteboardItem()
                for (typeName, data) in storedItem.representations {
                    let type = NSPasteboard.PasteboardType(typeName)
                    guard ClipboardMonitor.supportedTypes.contains(type) else { continue }
                    if type == .fileURL {
                        guard let value = String(data: data, encoding: .utf8),
                              let url = URL(string: value), url.isFileURL else { throw PasteError.invalidFile }
                        guard FileManager.default.fileExists(atPath: url.path) else { throw PasteError.missingFile }
                    }
                    item.setData(data, forType: type)
                }
                if !item.types.isEmpty { objects.append(item) }
            }
        }
        guard !objects.isEmpty else { throw PasteError.emptyPayload }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(objects) else { throw PasteError.writeFailed }
    }

    func paste(
        _ payload: ClipboardPayload,
        to target: NSRunningApplication?,
        plainTextOnly: Bool = false,
        didWrite: (() -> Void)? = nil
    ) async -> PasteOutcome {
        guard !isPasting else { return .failure(L10n.text("正在粘贴，请稍后再试。", "A paste is in progress. Please try again shortly.")) }
        isPasting = true
        defer { isPasting = false }
        do { try write(payload, plainTextOnly: plainTextOnly) }
        catch { return .failure(error.localizedDescription) }
        didWrite?()
        let expectedChangeCount = pasteboard.changeCount
        guard hasAccessibilityPermission else {
            return .copiedOnly(L10n.text("已复制。开启辅助功能权限后，可以自动粘贴。", "Copied. Enable Accessibility permission for automatic pasting."))
        }
        guard let target, !target.isTerminated, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .copiedOnly(L10n.text("已复制。请切换到目标应用后按 ⌘V。", "Copied. Switch to the destination app and press ⌘V."))
        }
        guard target.activate(options: [.activateIgnoringOtherApps]) else {
            return .copiedOnly(L10n.text("已复制，无法切换到原来的应用，请手动粘贴。", "Copied. The previous app could not be activated. Paste manually."))
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1.5))
        let interferingModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, !target.isTerminated else {
                return .copiedOnly(L10n.text("已复制，自动粘贴已取消。", "Copied. Automatic pasting was cancelled."))
            }
            guard pasteboard.changeCount == expectedChangeCount else {
                return .failure(L10n.text("剪贴板已被其他应用更新，已取消自动粘贴。", "Another app changed the clipboard. Automatic pasting was cancelled."))
            }
            let modifiers = CGEventSource.flagsState(.combinedSessionState).intersection(interferingModifiers)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier, modifiers.isEmpty {
                guard let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                    return .copiedOnly(L10n.text("已复制，无法发送粘贴快捷键，请手动按 ⌘V。", "Copied. The paste shortcut could not be sent. Press ⌘V manually."))
                }
                down.flags = .maskCommand
                up.flags = .maskCommand
                // Targeted events and the foreground check prevent a focus race from pasting elsewhere.
                down.postToPid(target.processIdentifier)
                up.postToPid(target.processIdentifier)
                return .pasted
            }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return .copiedOnly(L10n.text("已复制，自动粘贴已取消。", "Copied. Automatic pasting was cancelled.")) }
        }
        return .copiedOnly(L10n.text("已复制。原应用未激活或快捷键仍被按住，请手动按 ⌘V。", "Copied. The previous app did not activate or shortcut keys are still held. Press ⌘V manually."))
    }
}

private enum PasteError: LocalizedError {
    case emptyText, emptyPayload, invalidFile, missingFile, writeFailed

    var errorDescription: String? {
        switch self {
        case .emptyText: return L10n.text("这条记录没有可复制的纯文本。", "This item has no plain text to copy.")
        case .emptyPayload: return L10n.text("这条记录没有可用的剪贴板内容。", "This item has no usable clipboard content.")
        case .invalidFile: return L10n.text("记录中的文件位置无效。", "The stored file location is invalid.")
        case .missingFile: return L10n.text("原文件已移动或删除，无法粘贴。", "The original file was moved or deleted and cannot be pasted.")
        case .writeFailed: return L10n.text("无法写入系统剪贴板，请重试。", "Could not write to the system clipboard. Please try again.")
        }
    }
}
