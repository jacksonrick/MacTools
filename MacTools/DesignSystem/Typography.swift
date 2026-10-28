import SwiftUI

enum Typography {
    /// 示例标签（计算器底部的样例表达式）。
    static let chipLabel = Font.system(size: 10, weight: .semibold, design: .monospaced)

    static let statusTitle = Font.system(size: 13, weight: .semibold)
    static let statusHint = Font.system(size: 11, weight: .regular)
    static let statusBadge = Font.system(size: 10, weight: .semibold, design: .monospaced)

    static let listRow = Font.system(size: 13, weight: .regular)
    static let listMeta = Font.system(size: 10, weight: .regular, design: .monospaced)

    static let previewBody = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let resultValue = Font.system(size: 34, weight: .medium, design: .rounded)
    static let resultValueSmall = Font.system(size: 22, weight: .medium, design: .rounded)
    static let expression = Font.system(size: 17, weight: .regular, design: .monospaced)

    static let hint = Font.system(size: 11, weight: .regular)
    static let keyCap = Font.system(size: 10.5, weight: .semibold, design: .rounded)
}
