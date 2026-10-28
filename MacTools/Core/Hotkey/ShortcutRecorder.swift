import SwiftUI
import AppKit
import ServiceManagement

/// 快捷键录制控件。点击进入录制态；Esc 取消，Delete 清空；录制完成立即尝试注册，
/// 失败原地显示错误（不弹窗、不回滚）。
struct ShortcutRecorder: NSViewRepresentable {

    @Binding var shortcut: HotkeyManager.Shortcut?
    var onCommit: (HotkeyManager.Shortcut) throws -> Void
    var onClear: () -> Void = {}

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.shortcut = shortcut
        view.onCommit = { newValue in
            do {
                try onCommit(newValue)
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? "已被占用"
            }
        }
        view.onClear = {
            shortcut = nil
            onClear()
        }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.onCommit = { newValue in
            do {
                try onCommit(newValue)
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? "已被占用"
            }
        }
        view.onClear = {
            shortcut = nil
            onClear()
        }
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var shortcut: HotkeyManager.Shortcut?
        var onCommit: ((HotkeyManager.Shortcut) -> String?)?
        var onClear: (() -> Void)?

        private var isRecording = false
        private var errorText: String?

        /// 胶囊高度。行高由外部 `.frame(height: 40)` 给定，胶囊在行内垂直居中。
        static let capsuleHeight: CGFloat = 26

        /// 胶囊位置：**垂直居中**。
        ///
        /// 原来画在 `bounds.height - 26`（贴顶），设 40pt 行高时胶囊占 14…40、中线偏上 7pt，
        /// 而行内的「唤起浮窗」和「可能冲突：…」都是按行中线对齐的 —— 三个元素看着就歪了。
        static func capsuleRect(in bounds: NSRect) -> NSRect {
            NSRect(
                x: 0,
                y: ((bounds.height - capsuleHeight) / 2).rounded(),
                width: bounds.width,
                height: capsuleHeight
            )
        }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 156, height: 40) }

        override func mouseDown(with event: NSEvent) {
            errorText = nil
            isRecording = true
            window?.makeFirstResponder(self)
            needsDisplay = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            needsDisplay = true
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }

            // Esc 取消
            if event.keyCode == 53 {
                isRecording = false
                needsDisplay = true
                return
            }
            // Delete 清空
            if event.keyCode == 51 || event.keyCode == 117 {
                onClear?()
                isRecording = false
                needsDisplay = true
                return
            }

            guard let captured = HotkeyManager.Shortcut(event: event) else {
                // 必须含至少一个修饰键
                errorText = "需包含 ⌘/⌥/⌃/⇧"
                needsDisplay = true
                return
            }

            if let message = onCommit?(captured) {
                errorText = message
                isRecording = false
                needsDisplay = true
                return
            }

            shortcut = captured
            errorText = nil
            isRecording = false
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let capsuleRect = Self.capsuleRect(in: bounds)
            let path = NSBezierPath(roundedRect: capsuleRect, xRadius: 7, yRadius: 7)

            let borderColor: NSColor
            if errorText != nil {
                borderColor = .systemRed
            } else if isRecording {
                borderColor = .controlAccentColor
            } else {
                borderColor = .separatorColor
            }

            NSColor.controlBackgroundColor.setFill()
            path.fill()

            borderColor.setStroke()
            path.lineWidth = isRecording || errorText != nil ? 2 : 1
            path.stroke()

            // 错误提示就画在胶囊里（红色替换内容）。
            // 以前把它塞在胶囊下方 14pt 的缝里，胶囊只能贴顶，整行跟着歪；现在胶囊恒居中。
            if let errorText {
                drawCentered(
                    errorText,
                    in: capsuleRect,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                        .foregroundColor: NSColor.systemRed,
                    ]
                )
                return
            }

            let text: String
            if isRecording {
                text = "按下快捷键…"
            } else if let shortcut {
                text = shortcut.displayString
            } else {
                text = "未设置"
            }

            drawCentered(
                text,
                in: capsuleRect,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
                ]
            )
        }

        private func drawCentered(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}

/// 登录时启动（SMAppService）。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
