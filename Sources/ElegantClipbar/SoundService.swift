import AppKit

@MainActor
enum SoundService {
    private static let recordSound = NSSound(named: "Tink")
    private static let pasteSound = NSSound(named: "Pop")

    static func record(isEnabled: Bool) { if isEnabled { previewRecord() } }
    static func paste(isEnabled: Bool) { if isEnabled { previewPaste() } }
    static func previewRecord() { play(recordSound) }
    static func previewPaste() { play(pasteSound) }

    private static func play(_ sound: NSSound?) {
        sound?.stop()
        sound?.play()
    }
}
