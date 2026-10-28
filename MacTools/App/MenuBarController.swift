import AppKit

/// 菜单栏图标 + 右键菜单。左键唤起浮窗，右键打开菜单。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let environment: AppEnvironment
    private let statusItem: NSStatusItem

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let symbol = environment.settings.menuBarIconMode == .dot ? "circle.fill" : "wand.and.stars"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacTools")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "MacTools · ⌥Space"
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func refreshIcon() {
        configureButton()
    }

    /// 轻量状态反馈：菜单栏图标闪烁一次。
    func flashIcon() {
        guard let button = statusItem.button else { return }
        let original = button.image
        button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "超长已跳过")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            button.image = original
        }
    }

    @objc
    private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            environment.router.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let openItem = NSMenuItem(title: "打开 MacTools", action: #selector(openHUD), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "关于 MacTools", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 MacTools", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openHUD() {
        environment.router.open()
    }

    @objc private func openSettings() {
        environment.openSettings()
    }

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
