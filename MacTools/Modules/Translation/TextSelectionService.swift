import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 取词回退链：AXSelectedText → AppleScript → 保存剪贴板 + 合成 ⌘C。
@MainActor
enum TextSelectionService {

    enum Failure: LocalizedError, Equatable {
        case accessibilityNotGranted
        case secureInput
        case composing
        case unavailable

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted: "未授予「辅助功能」权限，无法读取选中文本"
            case .secureInput: "当前应用禁止读取选中文本（安全输入）"
            case .composing: "请先完成输入"
            case .unavailable: "没有取到选中的文本"
            }
        }
    }

    static func readSelection() async -> Result<String, Failure> {
        // 第一级（AX）与第三级（⌘C）都以「辅助功能」授权为前提。没授权时三层全是空的，
        // 最终只会落到 .unavailable（「没有取到选中的文本」）—— 用户据此完全无法排查，
        // 只能怀疑是选中没选对。所以先把「没权限」这件事单独报出来。
        guard AXIsProcessTrusted() else {
            Log.trace("[selection] 未授予辅助功能权限，取词链路中止")
            return .failure(.accessibilityNotGranted)
        }

        if let text = axSelectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.trace("[selection] 第一级 AX 命中，长度 \(text.count)")
            return .success(text)
        }
        if let text = await appleScriptSelectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.trace("[selection] 第二级 AppleScript 命中，长度 \(text.count)")
            return .success(text)
        }
        if IsSecureEventInputEnabled() {
            return .failure(.secureInput)
        }
        if hasMarkedText() {
            return .failure(.composing)
        }
        if let text = await pasteboardFallback(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.trace("[selection] 第三级 ⌘C 命中，长度 \(text.count)")
            return .success(text)
        }
        Log.trace("[selection] 三级回退全空：前台应用既没暴露 AXSelectedText，也对 ⌘C 无响应")
        return .failure(.unavailable)
    }

    // MARK: 一级：AX

    private static func axSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)

        guard let focused = copyAttribute(appElement, kAXFocusedUIElementAttribute) else { return nil }
        let focusedElement = focused as! AXUIElement
        guard let value = copyAttribute(focusedElement, kAXSelectedTextAttribute) else { return nil }
        return value as? String
    }

    private static func hasMarkedText() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let application = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let focused = copyAttribute(appElement, kAXFocusedUIElementAttribute) else { return false }
        let focusedElement = focused as! AXUIElement
        if let marked = copyAttribute(focusedElement, "AXMarkedText") as? String {
            return !marked.isEmpty
        }
        return false
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as AnyObject?
    }

    // MARK: 二级：AppleScript（Safari / Chrome / Edge 等支持 AX 脚本的应用）

    private static func appleScriptSelectedText() async -> String? {
        let script = """
        tell application "System Events"
            try
                set frontApp to first application process whose frontmost is true
                set focusedElement to value of attribute "AXFocusedUIElement" of frontApp
                set selectedText to value of attribute "AXSelectedText" of focusedElement
                return selectedText
            on error
                return ""
            end try
        end tell
        """
        // 放到主线程之外执行：首次调用会弹「自动化」授权框，而 NSAppleScript 是**同步阻塞**的，
        // 留在主线程会让整个浮窗一直卡着（最长等到弹窗超时）。
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let appleScript = NSAppleScript(source: script) else { return nil }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                if code == -1743 {
                    Log.trace("[selection] AppleScript 被系统拒绝：未授予「自动化」权限")
                }
                return nil
            }
            return result.stringValue
        }.value
    }

    // MARK: 三级：剪贴板 + ⌘C

    private static func pasteboardFallback() async -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            var hasContent = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    hasContent = true
                }
            }
            return hasContent ? copy : nil
        } ?? []

        let baseline = pasteboard.changeCount
        PasteService.synthesizeCommandC()

        var didCopy = false
        var elapsed = 0
        while elapsed < 200 {
            try? await Task.sleep(for: .milliseconds(20))
            elapsed += 20
            if pasteboard.changeCount != baseline {
                didCopy = true
                break
            }
        }

        // 只有 changeCount 变了才说明 ⌘C 真的执行过。否则前台应用没有选中内容
        // （或干脆不响应 ⌘C），剪贴板还是原来那份东西 —— 直接读出来会把「上次复制的内容」
        // 当成选中文本送去翻译，看着像取词成功，其实是拿错了数据。
        let selected = didCopy ? pasteboard.string(forType: .string) : nil

        // 还原剪贴板
        pasteboard.clearContents()
        if !savedItems.isEmpty {
            pasteboard.writeObjects(savedItems)
        }

        return selected
    }
}
