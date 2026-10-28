import Foundation

/// 诊断日志：默认 **不输出**，排查真机问题时用 `MACTOOLS_DEBUG_TRACE=1` 打开。
///
/// 这些 `[capture]` / `[annotate]` / `[key]` / `[engage]` 打点都是当初定位
/// 「回车不出截图」「第一次拖拽没反应」这类问题留下的证据链，留着有价值，
/// 但它们会跟着日常 Debug 运行一起刷屏，其中几条本身也不便宜——
/// `[capture] 覆盖层已上屏` 那行会枚举一遍 WindowServer 窗口表。
///
/// 统一收进这里：参数是 `@autoclosure`，没开开关时字符串根本不会被拼出来；
/// Release 构建里函数体是空的，连字面量都不落地（可用 `strings` 核对）。
enum Log {

    #if DEBUG
    /// 进程启动时读一次。
    nonisolated(unsafe) static let traceEnabled =
        ProcessInfo.processInfo.environment["MACTOOLS_DEBUG_TRACE"] == "1"

    static func trace(_ message: @autoclosure () -> String) {
        guard traceEnabled else { return }
        print(message())
    }
    #else
    @inline(__always)
    static func trace(_ message: @autoclosure () -> String) {}
    #endif
}
