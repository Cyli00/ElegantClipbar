import Foundation

enum ClipboardKind: String, Codable, CaseIterable {
    case text
    case link
    case richText
    case image
    case file
}

struct ClipboardPayloadItem: Codable, Equatable {
    var representations: [String: Data]
}

struct ClipboardPayload: Codable, Equatable {
    static let maximumByteCount = 50 * 1_024 * 1_024

    var items: [ClipboardPayloadItem]
    var plainText: String
    var kind: ClipboardKind
}

struct ClipboardSource: Codable, Equatable {
    var name: String
    var bundleIdentifier: String?
}

struct ClipboardRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: ClipboardKind
    var preview: String
    var source: ClipboardSource?
    var createdAt: Date
    var lastCopiedAt: Date
    var isPinned: Bool
    var byteCount: Int
}
