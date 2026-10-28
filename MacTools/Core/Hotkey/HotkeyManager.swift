import AppKit
import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey` 封装。无需辅助功能权限。
@MainActor
final class HotkeyManager {

    enum Action: String, CaseIterable, Codable, Sendable {
        case toggleHUD
        case screenshot
        case selectionTranslate

        var displayName: String {
            switch self {
            case .toggleHUD: "唤起浮窗"
            case .screenshot: "截图"
            case .selectionTranslate: "划词翻译"
            }
        }
    }

    struct Shortcut: Codable, Equatable, Hashable, Sendable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// 展示用：⌥⇧4
        var displayString: String {
            var text = ""
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            text += Self.keyName(for: keyCode)
            return text
        }

        var hasModifier: Bool {
            modifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey) != 0
        }

        static func keyName(for keyCode: UInt32) -> String {
            if let special = specialKeys[keyCode] { return special }
            // 使用当前键盘布局反查字符
            if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
               let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = data.withUnsafeBytes { buffer -> OSStatus in
                    guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
                    return UCKeyTranslate(
                        layout,
                        UInt16(keyCode),
                        UInt16(kUCKeyActionDisplay),
                        0,
                        UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        chars.count,
                        &length,
                        &chars
                    )
                }
                if status == noErr, length > 0 {
                    return String(utf16CodeUnits: chars, count: length).uppercased()
                }
            }
            return "Key\(keyCode)"
        }

        private static let specialKeys: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
    }

    enum HotkeyError: LocalizedError {
        case conflict
        case system(OSStatus)

        var errorDescription: String? {
            switch self {
            case .conflict: "已被占用"
            case .system(let code): "注册失败（\(code)）"
            }
        }
    }

    /// Carbon 修饰符位掩码（与 NSEvent.ModifierFlags 不同）。
    nonisolated static let carbonCommand = UInt32(cmdKey)
    nonisolated static let carbonOption = UInt32(optionKey)
    nonisolated static let carbonControl = UInt32(controlKey)
    nonisolated static let carbonShift = UInt32(shiftKey)

    /// 常见应用冲突软提示表（内置，灰色文字提示，不阻断）。
    static let softConflictHints: [String: String] = [
        "⌥Space": "Spotlight / 输入法切换",
        "⌘Space": "Spotlight",
        "⌃Space": "输入法切换",
        "⌥⇧4": "系统截图",
        "⌘⇧4": "系统截图",
        "⌥T": "部分浏览器新标签页",
        "⌘⇧5": "系统录屏",
    ]

    var onTrigger: ((Action) -> Void)?

    private var registered: [Action: EventHotKeyRef] = [:]
    private var idToAction: [UInt32: Action] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandlerIfNeeded()
    }

    /// 应用退出前可显式调用；正常情况下随进程结束由系统回收 Carbon 热键。
    func unregisterAll() {
        for (_, ref) in registered {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()
        idToAction.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    func register(_ action: Action, shortcut: Shortcut) throws {
        unregister(action)
        guard shortcut.hasModifier else { throw HotkeyError.conflict }

        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D_54_4F_53), id: id)

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            throw HotkeyError.system(status)
        }

        registered[action] = ref
        idToAction[id] = action
    }

    func unregister(_ action: Action) {
        guard let ref = registered.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(ref)
        idToAction = idToAction.filter { $0.value != action }
    }

    func update(_ action: Action, to shortcut: Shortcut) throws {
        try register(action, shortcut: shortcut)
    }

    fileprivate func fire(id: UInt32) {
        guard let action = idToAction[id] else { return }
        onTrigger?(action)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon 热键事件在主线程 run loop 派发，可直接断言 MainActor。
            MainActor.assumeIsolated {
                manager.fire(id: hotKeyID.id)
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, userData, &eventHandler)
    }
}

// MARK: - NSEvent → Carbon 转换

extension HotkeyManager.Shortcut {
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= HotkeyManager.carbonCommand }
        if flags.contains(.option) { carbon |= HotkeyManager.carbonOption }
        if flags.contains(.control) { carbon |= HotkeyManager.carbonControl }
        if flags.contains(.shift) { carbon |= HotkeyManager.carbonShift }
        guard carbon != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }
}
