import Foundation
import CSQLite
import Testing
@testable import ElegantClipbar

@Suite(.serialized)
final class ClipboardStoreTests {
    private let directory: URL
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ElegantClipbar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func testPayloadAndMetadataSurviveReopening() throws {
        let source = ClipboardSource(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
        let payload = text("一段保存的文字")
        var first: ClipboardStore? = try ClipboardStore(directory: directory)
        let record = try first!.record(payload: payload, source: source, at: epoch)
        try first!.setPinned(true, id: record.id)
        first = nil

        let reopened = try ClipboardStore(directory: directory)
        let records = try reopened.records()
        #expect(records.count == 1)
        #expect(records[0].id == record.id)
        #expect(records[0].source == source)
        #expect(records[0].byteCount == payload.items[0].representations.values.first!.count)
        #expect(records[0].isPinned)
        #expect(try reopened.payload(for: record.id) == payload)
    }

    @Test func testDeduplicationIgnoresDictionaryOrderAndSourceButPreservesFormatting() throws {
        let store = try ClipboardStore(directory: directory)
        let bold = richText("Hello", html: "<b>Hello</b>")
        let plain = text("Hello")
        let boldRecord = try store.record(payload: bold, source: nil, at: epoch)
        let source = ClipboardSource(name: "Other App", bundleIdentifier: "test.other")
        var reordered = bold
        reordered.items[0].representations = ["public.html": Data("<b>Hello</b>".utf8), "public.utf8-plain-text": Data("Hello".utf8)]
        try store.setPinned(true, id: boldRecord.id)
        let duplicate = try store.record(payload: reordered, source: source, at: epoch.addingTimeInterval(2))
        let plainRecord = try store.record(payload: plain, source: nil, at: epoch.addingTimeInterval(3))
        let italicRecord = try store.record(payload: richText("Hello", html: "<i>Hello</i>"), source: nil, at: epoch.addingTimeInterval(4))

        #expect(duplicate.id == boldRecord.id)
        #expect(duplicate.createdAt == epoch)
        #expect(duplicate.lastCopiedAt == epoch.addingTimeInterval(2))
        #expect(duplicate.source == source)
        #expect(duplicate.isPinned)
        #expect(plainRecord.id != boldRecord.id)
        #expect(italicRecord.id != boldRecord.id)
        #expect(try store.count() == 3)
    }

    @Test func testPayloadItemOrderIsPartOfIdentityAndBinaryDataRoundTrips() throws {
        let store = try ClipboardStore(directory: directory)
        let firstItem = ClipboardPayloadItem(representations: ["public.png": Data([0, 255, 0, 1])])
        let secondItem = ClipboardPayloadItem(representations: ["public.png": Data([2, 0, 255, 0])])
        let first = ClipboardPayload(items: [firstItem, secondItem], plainText: "", kind: .image)
        let reversed = ClipboardPayload(items: [secondItem, firstItem], plainText: "", kind: .image)
        let record = try store.record(payload: first, source: nil, at: epoch)
        let other = try store.record(payload: reversed, source: nil, at: epoch)
        #expect(record.id != other.id)
        #expect(record.byteCount == 8)
        #expect(try store.payload(for: record.id) == first)
    }

    @Test func testPruningUsesRecencyAndExemptsPinnedRecords() throws {
        let store = try ClipboardStore(directory: directory)
        let oldDate = epoch.addingTimeInterval(-31 * 86_400)
        let pinned = try store.record(payload: text("old pinned"), source: nil, at: oldDate)
        try store.setPinned(true, id: pinned.id)
        let expired = try store.record(payload: text("old ordinary"), source: nil, at: oldDate)
        let older = try store.record(payload: text("recent one"), source: nil, at: epoch.addingTimeInterval(-10))
        let newest = try store.record(payload: text("recent two"), source: nil, at: epoch)

        try store.prune(maxCount: 1, maxAgeDays: 30, now: epoch)
        #expect(try store.records().map(\.id) == [pinned.id, newest.id])
        #expect(throws: (any Error).self) { try store.payload(for: expired.id) }
        #expect(throws: (any Error).self) { try store.payload(for: older.id) }
        try store.prune(maxCount: 0, maxAgeDays: 0, now: epoch)
        #expect(try store.records().map(\.id) == [pinned.id])
    }

    @Test func testSearchIsUnicodeAwareLiteralAndSearchesBeyondPreview() throws {
        let store = try ClipboardStore(directory: directory)
        let matching = try store.record(payload: text(String(repeating: "a", count: 300) + " 中文 Café 100% _literal_"), source: nil, at: epoch)
        _ = try store.record(payload: text("another record"), source: nil, at: epoch)
        #expect(!(matching.preview.contains("中文")))
        for query in ["中文", "CAFÉ", "cafe", "%", "_literal_"] {
            #expect(try store.records(query: query).map(\.id) == [matching.id])
            #expect(try store.count(query: query) == 1)
        }
        #expect(try store.count(query: "' OR 1=1 --") == 0)
        #expect(try store.count(query: "不存在") == 0)
    }

    @Test func testPaginationIsStableAndPinsSortFirst() throws {
        let store = try ClipboardStore(directory: directory)
        var ids: [UUID] = []
        for index in 0..<6 {
            ids.append(try store.record(payload: text("item \(index)"), source: nil, at: epoch.addingTimeInterval(Double(index))).id)
        }
        try store.setPinned(true, id: ids[1])
        let expected = [ids[1], ids[5], ids[4], ids[3], ids[2], ids[0]]
        #expect(try store.records(limit: 2).map(\.id) == Array(expected.prefix(2)))
        #expect(try store.records(limit: 2, offset: 2).map(\.id) == Array(expected[2..<4]))
        #expect(try store.records(limit: 2, offset: 4).map(\.id) == Array(expected[4..<6]))
        #expect(try store.records(limit: 2, offset: 6) == [])
    }

    @Test func testBackupRoundTripMergesWithoutReplacingExistingData() throws {
        let source = try ClipboardStore(directory: directory.appendingPathComponent("source"))
        let duplicate = try source.record(payload: richText("same", html: "<b>same</b>"), source: nil, at: epoch)
        try source.setPinned(true, id: duplicate.id)
        let filePayload = ClipboardPayload(items: [ClipboardPayloadItem(representations: ["public.file-url": Data("file:///tmp/example.txt".utf8)])], plainText: "/tmp/example.txt", kind: .file)
        let file = try source.record(payload: filePayload, source: nil, at: epoch)
        let backup = directory.appendingPathComponent("history.clipbar")
        try source.exportBackup(to: backup)
        #expect(try Data(contentsOf: backup).prefix(16) == Data("SQLite format 3\0".utf8))

        let destination = try ClipboardStore(directory: directory.appendingPathComponent("destination"))
        let existing = try destination.record(payload: richText("same", html: "<b>same</b>"), source: nil, at: epoch.addingTimeInterval(10))
        let unrelated = try destination.record(payload: text("keep me"), source: nil, at: epoch)
        #expect(try destination.importBackup(from: backup) == 1)
        #expect(try destination.count() == 3)
        let records = try destination.records()
        #expect(records.first?.id == existing.id)
        #expect(records.first?.lastCopiedAt == epoch.addingTimeInterval(10))
        #expect(records.first!.isPinned)
        #expect(records.contains(where: { $0.id == unrelated.id }))
        #expect(try destination.payload(for: file.id) == filePayload)
        #expect(try destination.importBackup(from: backup) == 0)
        #expect(try destination.count() == 3)
    }

    @Test func testMalformedBackupDoesNotPartiallyImportOrChangePins() throws {
        let source = try ClipboardStore(directory: directory.appendingPathComponent("source"))
        let first = try source.record(payload: text("first"), source: nil, at: epoch)
        try source.setPinned(true, id: first.id)
        let second = try source.record(payload: text("second"), source: nil, at: epoch.addingTimeInterval(1))
        let backup = directory.appendingPathComponent("history.clipbar")
        try source.exportBackup(to: backup)
        let invalidPayload = ClipboardPayload(items: [], plainText: "", kind: .text)
        try mutateBackup(backup, sql: "UPDATE records SET payload = ? WHERE id = '\(second.id.uuidString)'", payload: PropertyListEncoder().encode(invalidPayload))

        let destination = try ClipboardStore(directory: directory.appendingPathComponent("destination"))
        let existing = try destination.record(payload: text("first"), source: nil, at: epoch)
        #expect(throws: (any Error).self) { try destination.importBackup(from: backup) }
        #expect(try destination.count() == 1)
        #expect(try destination.records() == [existing])
        try Data("invalid backup".utf8).write(to: backup)
        #expect(throws: (any Error).self) { try destination.importBackup(from: backup) }
        #expect(try destination.records() == [existing])
    }

    @Test func testBackupVersionAndSchemaAreValidated() throws {
        let store = try ClipboardStore(directory: directory.appendingPathComponent("source"))
        _ = try store.record(payload: text("preserve"), source: nil, at: epoch)
        let backup = directory.appendingPathComponent("history.clipbar")
        try store.exportBackup(to: backup)
        try mutateBackup(backup, sql: "PRAGMA user_version = 99")
        #expect(throws: (any Error).self) { try store.importBackup(from: backup) }
        #expect(try store.count() == 1)
        try store.exportBackup(to: backup)
        try mutateBackup(backup, sql: "ALTER TABLE records ADD COLUMN unexpected TEXT")
        #expect(throws: (any Error).self) { try store.importBackup(from: backup) }
        #expect(try store.count() == 1)
    }

    @Test func testImageBackupIsOneStandaloneFile() throws {
        let source = try ClipboardStore(directory: directory.appendingPathComponent("source"))
        for index in UInt8(0)..<3 {
            let payload = ClipboardPayload(items: [ClipboardPayloadItem(representations: ["public.png": Data(repeating: index, count: 2 * 1_024 * 1_024)])], plainText: "", kind: .image)
            _ = try source.record(payload: payload, source: nil, at: epoch)
        }
        let backupDirectory = directory.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appendingPathComponent("images.clipbar")
        try source.exportBackup(to: backup)
        let files = try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        #expect(files == ["images.clipbar"])
        let destination = try ClipboardStore(directory: directory.appendingPathComponent("destination"))
        #expect(try destination.importBackup(from: backup) == 3)
        #expect(try destination.records().map(\.byteCount) == [2 * 1_024 * 1_024, 2 * 1_024 * 1_024, 2 * 1_024 * 1_024])
    }

    @Test func testInvalidPayloadAndMissingRecordAreReported() throws {
        let store = try ClipboardStore(directory: directory)
        #expect(throws: (any Error).self) { try store.record(payload: ClipboardPayload(items: [], plainText: "", kind: .text), source: nil) }
        let invalidFile = ClipboardPayload(items: [ClipboardPayloadItem(representations: ["public.file-url": Data("https://example.com".utf8)])], plainText: "invalid", kind: .file)
        #expect(throws: (any Error).self) { try store.record(payload: invalidFile, source: nil) }
        #expect(throws: (any Error).self) { try store.payload(for: UUID()) }
        #expect(throws: (any Error).self) { try store.setPinned(true, id: UUID()) }
        #expect(throws: (any Error).self) { try store.prune(maxCount: -1, maxAgeDays: 30) }
        #expect(throws: (any Error).self) { try store.exportBackup(to: directory.appendingPathComponent("clipboard.sqlite3")) }
        #expect(try store.count() == 0)
    }

    @Test func testPayloadLimitCountsEveryRepresentation() throws {
        let store = try ClipboardStore(directory: directory)
        let half = Data(repeating: 0, count: ClipboardPayload.maximumByteCount / 2 + 1)
        let tooLarge = ClipboardPayload(items: [ClipboardPayloadItem(representations: ["public.png": half, "public.tiff": half])], plainText: "", kind: .image)
        #expect(throws: (any Error).self) { try store.record(payload: tooLarge, source: nil) }
        #expect(try store.count() == 0)
    }

    private func text(_ value: String) -> ClipboardPayload {
        ClipboardPayload(items: [ClipboardPayloadItem(representations: ["public.utf8-plain-text": Data(value.utf8)])], plainText: value, kind: .text)
    }

    private func richText(_ value: String, html: String) -> ClipboardPayload {
        ClipboardPayload(items: [ClipboardPayloadItem(representations: ["public.utf8-plain-text": Data(value.utf8), "public.html": Data(html.utf8)])], plainText: value, kind: .richText)
    }

    private func mutateBackup(_ url: URL, sql: String, payload: Data? = nil) throws {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close_v2(handle) }
        #expect(opened == SQLITE_OK)
        let database = try #require(handle)
        var prepared: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK)
        defer { sqlite3_finalize(prepared) }
        let statement = try #require(prepared)
        if let payload {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(payload.count), transient) }
            #expect(bound == SQLITE_OK)
        }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
    }
}
