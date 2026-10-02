import AppKit

@MainActor
enum BrandIcon {
    static let image: NSImage? = {
        loadImage(named: "BrandIcon")
    }()

    static let statusImage: NSImage? = {
        guard let image = loadImage(named: "StatusIconTemplate") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "ElegantClipbar"
        return image
    }()

    private static func loadImage(named name: String) -> NSImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        return url.flatMap { NSImage(contentsOf: $0) }
    }
}
