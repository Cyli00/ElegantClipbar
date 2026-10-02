import CSQLite
import CryptoKit
import Foundation

enum ClipboardStoreError: LocalizedError {
    case database(String)
    case recordNotFound
    case invalidPayload
    case invalidBackup
    case unsupportedBackupVersion
    case invalidRetention

    var errorDescription: String? {
        switch self {
        case .database(let message): return "无法访问剪贴板历史：\(message)"
        case .recordNotFound: return "这条剪贴板记录已不存在。"
        case .invalidPayload: return "剪贴板内容无效。"
        case .invalidBackup: return "备份文件无效或已损坏。"
        case .unsupportedBackupVersion: return "此备份版本不受支持。"
        case .invalidRetention: return "历史保留数量和天数不能为负数。"
        }
    }
}

// All public operations serialize database and encoder access through the same lock.
final class ClipboardStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let databaseURL: URL
    private let lock = NSLock()
    private let encoder: PropertyListEncoder
    private let decoder = PropertyListDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let metadataColumns = "id, kind, preview, source_name, source_bundle, created_at, copied_at, pinned, byte_count"
    private static let applicationID: Int32 = 0x45434C42
    private static let schemaVersion: Int32 = 1
    private static let maximumEncodedPayloadBytes = ClipboardPayload.maximumByteCount * 3

    init(directory: URL) throws {
        encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = databaseError()
            sqlite3_close_v2(database)
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("""
                CREATE TABLE IF NOT EXISTS records (
                    id TEXT PRIMARY KEY NOT NULL,
                    fingerprint TEXT UNIQUE NOT NULL,
                    kind TEXT NOT NULL,
                    preview TEXT NOT NULL,
                    plain_text TEXT NOT NULL,
                    search_text TEXT NOT NULL,
                    source_name TEXT,
                    source_bundle TEXT,
                    created_at REAL NOT NULL,
                    copied_at REAL NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    byte_count INTEGER NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS records_recency ON records(pinned DESC, copied_at DESC, created_at DESC, id ASC)")
            try execute("PRAGMA application_id = \(Self.applicationID)")
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        } catch {
            sqlite3_close_v2(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(database)
    }

    func record(payload: ClipboardPayload, source: ClipboardSource?, at date: Date = Date()) throws -> ClipboardRecord {
        try synchronized {
            try validate(payload)
            guard date.timeIntervalSince1970.isFinite else { throw ClipboardStoreError.invalidPayload }
            let fingerprint = fingerprint(for: payload)
            return try transaction {
                if var existing = try find(fingerprint: fingerprint) {
                    existing.createdAt = min(existing.createdAt, date)
                    existing.lastCopiedAt = date
                    existing.source = source
                    try updateMetadata(existing)
                    return existing
                }
                let record = ClipboardRecord(
                    id: UUID(), kind: payload.kind, preview: preview(for: payload), source: source,
                    createdAt: date, lastCopiedAt: date, isPinned: false, byteCount: byteCount(for: payload)
                )
                try insert(record, payload: payload, fingerprint: fingerprint)
                return record
            }
        }
    }

    func records(query: String = "", limit: Int = 100, offset: Int = 0) throws -> [ClipboardRecord] {
        try synchronized {
            guard limit > 0 else { return [] }
            let sql = "SELECT \(Self.metadataColumns) FROM records WHERE instr(search_text, ?) > 0 ORDER BY pinned DESC, copied_at DESC, created_at DESC, id ASC LIMIT ? OFFSET ?"
            return try statement(sql) { statement in
                try bind(normalized(query), at: 1, to: statement)
                try bind(Int64(limit), at: 2, to: statement)
                try bind(Int64(max(0, offset)), at: 3, to: statement)
                var result: [ClipboardRecord] = []
                while try step(statement) {
                    result.append(try metadata(from: statement))
                }
                return result
            }
        }
    }

    func count(query: String = "") throws -> Int {
        try synchronized {
            try statement("SELECT count(*) FROM records WHERE instr(search_text, ?) > 0") { statement in
                try bind(normalized(query), at: 1, to: statement)
                guard try step(statement) else { throw databaseError() }
                return Int(sqlite3_column_int64(statement, 0))
            }
        }
    }

    func payload(for id: UUID) throws -> ClipboardPayload {
        try synchronized { try loadPayload(id: id) }
    }

    func setPinned(_ pinned: Bool, id: UUID) throws {
        try synchronized {
            try statement("UPDATE records SET pinned = ? WHERE id = ?") { statement in
                try bind(Int64(pinned ? 1 : 0), at: 1, to: statement)
                try bind(id.uuidString, at: 2, to: statement)
                try step(statement)
                guard sqlite3_changes(database) > 0 else { throw ClipboardStoreError.recordNotFound }
            }
        }
    }

    func remove(id: UUID) throws {
        try synchronized {
            try statement("DELETE FROM records WHERE id = ?") { statement in
                try bind(id.uuidString, at: 1, to: statement)
                try step(statement)
            }
        }
    }

    func prune(maxCount: Int, maxAgeDays: Int, now: Date = Date()) throws {
        try synchronized {
            guard maxCount >= 0, maxAgeDays >= 0, now.timeIntervalSince1970.isFinite else {
                throw ClipboardStoreError.invalidRetention
            }
            try transaction {
                if maxAgeDays > 0 {
                    let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
                    try statement("DELETE FROM records WHERE pinned = 0 AND copied_at < ?") { statement in
                        try bind(cutoff.timeIntervalSince1970, at: 1, to: statement)
                        try step(statement)
                    }
                }
                try statement("DELETE FROM records WHERE id IN (SELECT id FROM records WHERE pinned = 0 ORDER BY copied_at DESC, created_at DESC, id ASC LIMIT -1 OFFSET ?)") { statement in
                    try bind(Int64(maxCount), at: 1, to: statement)
                    try step(statement)
                }
            }
        }
    }

    func exportBackup(to url: URL) throws {
        try synchronized {
            guard url.resolvingSymlinksInPath().standardizedFileURL != databaseURL.resolvingSymlinksInPath().standardizedFileURL else {
                throw ClipboardStoreError.invalidBackup
            }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
            defer {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: temporary.path + suffix)
                }
            }
            var destination: OpaquePointer?
            guard sqlite3_open_v2(temporary.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                  let destination else {
                sqlite3_close_v2(destination)
                throw ClipboardStoreError.invalidBackup
            }
            do {
                guard let backup = sqlite3_backup_init(destination, "main", database, "main") else { throw databaseError(destination) }
                var status: Int32
                var retries = 0
                repeat {
                    status = sqlite3_backup_step(backup, 256)
                    if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                        retries += 1
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                } while status == SQLITE_OK || ((status == SQLITE_BUSY || status == SQLITE_LOCKED) && retries < 500)
                let finished = sqlite3_backup_finish(backup)
                guard status == SQLITE_DONE, finished == SQLITE_OK else { throw databaseError(destination) }
                // A backup is a standalone file, even while the active history uses WAL journaling.
                try execute("PRAGMA journal_mode = DELETE", on: destination)
            } catch {
                sqlite3_close_v2(destination)
                throw error
            }
            guard sqlite3_close_v2(destination) == SQLITE_OK else { throw ClipboardStoreError.invalidBackup }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        }
    }

    func importBackup(from url: URL) throws -> Int {
        try synchronized {
            var imported: OpaquePointer?
            guard sqlite3_open_v2(url.path, &imported, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let imported else {
                sqlite3_close_v2(imported)
                throw ClipboardStoreError.invalidBackup
            }
            defer { sqlite3_close_v2(imported) }
            sqlite3_busy_timeout(imported, 5_000)
            try execute("PRAGMA trusted_schema = OFF", on: imported)
            try execute("PRAGMA query_only = ON", on: imported)
            try execute("BEGIN", on: imported)
            defer { try? execute("ROLLBACK", on: imported) }
            try validateBackupDatabase(imported)

            // Decode one payload at a time. Any later invalid row rolls back earlier merges.
            return try transaction {
                try statement("SELECT \(Self.metadataColumns), payload, fingerprint, plain_text, search_text FROM records ORDER BY created_at ASC, id ASC", on: imported) { statement in
                    var inserted = 0
                    var ids = Set<UUID>()
                    var fingerprints = Set<String>()
                    while try step(statement) {
                        guard [0, 1, 2, 10, 11, 12].allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_TEXT }),
                              [3, 4].allSatisfy({ [SQLITE_TEXT, SQLITE_NULL].contains(sqlite3_column_type(statement, Int32($0))) }),
                              [5, 6].allSatisfy({ [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, Int32($0))) }),
                              [7, 8].allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }),
                              sqlite3_column_type(statement, 9) == SQLITE_BLOB,
                              Int(sqlite3_column_bytes(statement, 9)) <= Self.maximumEncodedPayloadBytes else {
                            throw ClipboardStoreError.invalidBackup
                        }
                        let record: ClipboardRecord
                        let payload: ClipboardPayload
                        do {
                            record = try metadata(from: statement)
                            payload = try decoder.decode(ClipboardPayload.self, from: blob(statement, column: 9))
                            try validate(payload)
                        } catch {
                            throw ClipboardStoreError.invalidBackup
                        }
                        let identity = fingerprint(for: payload)
                        guard ids.insert(record.id).inserted,
                              fingerprints.insert(identity).inserted,
                              record.kind == payload.kind,
                              record.byteCount == byteCount(for: payload),
                              record.preview == preview(for: payload),
                              record.createdAt.timeIntervalSince1970.isFinite,
                              record.lastCopiedAt.timeIntervalSince1970.isFinite,
                              record.createdAt <= record.lastCopiedAt,
                              string(statement, column: 10) == identity,
                              string(statement, column: 11) == payload.plainText,
                              string(statement, column: 12) == normalized(payload.plainText),
                              [0, 1].contains(sqlite3_column_int(statement, 7)) else {
                            throw ClipboardStoreError.invalidBackup
                        }
                        if var existing = try find(fingerprint: identity) {
                            existing.isPinned = existing.isPinned || record.isPinned
                            existing.createdAt = min(existing.createdAt, record.createdAt)
                            if record.lastCopiedAt >= existing.lastCopiedAt {
                                existing.lastCopiedAt = record.lastCopiedAt
                                existing.source = record.source
                            }
                            try updateMetadata(existing)
                        } else {
                            var insertedRecord = record
                            if try contains(id: record.id) { insertedRecord.id = UUID() }
                            try insert(insertedRecord, payload: payload, fingerprint: identity)
                            inserted += 1
                        }
                    }
                    return inserted
                }
            }
        }
    }

    private func validateBackupDatabase(_ imported: OpaquePointer) throws {
        do {
            try statement("PRAGMA application_id", on: imported) { statement in
                guard try step(statement), sqlite3_column_int(statement, 0) == Self.applicationID else { throw ClipboardStoreError.invalidBackup }
            }
            try statement("PRAGMA user_version", on: imported) { statement in
                guard try step(statement), sqlite3_column_int(statement, 0) == Self.schemaVersion else { throw ClipboardStoreError.unsupportedBackupVersion }
            }
            try statement("PRAGMA quick_check", on: imported) { statement in
                guard try step(statement), string(statement, column: 0) == "ok", !(try step(statement)) else { throw ClipboardStoreError.invalidBackup }
            }
            try statement("SELECT type, sql FROM sqlite_master WHERE name = 'records'", on: imported) { statement in
                guard try step(statement), string(statement, column: 0) == "table",
                      string(statement, column: 1).uppercased().hasPrefix("CREATE TABLE ") else { throw ClipboardStoreError.invalidBackup }
            }
            let expected = ["id:TEXT", "fingerprint:TEXT", "kind:TEXT", "preview:TEXT", "plain_text:TEXT", "search_text:TEXT", "source_name:TEXT", "source_bundle:TEXT", "created_at:REAL", "copied_at:REAL", "pinned:INTEGER", "byte_count:INTEGER", "payload:BLOB"]
            let columns = try statement("PRAGMA table_info(records)", on: imported) { statement in
                var columns: [String] = []
                while try step(statement) {
                    columns.append("\(string(statement, column: 1)):\(string(statement, column: 2).uppercased())")
                }
                return columns
            }
            guard columns == expected else { throw ClipboardStoreError.invalidBackup }
        } catch let error as ClipboardStoreError {
            if case .unsupportedBackupVersion = error { throw error }
            throw ClipboardStoreError.invalidBackup
        } catch {
            throw ClipboardStoreError.invalidBackup
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func insert(_ record: ClipboardRecord, payload: ClipboardPayload, fingerprint: String) throws {
        try statement("INSERT INTO records (id, fingerprint, kind, preview, plain_text, search_text, source_name, source_bundle, created_at, copied_at, pinned, byte_count, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            try bind(record.id.uuidString, at: 1, to: statement)
            try bind(fingerprint, at: 2, to: statement)
            try bind(record.kind.rawValue, at: 3, to: statement)
            try bind(record.preview, at: 4, to: statement)
            try bind(payload.plainText, at: 5, to: statement)
            try bind(normalized(payload.plainText), at: 6, to: statement)
            try bind(record.source?.name, at: 7, to: statement)
            try bind(record.source?.bundleIdentifier, at: 8, to: statement)
            try bind(record.createdAt.timeIntervalSince1970, at: 9, to: statement)
            try bind(record.lastCopiedAt.timeIntervalSince1970, at: 10, to: statement)
            try bind(Int64(record.isPinned ? 1 : 0), at: 11, to: statement)
            try bind(Int64(record.byteCount), at: 12, to: statement)
            try bind(encoder.encode(payload), at: 13, to: statement)
            try step(statement)
        }
    }

    private func updateMetadata(_ record: ClipboardRecord) throws {
        try statement("UPDATE records SET source_name = ?, source_bundle = ?, created_at = ?, copied_at = ?, pinned = ? WHERE id = ?") { statement in
            try bind(record.source?.name, at: 1, to: statement)
            try bind(record.source?.bundleIdentifier, at: 2, to: statement)
            try bind(record.createdAt.timeIntervalSince1970, at: 3, to: statement)
            try bind(record.lastCopiedAt.timeIntervalSince1970, at: 4, to: statement)
            try bind(Int64(record.isPinned ? 1 : 0), at: 5, to: statement)
            try bind(record.id.uuidString, at: 6, to: statement)
            try step(statement)
        }
    }

    private func find(fingerprint: String) throws -> ClipboardRecord? {
        try statement("SELECT \(Self.metadataColumns) FROM records WHERE fingerprint = ?") { statement in
            try bind(fingerprint, at: 1, to: statement)
            return try step(statement) ? metadata(from: statement) : nil
        }
    }

    private func contains(id: UUID) throws -> Bool {
        try statement("SELECT 1 FROM records WHERE id = ?") { statement in
            try bind(id.uuidString, at: 1, to: statement)
            return try step(statement)
        }
    }

    private func loadPayload(id: UUID) throws -> ClipboardPayload {
        try statement("SELECT payload FROM records WHERE id = ?") { statement in
            try bind(id.uuidString, at: 1, to: statement)
            guard try step(statement) else { throw ClipboardStoreError.recordNotFound }
            return try decoder.decode(ClipboardPayload.self, from: blob(statement, column: 0))
        }
    }

    private func metadata(from statement: OpaquePointer) throws -> ClipboardRecord {
        guard let id = UUID(uuidString: string(statement, column: 0)),
              let kind = ClipboardKind(rawValue: string(statement, column: 1)) else {
            throw ClipboardStoreError.database("记录格式无效")
        }
        let source: ClipboardSource? = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : ClipboardSource(
            name: string(statement, column: 3),
            bundleIdentifier: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : string(statement, column: 4)
        )
        return ClipboardRecord(
            id: id, kind: kind, preview: string(statement, column: 2), source: source,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            isPinned: sqlite3_column_int(statement, 7) != 0,
            byteCount: Int(sqlite3_column_int64(statement, 8))
        )
    }

    private func validate(_ payload: ClipboardPayload) throws {
        guard !payload.items.isEmpty,
              payload.items.allSatisfy({ !$0.representations.isEmpty && $0.representations.keys.allSatisfy({ !$0.isEmpty }) }) else {
            throw ClipboardStoreError.invalidPayload
        }
        var bytes = 0
        var containsFile = false
        for item in payload.items {
            for (type, data) in item.representations {
                guard data.count <= ClipboardPayload.maximumByteCount - bytes else { throw ClipboardStoreError.invalidPayload }
                bytes += data.count
                if type == "public.file-url" {
                    guard let value = String(data: data, encoding: .utf8),
                          let url = URL(string: value), url.isFileURL, url.path.hasPrefix("/") else {
                        throw ClipboardStoreError.invalidPayload
                    }
                    containsFile = true
                }
            }
        }
        if payload.kind == .file, !containsFile { throw ClipboardStoreError.invalidPayload }
    }

    private func fingerprint(for payload: ClipboardPayload) -> String {
        var hash = SHA256()
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        // Explicit lengths distinguish item boundaries and binary values regardless of dictionary order.
        var itemCount = UInt64(payload.items.count).bigEndian
        withUnsafeBytes(of: &itemCount) { hash.update(data: Data($0)) }
        for item in payload.items {
            var typeCount = UInt64(item.representations.count).bigEndian
            withUnsafeBytes(of: &typeCount) { hash.update(data: Data($0)) }
            for type in item.representations.keys.sorted() {
                append(Data(type.utf8))
                append(item.representations[type]!)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func byteCount(for payload: ClipboardPayload) -> Int {
        payload.items.reduce(0) { total, item in total + item.representations.values.reduce(0) { $0 + $1.count } }
    }

    private func preview(for payload: ClipboardPayload) -> String {
        let text = payload.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.prefix(240)) }
        switch payload.kind {
        case .image: return "图片"
        case .file: return "文件"
        case .richText: return "富文本"
        case .link: return "链接"
        case .text: return "空文本"
        }
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func execute(_ sql: String, on connection: OpaquePointer? = nil) throws {
        let handle = connection ?? database
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError(handle) }
    }

    private func statement<T>(_ sql: String, on connection: OpaquePointer? = nil, body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        let handle = connection ?? database
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw databaseError(handle) }
        defer { sqlite3_finalize(prepared) }
        return try body(prepared)
    }

    @discardableResult
    private func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError(sqlite3_db_handle(statement))
        }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = value.withCString { sqlite3_bind_text64(statement, index, $0, UInt64(value.utf8.count), Self.transient, UInt8(SQLITE_UTF8)) }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw databaseError() }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw databaseError() }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw databaseError() }
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64(value.count), Self.transient) }
        guard result == SQLITE_OK else { throw databaseError() }
    }

    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private func blob(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func databaseError(_ connection: OpaquePointer? = nil) -> ClipboardStoreError {
        let message = (connection ?? database).map { String(cString: sqlite3_errmsg($0)) } ?? "数据库无法打开"
        return .database(message)
    }
}
