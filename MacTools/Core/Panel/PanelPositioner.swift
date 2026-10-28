import AppKit

enum PanelPositioner {
    /// 面板尺寸固定，不做运行时 resize（PRD 3.1 约束 2）。
    /// 高度按「上留白 + 工具条 + 间距 + 最高卡片 + 下留白」标定，跟随卡片收敛后整体更矮，
    /// 同样以 0.60 锚点居中时工具条自然落在屏幕偏上位置，不再贴着屏幕顶端。
    static let panelSize = CGSize(width: 820, height: 540)

    /// 工具条与内容卡片的统一宽度（面板两侧各留 16）。
    static let contentWidth: CGFloat = 788
    /// 工具条相对面板顶部的间距。
    static let topInset: CGFloat = 24
    /// 工具条与内容卡片之间的间距。
    static let contentGap: CGFloat = 12

    /// 鼠标当前所在屏幕。
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 锚点：屏幕高度 × 0.60（从底部算），面板中心对齐锚点。不跟随光标、不做边缘翻转。
    static func origin(for screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        let anchorY = frame.minY + frame.height * 0.60
        var x = frame.midX - panelSize.width / 2
        var y = anchorY - panelSize.height / 2

        // 仅做安全收敛，保证面板完整落在屏幕内。
        x = min(max(x, frame.minX), frame.maxX - panelSize.width)
        y = min(max(y, frame.minY), frame.maxY - panelSize.height)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    @MainActor
    static func apply(to panel: NSPanel) {
        guard let screen = activeScreen() else { return }
        panel.setFrame(NSRect(origin: origin(for: screen), size: panelSize), display: false)
    }
}
