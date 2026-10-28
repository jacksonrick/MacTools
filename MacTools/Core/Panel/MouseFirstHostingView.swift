import AppKit
import SwiftUI

/// SwiftUI 宿主视图的 `acceptsFirstMouse` 默认是 `false`。
///
/// 截图覆盖层是**非激活面板**：应用不是前台时，第一次按下鼠标只是「激活应用」，
/// 事件本身会被丢掉——表现就是「第一次拖拽毫无反应，松开再拖才行」。
/// 覆盖层里所有能命中鼠标的宿主视图都必须换成这个子类。
final class MouseFirstHostingView<Content: View>: NSHostingView<Content> {

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
