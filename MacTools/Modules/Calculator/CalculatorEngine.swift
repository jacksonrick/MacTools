import Foundation
import SoulverCore

struct CalculationResult: Equatable, Sendable {
    let value: String
    let expression: String
}

/// SoulverCore 封装：四则、括号、百分比、变量、单位换算。
/// 汇率换算暂不提供（原先依赖的联网汇率快照已移除）。
@MainActor
final class CalculatorEngine {

    private let calculator: SoulverCore.Calculator
    private var variables = VariableList(variables: [])

    init() {
        calculator = SoulverCore.Calculator(customization: .standard)
    }

    func evaluate(_ expression: String) -> CalculationResult? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let result = calculator.calculate(trimmed, with: variables)
        guard !result.isFailedResult, !result.isEmptyResult else { return nil }
        let value = result.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return CalculationResult(value: value, expression: trimmed)
    }

    func resetVariables() {
        variables = VariableList(variables: [])
    }
}

// MARK: - 汇率拦截

extension CalculatorEngine {

    /// 常见货币代码 / 符号。汇率换算已下线，命中这些写法时不再交给 SoulverCore——
    /// 没有汇率表时它会按 1:1 直接给出 "$100.00"，是个静默错误，不如明确拒绝。
    private static let currencyCodes: Set<String> = [
        "usd", "cny", "rmb", "eur", "gbp", "jpy", "hkd", "twd", "krw", "aud",
        "cad", "chf", "sgd", "nzd", "thb", "rub", "inr", "brl", "mxn", "sek",
        "nok", "dkk", "zar", "try", "aed", "sar", "myr", "idr", "php", "vnd",
    ]

    private static let currencySymbols: Set<Character> = ["$", "¥", "￥", "€", "£", "₩", "₹"]

    private static let conversionKeywords = [" to ", " in ", " into ", "->", "→"]

    /// 需要实时汇率的表达式（跨币种换算 / 混合币种运算）。
    static func needsExchangeRate(_ expression: String) -> Bool {
        let lower = expression.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let codes = Set(words.filter { currencyCodes.contains($0) })
        let symbols = Set(expression.filter { currencySymbols.contains($0) })

        let wantsConversion = conversionKeywords.contains { lower.contains($0) }
        if codes.count >= 2 || symbols.count >= 2 { return true }
        if wantsConversion && (!codes.isEmpty || !symbols.isEmpty) { return true }
        return false
    }
}
