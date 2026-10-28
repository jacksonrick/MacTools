import Foundation
import GRDB
import CryptoKit

struct Clip: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "clips"

    var id: Int64?
    var contentHash: String
    var content: String
    var createdAt: Date
    var lastSeenAt: Date
    var pasteCount: Int
    var isPinned: Bool
}

enum ClipUpsertOutcome: Sendable {
    case stored
    case duplicate
    case skippedTooLong
}

/// 存储上限的可变快照（设置变更时由主线程更新，后台读取）。
final class ClipboardLimits: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMaxBytes: Int
    private var storedMaxClips: Int

    init(maxBytes: Int, maxClips: Int) {
        storedMaxBytes = maxBytes
        storedMaxClips = maxClips
    }

    var maxBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return storedMaxBytes
    }

    var maxClips: Int {
        lock.lock(); defer { lock.unlock() }
        return storedMaxClips
    }

    func update(maxBytes: Int, maxClips: Int) {
        lock.lock(); defer { lock.unlock() }
        storedMaxBytes = maxBytes
        storedMaxClips = maxClips
    }
}

/// GRDB + FTS5。所有 SQL 在后台队列执行，主线程只应用结果。
/// 表结构与 `kv` 设置表同处一个 `settings.sqlite`（见 `AppDatabase`）。
final class ClipboardStore: Sendable {

    let limits: ClipboardLimits
    private let dbQueue: DatabaseQueue

    init(database: AppDatabase, limits: ClipboardLimits) {
        self.limits = limits
        self.dbQueue = database.queue
    }

    /// 测试 / 自检：内存库。
    convenience init(inMemory limits: ClipboardLimits) throws {
        self.init(database: try AppDatabase.inMemory(), limits: limits)
    }

    // MARK: 写入

    /// 长度超限跳过（不截断）；重复内容只更新 lastSeenAt / pasteCount。
    @discardableResult
    func upsert(text: String) async throws -> ClipUpsertOutcome {
        let byteCount = text.utf8.count
        let maxBytes = limits.maxBytes
        guard byteCount <= maxBytes else { return .skippedTooLong }

        let hash = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let now = Date()
        let maxClips = limits.maxClips

        return try await dbQueue.write { db in
            let existing = try Clip.filter(Column("contentHash") == hash).fetchOne(db)
            if existing != nil {
                try db.execute(
                    sql: "UPDATE clips SET lastSeenAt = ?, pasteCount = pasteCount + 1 WHERE contentHash = ?",
                    arguments: [now, hash]
                )
            } else {
                let clip = Clip(
                    id: nil,
                    contentHash: hash,
                    content: text,
                    createdAt: now,
                    lastSeenAt: now,
                    pasteCount: 0,
                    isPinned: false
                )
                try clip.insert(db)
            }
            try Self.evict(db, limit: maxClips)
            return existing == nil ? .stored : .duplicate
        }
    }

    /// 淘汰：保留最近使用的 maxClips 条，置顶项永不淘汰。
    private static func evict(_ db: Database, limit: Int) throws {
        try db.execute(
            sql: """
                DELETE FROM clips WHERE isPinned = 0 AND id NOT IN (
                    SELECT id FROM clips ORDER BY lastSeenAt DESC LIMIT ?
                )
                """,
            arguments: [limit]
        )
    }

    func enforceLimit() async throws {
        let maxClips = limits.maxClips
        try await dbQueue.write { db in
            try Self.evict(db, limit: maxClips)
        }
    }

    // MARK: 读取

    func recent(limit: Int) async throws -> [Clip] {
        try await dbQueue.read { db in
            try Clip
                .order(Column("isPinned").desc, Column("lastSeenAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func count() async throws -> Int {
        try await dbQueue.read { db in
            try Clip.fetchCount(db)
        }
    }

    /// 搜索：CJK 走 LIKE（unicode61 不切分中文），其余走 FTS5 前缀匹配。
    func search(_ query: String, limit: Int) async throws -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await recent(limit: limit) }

        if Self.containsCJK(trimmed) {
            return try await dbQueue.read { db in
                try Clip
                    .filter(sql: "content LIKE ?", arguments: ["%\(trimmed)%"])
                    .order(Column("isPinned").desc, Column("lastSeenAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        }

        let pattern = Self.ftsPattern(trimmed)
        guard !pattern.isEmpty else { return try await recent(limit: limit) }
        return try await dbQueue.read { db in
            try Clip.fetchAll(db, sql: """
                SELECT clips.* FROM clips
                JOIN clips_fts ON clips_fts.rowid = clips.id
                WHERE clips_fts MATCH ?
                ORDER BY clips.isPinned DESC, clips.lastSeenAt DESC
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    private static func ftsPattern(_ query: String) -> String {
        let tokens = query
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()*:")) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    // MARK: 变更

    func markUsed(_ id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE clips SET lastSeenAt = ?, pasteCount = pasteCount + 1 WHERE id = ?", arguments: [Date(), id])
        }
    }

    func setPinned(_ id: Int64, pinned: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE clips SET isPinned = ? WHERE id = ?", arguments: [pinned, id])
        }
    }

    func delete(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id])
        }
    }

    func clearAll() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clips")
            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('rebuild')")
        }
    }
}
