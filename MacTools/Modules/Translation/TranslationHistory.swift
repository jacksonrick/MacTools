import Foundation
import Observation

struct TranslationRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let source: String
    let translated: String
    let targetLanguage: String
    let timestamp: Date
}

/// 翻译历史：`settings.sqlite` 的 `kv` 表，最多 10 条，FIFO（最新在前）。
@Observable
@MainActor
final class TranslationHistory {

    static let limit = 10
    private static let storageKey = "translation.history"

    private(set) var records: [TranslationRecord] = []
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
        load()
    }

    func add(source: String, translated: String, targetLanguage: String) {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranslated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedTranslated.isEmpty else { return }

        // 原文、译文、目标语言三者都相同才算重复：换了目标语言重新译是一次新记录。
        records.removeAll {
            $0.source == trimmedSource
            && $0.translated == trimmedTranslated
            && $0.targetLanguage == targetLanguage
        }
        records.insert(
            TranslationRecord(
                id: UUID(),
                source: trimmedSource,
                translated: trimmedTranslated,
                targetLanguage: targetLanguage,
                timestamp: Date()
            ),
            at: 0
        )
        if records.count > Self.limit {
            records = Array(records.prefix(Self.limit))
        }
        persist()
    }

    func clear() {
        records.removeAll()
        persist()
    }

    private func persist() {
        database.setData(try? JSONEncoder().encode(records), forKey: Self.storageKey)
    }

    private func load() {
        guard let data = database.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([TranslationRecord].self, from: data) else {
            records = []
            return
        }
        records = Array(decoded.prefix(Self.limit))
    }
}
