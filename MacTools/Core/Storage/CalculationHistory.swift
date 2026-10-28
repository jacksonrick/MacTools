import Foundation
import Observation

struct CalculationRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let expression: String
    let result: String
    let timestamp: Date
}

/// 计算历史：`settings.sqlite` 的 `kv` 表，最多 10 条，FIFO。
@Observable
@MainActor
final class CalculationHistory {

    static let limit = 10
    private static let storageKey = "calc.history"

    private(set) var records: [CalculationRecord] = []
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
        load()
    }

    func add(expression: String, result: String) {
        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExpression.isEmpty, !trimmedResult.isEmpty else { return }

        // 同表达式同结果视为重复，移动到最前。
        records.removeAll { $0.expression == trimmedExpression && $0.result == trimmedResult }
        records.insert(
            CalculationRecord(id: UUID(), expression: trimmedExpression, result: trimmedResult, timestamp: Date()),
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
              let decoded = try? JSONDecoder().decode([CalculationRecord].self, from: data) else {
            records = []
            return
        }
        records = Array(decoded.prefix(Self.limit))
    }
}
