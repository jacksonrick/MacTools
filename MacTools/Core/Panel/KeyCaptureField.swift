import SwiftUI
import AppKit

/// 隐形输入框：整套 HUD 的唯一文本入口。
/// 用 NSTextField 而不是自绘键盘处理，是为了直接复用系统的 IME（中文输入法）行为。
final class HUDKeyField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            hideSystemCaret()
            currentEditor()?.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        }
        return result
    }

    /// 隐形输入框的位置与可见文字无关，因此系统光标必须隐藏，
    /// 由工具条在文字末尾自绘 `BlinkingCaret`。
    func hideSystemCaret() {
        (currentEditor() as? NSTextView)?.insertionPointColor = .clear
    }

    // 隐形输入框不参与鼠标命中，避免抢走列表点击。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct KeyCaptureField: NSViewRepresentable {
    let router: HUDRouter
    let text: String
    let focusToken: Int
    let textToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(router: router)
    }

    func makeNSView(context: Context) -> HUDKeyField {
        let field = HUDKeyField()
        field.isBordered = false
        field.drawsBackground = false
        field.isBezeled = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.textColor = .clear
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.field = field
        router.keyField = field
        return field
    }

    func updateNSView(_ field: HUDKeyField, context: Context) {
        context.coordinator.router = router
        router.keyField = field

        if context.coordinator.lastTextToken != textToken {
            context.coordinator.lastTextToken = textToken
            context.coordinator.write(text, to: field)
        } else if field.currentString != text {
            context.coordinator.write(text, to: field)
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            Task { @MainActor in
                field.window?.makeFirstResponder(field)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var router: HUDRouter
        weak var field: HUDKeyField?
        var isSyncing = false
        var lastFocusToken = -1
        var lastTextToken = -1

        init(router: HUDRouter) {
            self.router = router
        }

        /// 同步文本到输入框，并把光标放到末尾。
        func write(_ value: String, to field: HUDKeyField) {
            let current = field.currentString
            guard current != value else { return }
            isSyncing = true
            field.stringValue = value
            if let editor = field.currentEditor() as? NSTextView {
                editor.insertionPointColor = .clear
                editor.string = value
                editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            }
            isSyncing = false
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isSyncing, let field = obj.object as? HUDKeyField else { return }
            router.applyText(field.currentString, fromField: true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return router.handle(.arrowUp)
            case #selector(NSResponder.moveDown(_:)):
                return router.handle(.arrowDown)
            case #selector(NSResponder.moveLeft(_:)):
                return router.handle(.arrowLeft)
            case #selector(NSResponder.moveRight(_:)):
                return router.handle(.arrowRight)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                return router.handle(.enter)
            case #selector(NSResponder.cancelOperation(_:)):
                return router.handle(.escape)
            case #selector(NSResponder.insertTab(_:)):
                return router.handle(.tab)
            case #selector(NSResponder.insertBacktab(_:)):
                return router.handle(.shiftTab)
            default:
                return false
            }
        }
    }
}

extension HUDKeyField {
    /// 编辑状态下 `stringValue` 可能滞后于 field editor，这里取真实值。
    var currentString: String {
        if let editor = currentEditor() as? NSTextView {
            return editor.string
        }
        return stringValue
    }
}
