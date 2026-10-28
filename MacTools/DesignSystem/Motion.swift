import SwiftUI

/// 全局动画常量。规范：所有 morph 动画必须可中断（spring）。
///
/// 说明：`Animation.interpolatingSpring(response:dampingFraction:)` 在当前 SDK 中与一个同名的
/// 静态属性重名，导致该重载不可直接书写；`Animation.spring(response:dampingFraction:)`
/// 底层同为插值弹簧（response/dampingFraction 语义完全一致），因此统一使用后者。
enum Motion {
    /// 功能卡片出现/切换（工具条不动，只有内容区变形）。
    static let morphForward = Animation.spring(response: 0.36, dampingFraction: 0.80)
    static let settingSwitch = Animation.smooth(duration: 0.22)

    /// 关闭淡出时长（秒），必须与面板 `fadeOutAndOrderOut` 的默认时长一致。
    static let dismissDuration: Double = 0.14

    /// 遵循「减弱动态效果」：开启时返回 nil（即 .identity）。
    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
