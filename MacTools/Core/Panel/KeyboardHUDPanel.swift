import AppKit

/// 纯键盘驱动的非激活浮窗。
/// 关键约束：`canBecomeKey` 动态切换是整套交互的地基。合成 ⌘V 前必须先 `releaseKeyboard()`
/// 并让面板真正离场（orderOut），否则按键仍会落在本面板上。
final class KeyboardHUDPanel: NSPanel {

    private(set) var keyboardModeEngaged = false
    weak var router: HUDRouter?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: PanelPositioner.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = false
        worksWhenModal = true
    }

    override var canBecomeKey: Bool { keyboardModeEngaged }
    override var canBecomeMain: Bool { false }

    // MARK: - 键盘模式

    func engageKeyboard() {
        keyboardModeEngaged = true
        alphaValue = 1
        positionOnActiveScreen()
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeKey()
        focusKeyField()
        Log.trace("[engage] appActive=\(NSApp.isActive) isKey=\(isKeyWindow) canBecomeKey=\(canBecomeKey)")
    }

    func releaseKeyboard() {
        keyboardModeEngaged = false
        // 注意：不 resignKey。让出 key 依靠随后发生的 orderOut。
    }

    func positionOnActiveScreen() {
        PanelPositioner.apply(to: self)
    }

    func focusKeyField() {
        guard let field = router?.keyField else { return }
        makeFirstResponder(field)
        Task { @MainActor [weak self] in
            guard let self, let field = router?.keyField else { return }
            makeFirstResponder(field)
        }
    }

    // MARK: - 生命周期

    /// 淡出并离场；离场后立即把 key 归还给上一个 App（粘贴时序的前置条件）。
    func fadeOutAndOrderOut(duration: Double, completion: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.orderOut(nil)
                self.alphaValue = 1
                completion?()
            }
        }
    }

    func resetAfterDismiss() {
        alphaValue = 1
        if isVisible {
            orderOut(nil)
        }
    }

    // MARK: - 兜底按键（焦点不在隐形输入框时的路径）

    override func keyDown(with event: NSEvent) {
        if let key = Self.translate(event), router?.handle(key) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if router?.handle(.escape) == true { return }
        super.cancelOperation(sender)
    }

    static func translate(_ event: NSEvent) -> HUDKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return .command(characters.lowercased())
        }
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 48: return flags.contains(.shift) ? .shiftTab : .tab
        case 51: return .backspace
        case 123: return .arrowLeft
        case 124: return .arrowRight
        case 125: return .arrowDown
        case 126: return .arrowUp
        default: return nil
        }
    }
}
