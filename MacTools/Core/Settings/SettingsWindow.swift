import SwiftUI
import AppKit

/// 独立 NSWindow：760×560，最小 720×520，可 resize，⌘W 关闭。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTools 设置"
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.delegate = self
        let hosting = NSHostingView(rootView: SettingsRootView(environment: environment, page: page))
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
