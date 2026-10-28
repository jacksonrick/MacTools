import AppKit

/// 缩放手柄光标：边是双箭头，角是斜向双箭头。
///
/// 角上原来只能用 `.crosshair`——公开 API 里长期没有斜向调整光标（那是私有的
/// `_windowResizeNorthWestSouthEastCursor` 之类）。结果光标与画布空白处的十字一模一样，
/// 鼠标移到角上毫无反馈，看起来就像「角不能拉」，而边因为换成了上下/左右箭头所以正常。
///
/// macOS 15 起 `NSCursor.frameResize(position:directions:)` 提供了与系统窗口边缘同一套图形：
/// 八个位置一起换过来，角补上了斜箭头，边也从老的粗箭头变成系统原生细箭头，手感统一。
///
/// 光标实例不可变，缓存在这里只是为了别每次重算光标矩形都新建一遍。
enum ResizeCursor {

    nonisolated(unsafe) static let topLeft = NSCursor.frameResize(position: .topLeft, directions: .all)
    nonisolated(unsafe) static let top = NSCursor.frameResize(position: .top, directions: .all)
    nonisolated(unsafe) static let topRight = NSCursor.frameResize(position: .topRight, directions: .all)
    nonisolated(unsafe) static let left = NSCursor.frameResize(position: .left, directions: .all)
    nonisolated(unsafe) static let right = NSCursor.frameResize(position: .right, directions: .all)
    nonisolated(unsafe) static let bottomLeft = NSCursor.frameResize(position: .bottomLeft, directions: .all)
    nonisolated(unsafe) static let bottom = NSCursor.frameResize(position: .bottom, directions: .all)
    nonisolated(unsafe) static let bottomRight = NSCursor.frameResize(position: .bottomRight, directions: .all)

    /// 自检用：八个位置必须是八个**不同**的光标（曾出现过角退化成十字、与背景同款的情况）。
    static var all: [NSCursor] {
        [topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight]
    }
}
