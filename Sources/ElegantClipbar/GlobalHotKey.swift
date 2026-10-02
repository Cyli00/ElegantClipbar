import AppKit
import Carbon

@MainActor
final class GlobalHotKey {
    struct Shortcut: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32

        static let `default` = Shortcut(keyCode: 9, modifiers: UInt32(optionKey | cmdKey))

        var displayString: String {
            var result = ""
            if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
            let names: [UInt32: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
                11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
                20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8",
                29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
                38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
                47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"
            ]
            return result + (names[keyCode] ?? "Key \(keyCode)")
        }
    }

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var activeID: UInt32 = 0
    private var shortcut: Shortcut?
    private let onPressed: () -> Void
    private static let signature: OSType = 0x45434252

    init(onPressed: @escaping () -> Void) { self.onPressed = onPressed }

    func register(_ shortcut: Shortcut = .default) throws {
        if self.shortcut == shortcut, hotKey != nil { return }
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    if hotKeyID.signature == GlobalHotKey.signature, hotKeyID.id == instance.activeID { instance.onPressed() }
                }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard result == noErr else { throw RegistrationError(status: result) }
        }
        let nextID = activeID &+ 1
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: nextID),
                                        GetApplicationEventTarget(), 0, &replacement)
        guard result == noErr else { throw RegistrationError(status: result) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        activeID = nextID
        self.shortcut = shortcut
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        shortcut = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    struct RegistrationError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            L10n.text("无法注册唤醒快捷键，可能已被其他应用占用（\(status)）。",
                      "Could not register the shortcut. Another app may be using it (\(status)).")
        }
    }
}
