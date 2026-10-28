import Foundation
import Observation

@Observable
@MainActor
final class CalculatorController: ModuleControlling {

    enum Mode: Equatable {
        case editing
        case history
    }

    let moduleID: ModuleID = .calculator

    private(set) var mode: Mode = .editing
    private(set) var result: CalculationResult?
    private(set) var historyIndex: Int = 0
    /// 命中了已下线的汇率换算时的说明文案（同时 `result` 为 nil）。
    private(set) var unsupportedReason: String?

    let history: CalculationHistory
    private let engine: CalculatorEngine

    init(history: CalculationHistory, engine: CalculatorEngine) {
        self.history = history
        self.engine = engine
    }

    // MARK: - ModuleControlling

    func didEnter(router: HUDRouter) {
        mode = .editing
        historyIndex = 0
        evaluate(router.calcExpression)
    }

    func didLeave(router: HUDRouter) {
        mode = .editing
    }

    private func evaluate(_ text: String) {
        if CalculatorEngine.needsExchangeRate(text) {
            result = nil
            unsupportedReason = "暂不支持汇率换算"
        } else {
            result = engine.evaluate(text)
            unsupportedReason = nil
        }
    }

    func didChangeText(_ text: String, router: HUDRouter) {
        if mode == .history {
            mode = .editing
            historyIndex = 0
        }
        evaluate(text)
    }

    func handle(_ key: HUDKey, router: HUDRouter) -> Bool {
        switch key {
        case .arrowUp:
            if mode == .editing {
                guard !history.records.isEmpty else { return true }
                mode = .history
                historyIndex = 0
                return true
            }
            if historyIndex == 0 {
                mode = .editing
                return true
            }
            historyIndex -= 1
            return true

        case .arrowDown:
            guard mode == .history else { return true }
            historyIndex = min(historyIndex + 1, max(history.records.count - 1, 0))
            return true

        case .enter:
            if mode == .history {
                guard history.records.indices.contains(historyIndex) else { return true }
                let record = history.records[historyIndex]
                mode = .editing
                historyIndex = 0
                router.setText(record.expression)
                return true
            }
            guard let result else { return false }
            history.add(expression: result.expression, result: result.value)
            PasteService.copy(result.value)
            router.close()
            return true

        case .escape:
            if mode == .history {
                mode = .editing
                return true
            }
            return false

        default:
            return false
        }
    }
}
