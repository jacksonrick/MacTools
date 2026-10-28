import AppKit
import ApplicationServices

/// 粘贴时序的执行者。
/// 关键约束：合成 ⌘V 之前必须让面板真正离场，否则按键会落回自己的浮窗。
@MainActor
enum PasteService {

    /// 仅写入剪贴板。
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 粘贴到前台应用：写剪贴板 → 收起浮窗（归还 key）→ 合成 ⌘V。
    /// 未授权辅助功能时只复制，状态行提示“已复制（需授权自动粘贴）”，3 秒后关闭。
    static func paste(_ text: String, router: HUDRouter) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            // 首次使用即请求辅助功能权限（系统弹窗只会出现一次）
            _ = PermissionCoordinator().requestAccessibilityIfNeeded()
            router.flashStatus("已复制（需授权自动粘贴）", duration: .seconds(3))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                router.close()
            }
            return
        }

        // 短等待确保 pasteboard 落定（PRD 5.1 粘贴时序第 2 步）
        Thread.sleep(forTimeInterval: 0.01)

        router.closeForAction(duration: 0.10) {
            synthesizeCommandV()
        }
    }

    static func synthesizeCommandV() {
        synthesize(keyCode: 9)   // 'v'
    }

    /// 合成 ⌘C（划词取词第三级回退链使用）。
    static func synthesizeCommandC() {
        synthesize(keyCode: 8)   // 'c'
    }

    private static func synthesize(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
