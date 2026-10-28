#if DEBUG
import AppKit

/// 仅 DEBUG：把浮窗 / 设置窗口渲染成 PNG，用于在没有屏幕录制权限的机器上检查版式。
///
/// 用法：
/// `MACTOOLS_DEBUG_SNAPSHOT=/tmp/hud.png MACTOOLS_DEBUG_SNAPSHOT_STATE=clipboard \
///  MACTOOLS_DEBUG_SOLID=1 ./MacTools`
///
/// `MACTOOLS_DEBUG_SNAPSHOT_STATE=settings` 抓的是设置窗口，可用 `…_PAGE` 指定选中页
/// （general / clipboard / translation / keywords / about）。
///
/// 说明：Liquid Glass 由窗口服务器合成，位图里会是透明的；配合 `MACTOOLS_DEBUG_SOLID=1`
/// 把材质降级成实体后再抓图，几何/字号/间距与真实一致，仅材质不同。
@MainActor
enum HUDSnapshot {

    static func capture(window: NSWindow, to path: String) throws {
        guard let view = window.contentView else {
            throw SnapshotError.noContentView
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotError.bitmapUnavailable
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodeFailed
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func capture(panel: NSPanel, to path: String) throws {
        try capture(window: panel, to: path)
    }

    enum SnapshotError: Error {
        case noContentView
        case bitmapUnavailable
        case encodeFailed
    }
}

/// 仅 DEBUG：给截图流程造一张「假桌面」，用来在没有真实屏幕录制授权的机器上核查版式。
@MainActor
enum DebugScreenMock {

    static func image(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGradient(colors: [
            NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.26, alpha: 1),
            NSColor(calibratedRed: 0.24, green: 0.12, blue: 0.22, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: -55)

        // 几个「窗口」色块
        let blocks: [(CGRect, NSColor)] = [
            (CGRect(x: size.width * 0.06, y: size.height * 0.55, width: size.width * 0.34, height: size.height * 0.34),
             NSColor(calibratedWhite: 0.16, alpha: 1)),
            (CGRect(x: size.width * 0.46, y: size.height * 0.5, width: size.width * 0.3, height: size.height * 0.4),
             NSColor(calibratedWhite: 0.22, alpha: 1)),
        ]
        for (rect, color) in blocks {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            path.lineWidth = 1
            path.stroke()
        }

        let caption = "假桌面 · 截图版式自查"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.7),
        ]
        (caption as NSString).draw(
            at: NSPoint(x: size.width * 0.06, y: size.height * 0.42),
            withAttributes: attributes
        )

        for index in 0..<6 {
            NSColor(calibratedWhite: 1, alpha: 0.06).setFill()
            NSRect(x: size.width * 0.06, y: size.height * (0.34 - Double(index) * 0.045),
                   width: size.width * 0.7, height: 10).fill()
        }
        return image
    }
}
#endif
