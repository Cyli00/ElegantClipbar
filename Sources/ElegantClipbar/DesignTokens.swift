import AppKit
import SwiftUI

enum L10n {
    static let usesChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? true

    static func text(_ chinese: String, _ english: String) -> String {
        usesChinese ? chinese : english
    }
}

enum PanelStyle {
    static let width: CGFloat = 360
    static let height: CGFloat = 560
    static let radius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let padding: CGFloat = 8
    static let bodySize: CGFloat = 13
    static let captionSize: CGFloat = 11
    static let rowHeight: CGFloat = 60
    static let titleSize: CGFloat = 15
    static let logoSize: CGFloat = 40
    static let iconButtonSize: CGFloat = 26
    static let stroke: CGFloat = 0.65

    static let body = Font.system(size: bodySize, design: .monospaced)
    static let caption = Font.system(size: captionSize, design: .monospaced)
    static let title = Font.system(size: titleSize, weight: .semibold, design: .monospaced)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let inset = Color(nsColor: .controlBackgroundColor)
    static let selection = Color.accentColor.opacity(0.12)
    static let border = Color(nsColor: .separatorColor)
    static let hover = Color.primary.opacity(0.05)
}

extension ClipboardKind {
    var tint: Color {
        switch self {
        case .text: return .blue
        case .link: return .indigo
        case .richText: return .purple
        case .image: return .pink
        case .file: return .orange
        }
    }

    var title: String {
        switch self {
        case .text: return L10n.text("文本", "Text")
        case .link: return L10n.text("链接", "Link")
        case .richText: return L10n.text("富文本", "Rich text")
        case .image: return L10n.text("图片", "Image")
        case .file: return L10n.text("文件", "File")
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .richText: return "doc.richtext"
        case .image: return "photo"
        case .file: return "doc.on.doc"
        }
    }
}

struct PanelIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: PanelStyle.iconButtonSize, height: PanelStyle.iconButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .background(hovered ? PanelStyle.hover : .clear, in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
