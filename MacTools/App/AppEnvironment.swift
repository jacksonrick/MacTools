import SwiftUI
import AppKit
import Observation

/// 依赖容器：所有长生命周期对象在此装配，避免视图层持有可变全局状态。
@Observable
@MainActor
final class AppEnvironment {

    let database: AppDatabase
    let settings: SettingsStore
    let hotkeys: HotkeyManager
    let router: HUDRouter
    let panel: KeyboardHUDPanel
    let permissions: PermissionCoordinator
    let calculationHistory: CalculationHistory
    let calculator: CalculatorController
    let clipboardLimits: ClipboardLimits
    let clipboardStore: ClipboardStore
    let clipboard: ClipboardController
    let translationService: TranslationService
    let translation: TranslationController
    let screenshot: ScreenshotController
    private let clipboardMonitor: ClipboardMonitor

    @ObservationIgnored weak var menuBar: MenuBarController?
    @ObservationIgnored private var localKeyMonitor: Any?
    private var settingsWindow: SettingsWindowController?

    init() {
        // 单一存储：所有数据与设置共用 settings.sqlite，首次启动顺带搬迁旧数据。
        let database: AppDatabase
        do {
            database = try AppDatabase()
        } catch {
            assertionFailure("settings.sqlite 打开失败：\(error)")
            database = try! AppDatabase.inMemory()
        }
        LegacyImporter.run(on: database)

        let settings = SettingsStore(database: database)
        let hotkeys = HotkeyManager()
        let router = HUDRouter()
        let panel = KeyboardHUDPanel()

        self.database = database
        self.settings = settings
        self.hotkeys = hotkeys
        self.router = router
        self.panel = panel
        self.permissions = PermissionCoordinator()

        let calculationHistory = CalculationHistory(database: database)
        let calculator = CalculatorController(
            history: calculationHistory,
            engine: CalculatorEngine()
        )
        self.calculationHistory = calculationHistory
        self.calculator = calculator

        let clipboardLimits = ClipboardLimits(maxBytes: settings.maxClipBytes, maxClips: settings.maxClips)
        let clipboardStore = ClipboardStore(database: database, limits: clipboardLimits)
        let clipboard = ClipboardController(store: clipboardStore, settings: settings)
        let clipboardMonitor = ClipboardMonitor(
            store: clipboardStore,
            initialChangeCount: NSPasteboard.general.changeCount
        )
        self.clipboardLimits = clipboardLimits
        self.clipboardStore = clipboardStore
        self.clipboard = clipboard
        self.clipboardMonitor = clipboardMonitor

        let translationService = TranslationService(database: database, activeEngine: settings.translationEngine)
        let translation = TranslationController(service: translationService, settings: settings)
        self.translationService = translationService
        self.translation = translation

        let screenshot = ScreenshotController(settings: settings, permissions: permissions)
        self.screenshot = screenshot

        router.register(calculator)
        router.register(clipboard)
        router.register(translation)
        router.register(ScreenshotController.Module(controller: screenshot))
        router.panel = panel
        router.settings = settings
        // 截图没有独立视图：工具条激活截图后，回车由路由回调到这里。
        router.onStartScreenshot = { [weak self] in
            self?.beginScreenshot()
        }
        panel.router = router

        // 下调存储上限要立刻淘汰，但滑杆拖动时 didSet 跟着刷新率走：
        // 每一下都是一次「DELETE … WHERE id NOT IN (SELECT … LIMIT n)」全表扫描。
        // 攒 200ms 跑一次，观感一样（用户还在拖），数据库少挨几十次。
        let eviction = EvictionDebouncer()
        settings.onMaxClipsReduced = { newValue in
            clipboardLimits.update(maxBytes: settings.maxClipBytes, maxClips: newValue)
            if settings.displayCount > newValue {
                settings.setDisplayCount(newValue)
            }
            eviction.schedule {
                do { try await clipboardStore.enforceLimit() } catch { /* 淘汰失败不影响设置生效 */ }
            }
        }
        settings.onMaxClipBytesChanged = { newValue in
            clipboardLimits.update(maxBytes: newValue, maxClips: settings.maxClips)
        }

        installContent(in: panel)
        wireHotkeys()
        installKeyMonitor()
        startClipboardMonitor()
        screenshot.warmUpIfAuthorized()
    }

    // MARK: - 装配

    private func installContent(in panel: KeyboardHUDPanel) {
        let hosting = NSHostingView(rootView: hostingRoot())
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = NSRect(origin: .zero, size: PanelPositioner.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    /// 正常是实时玻璃；`MACTOOLS_DEBUG_SOLID=1`（仅 DEBUG）时强制实体材质，
    /// 便于无屏幕录制权限的机器用窗口位图检查版式。
    private func hostingRoot() -> AnyView {
        let root = HUDRootView(
            router: router,
            settings: settings,
            calculator: calculator,
            clipboard: clipboard,
            translation: translation
        )
        #if DEBUG
        if ProcessInfo.processInfo.environment["MACTOOLS_DEBUG_SOLID"] == "1" {
            return AnyView(root.environment(\.forceSolidSurfaces, true))
        }
        #endif
        return AnyView(root)
    }

    private func wireHotkeys() {
        hotkeys.onTrigger = { [weak self] action in
            self?.perform(action)
        }
        for action in HotkeyManager.Action.allCases {
            guard let shortcut = settings.hotkeys[action] else { continue }
            try? hotkeys.register(action, shortcut: shortcut)
        }
    }

    /// 设置页修改快捷键后即时重注册。失败原地抛给调用方展示。
    func applyShortcut(_ action: HotkeyManager.Action, shortcut: HotkeyManager.Shortcut?) throws {
        if let shortcut {
            // 应用内三入口互斥
            for (other, existing) in settings.hotkeys where other != action && existing == shortcut {
                throw HotkeyManager.HotkeyError.conflict
            }
        }
        hotkeys.unregister(action)
        guard let shortcut else {
            settings.hotkeys[action] = nil
            return
        }
        try hotkeys.register(action, shortcut: shortcut)
        settings.hotkeys[action] = shortcut
    }

    func perform(_ action: HotkeyManager.Action) {
        switch action {
        case .toggleHUD:
            router.toggle()
        case .screenshot:
            beginScreenshot()
        case .selectionTranslate:
            beginSelectionTranslate()
        }
    }

    // MARK: - 模块入口（后续阶段接入控制器）

    private func beginScreenshot() {
        screenshot.onStatus = { [weak self] message in
            self?.router.flashStatus(message)
        }
        // 抓屏失败（冷启动时 SCK 偶尔拿不到画面）不能静默：把浮窗叫回来并说明原因。
        screenshot.onCaptureFailed = { [weak self] message in
            guard let self else { return }
            self.router.open()
            self.router.flashStatus(message, duration: .seconds(6))
        }

        guard router.isVisible else {
            screenshot.beginCapture()
            return
        }

        // 必须等浮窗真正离场再抓屏，否则半透明窗口会被一起拍进去。
        // 这里不用淡出动画而直接 orderOut：动画 + 完成回调 + 兜底定时器曾让
        // 「回车 → 抓屏」偶尔整条链路哑掉（看起来就是按回车没反应）。
        // orderOut 是同步的，随后立刻抓屏既不会入镜，也不存在时序竞态。
        router.dismissImmediately {
            self.screenshot.beginCapture()
        }
    }

    /// ⌥T：取词 → 直达翻译视图 → 自动发起翻译。
    private func beginSelectionTranslate() {
        Task { @MainActor in
            let result = await TextSelectionService.readSelection()
            switch result {
            case .success(let text):
                router.open(at: .translation, seed: text)
                translation.translate(router: router)
            case .failure(.accessibilityNotGranted):
                // 系统授权弹窗只会弹一次，而且只有主动调用过它，MacTools 才会出现在
                // 「辅助功能」列表里 —— 否则用户连勾选的入口都找不到（安装到别的路径后
                // 签名变了、旧授权失效，就是这个状态）。所以这里既弹窗也直接把设置页打开。
                permissions.requestAccessibilityIfNeeded()
                permissions.openAccessibilitySettings()
                router.open(at: .translation)
                router.flashStatus(
                    "取词需要「辅助功能」权限：在「隐私与安全性 → 辅助功能」里勾选 MacTools（不在列表就点 + 添加），然后重新按 ⌥T",
                    duration: .seconds(10)
                )
            case .failure(let failure):
                router.open(at: .translation)
                router.flashStatus(failure.errorDescription ?? "取词失败")
            }
        }
    }

    private func startClipboardMonitor() {
        let router = self.router
        let menuBarRef: () -> MenuBarController? = { [weak self] in self?.menuBar }
        Task { [clipboardMonitor] in
            await clipboardMonitor.start { message in
                router.flashStatus(message)
                menuBarRef()?.flashIcon()
            }
        }
    }

    // MARK: - 按键监视（⌘ 组合键与 Tab）

    private func installKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handlePanelKey(event) }
            return consumed ? nil : event
        }
    }

    private func handlePanelKey(_ event: NSEvent) -> Bool {
        guard event.window === panel, router.level != .hidden, !router.isDismissing else { return false }

        // 输入法正在拼字时，回车 / Esc 属于输入法自己的语义（上屏 / 取消候选），不能抢。
        let markedText = (panel.firstResponder as? NSTextView)?.hasMarkedText() ?? false

        // Tab / 回车 / Esc 在监视器里直接接管，不依赖隐形输入框的 doCommandBy 回调：
        // 焦点一旦被 SwiftUI 的按钮或列表拿走，那条回调就没了，回车会石沉大海。
        switch event.keyCode {
        case 48:
            let key: HUDKey = event.modifierFlags.contains(.shift) ? .shiftTab : .tab
            return router.handle(key)
        case 36, 76:
            guard !markedText else { return false }
            Log.trace("[key] 回车 level=\(router.level) marked=\(markedText)")
            return router.handle(.enter)
        case 53:
            guard !markedText else { return false }
            return router.handle(.escape)
        default:
            break
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            if let characters = event.charactersIgnoringModifiers, characters.count == 1 {
                return router.handle(.command(characters.lowercased()))
            }
        }
        return false
    }

    // MARK: - 设置窗口

    func openSettings(page: SettingsPage = .general) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(environment: self)
        }
        settingsWindow?.show(page: page)
    }
}

/// 把连续触发的动作合并成一次（200ms 静默窗口）。
///
/// 用在「下调存储上限 → 触发淘汰」上：滑杆拖动时每秒会来几十次回调，
/// 而每次淘汰都是一条全表扫描的 DELETE。攒一下再跑，行为不变、数据库少挨几十次。
@MainActor
private final class EvictionDebouncer {

    private var task: Task<Void, Never>?
    private static let delay = 200

    func schedule(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.delay))
            guard !Task.isCancelled else { return }
            await work()
        }
    }
}
