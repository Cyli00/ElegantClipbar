import AppKit
import ImageIO
import SwiftUI

struct PreviewView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let record = state.previewRecord {
                HStack(spacing: 8) {
                    Label(record.kind.title, systemImage: record.kind.symbol)
                    Spacer(minLength: 0)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .font(PanelStyle.caption)
                .padding(12)

                if let payload = state.previewPayload {
                    preview(payload)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack {
                    Button(L10n.text("粘贴", "Paste")) { state.paste(record) }
                        .disabled(state.isPasting || state.previewPayload == nil)
                    Button(L10n.text("复制", "Copy")) { state.paste(record, copyOnly: true) }
                        .disabled(state.isPasting || state.previewPayload == nil)
                    Spacer(minLength: 4)
                    Text(record.source?.name ?? "")
                        .font(PanelStyle.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .controlSize(.small)
                .padding(12)
            }
        }
    }

    @ViewBuilder private func preview(_ payload: ClipboardPayload) -> some View {
        switch payload.kind {
        case .image:
            ScrollView {
                if let image = imageThumbnail(payload) {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                        .accessibilityLabel(L10n.text("剪贴板图片预览", "Clipboard image preview"))
                } else {
                    Text(L10n.text("无法预览这张图片。", "This image cannot be previewed.")).padding()
                }
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(fileURLs(payload), id: \.absoluteString) { url in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(url.lastPathComponent, systemImage: "doc")
                                .font(.system(size: 13)).textSelection(.enabled)
                            Text(url.path).font(PanelStyle.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if FileManager.default.fileExists(atPath: url.path) {
                                Button(L10n.text("在 Finder 中显示", "Show in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }.controlSize(.small)
                            } else {
                                Label(L10n.text("原文件已移动或删除", "File moved or deleted"), systemImage: "exclamationmark.triangle")
                                    .font(PanelStyle.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(12)
            }
        default:
            NativeTextPreview(payload: payload)
                .padding(.horizontal, PanelStyle.padding)
        }
    }

    private func fileURLs(_ payload: ClipboardPayload) -> [URL] {
        payload.items.compactMap { item in
            item.representations[NSPasteboard.PasteboardType.fileURL.rawValue]
                .flatMap { String(data: $0, encoding: .utf8) }.flatMap { URL(string: $0) }
        }
    }

    private func imageThumbnail(_ payload: ClipboardPayload) -> NSImage? {
        for item in payload.items {
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                guard let data = item.representations[type.rawValue],
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1_024,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { continue }
                return NSImage(cgImage: thumbnail, size: .zero)
            }
        }
        return nil
    }
}

private struct NativeTextPreview: NSViewRepresentable {
    let payload: ClipboardPayload

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 4, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let rtf = payload.items.first?.representations[NSPasteboard.PasteboardType.rtf.rawValue]
        if let rtf, let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            text.textStorage?.setAttributedString(attributed)
        } else {
            // HTML is shown as extracted text; previewing must not load remote resources.
            text.textStorage?.setAttributedString(NSAttributedString(string: payload.plainText, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
            ]))
        }
        text.setAccessibilityLabel(L10n.text("剪贴板内容预览", "Clipboard content preview"))
    }
}
