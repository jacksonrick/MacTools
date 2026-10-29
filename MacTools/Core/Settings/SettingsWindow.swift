import SwiftUI
import AppKit

/// 独立 NSWindow：固定 680×520，不可缩放（⌘W 关闭）。
/// 尺寸固定是因为内容按档位排布（快捷键行、滑杆宽度都是定值），
/// 拉宽只会让控件之间出现大片空白，不如干脆锁死。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private static let contentSize = NSSize(width: 680, height: 520)

    private let environment: AppEnvironment
    private var window: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    func show(page: SettingsPage = .general) {
        if window == nil {
            build(page: page)
        }
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func build(page: SettingsPage) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            // 没有 .resizable：窗口尺寸锁死，用户拖不动边框。
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTools 设置"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self

        let hosting = NSHostingView(rootView: SettingsRootView(environment: environment, page: page))
        hosting.frame = NSRect(origin: .zero, size: Self.contentSize)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.setContentSize(Self.contentSize)
        window.center()
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
