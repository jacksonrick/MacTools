import Foundation
import GRDB

/// 单一存储：所有数据与设置都写在 `~/Library/Application Support/MacTools/settings.sqlite`。
///
/// - `clips` + `clips_fts`：剪贴板内容（FTS5 全文索引）
/// - `kv`：设置项、计算历史、翻译凭据、迁移标记
///
/// 历史版本曾把剪贴板放 `clips.sqlite`、其余放 UserDefaults，
/// 首次启动会自动改名并搬迁（见 `LegacyImporter`）。
final class AppDatabase: Sendable {

    static let fileName = "settings.sqlite"
    static let legacyFileName = "clips.sqlite"

    let queue: DatabaseQueue
    /// 磁盘库的文件路径；内存库为 nil。
    let fileURL: URL?

    static func directoryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("MacTools", isDirectory: true)
    }

    static func defaultURL() -> URL {
        directoryURL().appendingPathComponent(fileName)
    }

    init(url: URL = AppDatabase.defaultURL()) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.renameLegacyDatabaseIfNeeded(at: url)

        // WAL + synchronous=NORMAL：设置由主线程同步写、剪贴板由后台写，
        // 这种组合下每次提交的开销最小；崩溃最多丢最后一条事务。
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        self.queue = queue
        self.fileURL = url

        try Self.migrate(queue)
        Self.restrictPermissions(directory: directory, fileURL: url)
    }

    private init(memoryQueue: DatabaseQueue) throws {
        self.queue = memoryQueue
        self.fileURL = nil
        try Self.migrate(memoryQueue)
    }

    /// 测试 / 自检用的内存库。
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(memoryQueue: DatabaseQueue())
    }

    // MARK: - 建表

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        // 与历史 clips.sqlite 完全一致的迁移标识与 SQL：
        // 旧库改名后此处会被自动跳过，不会重建表。
        migrator.registerMigration("v1.clips") { db in
            try db.execute(sql: """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    contentHash TEXT NOT NULL,
                    content TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    lastSeenAt DATETIME NOT NULL,
                    pasteCount INTEGER NOT NULL DEFAULT 0,
                    isPinned BOOLEAN NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX idx_clips_hash ON clips(contentHash)")
            try db.execute(sql: "CREATE INDEX idx_clips_lastSeen ON clips(lastSeenAt DESC)")
            try db.execute(sql: "CREATE INDEX idx_clips_pinned ON clips(isPinned, lastSeenAt DESC)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    content,
                    content='clips',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, content) VALUES (new.id, new.content);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, content) VALUES('delete', old.id, old.content);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, content) VALUES('delete', old.id, old.content);
                    INSERT INTO clips_fts(rowid, content) VALUES (new.id, new.content);
                END
                """)
        }

        migrator.registerMigration("v2.keyValue") { db in
            try db.execute(sql: """
                CREATE TABLE kv (
                    key TEXT PRIMARY KEY NOT NULL,
                    value BLOB NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_kv_updatedAt ON kv(updatedAt DESC)")
        }

        try migrator.migrate(queue)
    }

    // MARK: - 旧库改名

    /// 旧版本只有 `clips.sqlite`：整体改名成 `settings.sqlite`，
    /// 连同 `-wal` / `-shm` 一起搬，避免丢最近事务。
    private static func renameLegacyDatabaseIfNeeded(at url: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else { return }

        let legacy = url.deletingLastPathComponent().appendingPathComponent(legacyFileName)
        guard fileManager.fileExists(atPath: legacy.path) else { return }

        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: legacy.path + suffix)
            let to = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            try? fileManager.moveItem(at: from, to: to)
        }
    }

    /// 设置与凭据同库落盘，目录 0700、文件 0600，避免同机其他账户读取。
    private static func restrictPermissions(directory: URL, fileURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for suffix in ["", "-wal", "-shm"] {
            let path = fileURL.path + suffix
            guard fileManager.fileExists(atPath: path) else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    // MARK: - key/value 读写（同步，主线程调用；单行读写耗时 < 0.1ms）

    func containsKey(_ key: String) -> Bool {
        data(forKey: key) != nil
    }

    func data(forKey key: String) -> Data? {
        (try? queue.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }) ?? nil
    }

    func setData(_ data: Data?, forKey key: String) {
        do {
            try queue.write { db in
                guard let data else {
                    try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
                    return
                }
                try db.execute(
                    sql: """
                        INSERT INTO kv (key, value, updatedAt) VALUES (?, ?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                        """,
                    arguments: [key, data, Date()]
                )
            }
        } catch {
            Log.trace("[db] 写入设置失败 \(key)：\(error)")
        }
    }

    func removeValue(forKey key: String) {
        setData(nil, forKey: key)
    }

    func string(forKey key: String) -> String? {
        data(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setString(_ value: String?, forKey key: String) {
        setData(value.map { Data($0.utf8) }, forKey: key)
    }

    func int(forKey key: String) -> Int? {
        data(forKey: key).flatMap { Int(String(decoding: $0, as: UTF8.self)) }
    }

    func setInt(_ value: Int?, forKey key: String) {
        setData(value.map { Data(String($0).utf8) }, forKey: key)
    }

    func bool(forKey key: String) -> Bool? {
        guard let raw = string(forKey: key) else { return nil }
        switch raw {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    func setBool(_ value: Bool?, forKey key: String) {
        setData(value.map { Data(($0 ? "1" : "0").utf8) }, forKey: key)
    }

    func allKeys() -> [String] {
        (try? queue.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM kv ORDER BY key")
        }) ?? []
    }
}
