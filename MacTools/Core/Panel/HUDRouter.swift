import SwiftUI
import Observation
import AppKit

enum ModuleID: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboard
    case screenshot
    case translation
    case calculator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: "剪贴板"
        case .screenshot: "截图"
        case .translation: "翻译"
        case .calculator: "计算器"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .screenshot: "camera.viewfinder"
        case .translation: "character.bubble"
        case .calculator: "equal.square"
        }
    }

    /// 百度 / 有道这类关键词提示，仅在工具条 tooltip 与设置页出现。
    var subtitle: String {
        switch self {
        case .clipboard: "历史与搜索"
        case .screenshot: "回车开始截图"
        case .translation: "划词即译"
        case .calculator: "实时求值"
        }
    }

    /// 工具条上的顺序 = Tab 循环顺序。
    var index: Int {
        ModuleID.allCases.firstIndex(of: self) ?? 0
    }

    /// 该功能是否接收文本输入。
    var acceptsText: Bool {
        self != .screenshot
    }
}

enum HUDKey: Equatable {
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case tab
    case shiftTab
    case enter
    case escape
    case backspace
    /// ⌘ + 字符，如 "1"…"9"、"p"、"s"
    case command(String)
}

/// 功能视图的键盘处理器。路由把按键按当前激活的功能派发给对应控制器。
@MainActor
protocol ModuleControlling: AnyObject {
    var moduleID: ModuleID { get }
    func handle(_ key: HUDKey, router: HUDRouter) -> Bool
    func didChangeText(_ text: String, router: HUDRouter)
    func didEnter(router: HUDRouter)
    func didLeave(router: HUDRouter)
}

extension ModuleControlling {
    func didChangeText(_ text: String, router: HUDRouter) {}
    func didEnter(router: HUDRouter) {}
    func didLeave(router: HUDRouter) {}
}

/// 顶层状态机：工具条（未激活）→ 功能（已激活）。
///
/// 交互模型参考 Spotlight：一个输入框 + 四个圆形功能按钮。
/// - Tab / ⇧Tab 在四个功能间循环，未激活时按下即激活第一个（或最后一个）
/// - 输入框内容随激活功能改变语义（搜索 / 翻译 / 求值），切换功能时文本随行；
///   唯一例外是计算器——切进去一律从空开始（自然语言求不出值，留着更像是 bug）
/// - 未激活状态输入关键词（全文命中）即直接激活对应功能
@Observable
@MainActor
final class HUDRouter {

    enum Level: Equatable {
        case hidden
        /// 工具条可见但未激活任何功能
        case bar
        case module(ModuleID)
    }

    // MARK: 状态

    private(set) var level: Level = .hidden
    /// 未激活功能时的输入内容（关键词）。
    var keywordBuffer: String = ""

    var clipboardQuery: String = ""
    var calcExpression: String = ""
    var translationSource: String = ""

    private(set) var statusMessage: String?
    private(set) var isDismissing = false
    /// 每次需要把焦点交还给隐形输入框时递增。
    private(set) var focusToken: Int = 0
    /// 文本被外部改写（如划词预填）时递增，驱动输入框重新同步。
    private(set) var textToken: Int = 0

    // MARK: 依赖

    weak var panel: KeyboardHUDPanel?
    weak var keyField: NSTextField?
    var settings: SettingsStore?
    /// 截图没有独立视图：激活后回车即开始捕获（装配层注入）。
    var onStartScreenshot: (@MainActor () -> Void)?

    private var controllers: [ModuleID: any ModuleControlling] = [:]
    private var statusTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    var isVisible: Bool {
        level != .hidden && !isDismissing
    }

    var currentModule: ModuleID? {
        if case .module(let module) = level { return module }
        return nil
    }

    /// 当前激活功能是否接收文本（截图为 false）。
    var acceptsText: Bool {
        switch level {
        case .hidden: false
        case .bar: true
        case .module(let module): module.acceptsText
        }
    }

    // MARK: 注册

    func register(_ controller: any ModuleControlling) {
        controllers[controller.moduleID] = controller
    }

    func controller(for module: ModuleID) -> (any ModuleControlling)? {
        controllers[module]
    }

    // MARK: 文本通道（单一隐形输入框）

    var text: String {
        switch level {
        case .hidden, .bar: keywordBuffer
        case .module(.clipboard): clipboardQuery
        case .module(.calculator): calcExpression
        case .module(.translation): translationSource
        case .module(.screenshot): ""
        }
    }

    /// 用户键入（来自隐形输入框）。会触发各层级联动。
    func applyText(_ value: String, fromField: Bool) {
        switch level {
        case .hidden:
            break
        case .bar:
            keywordBuffer = value
            guard fromField else { return }
            activateByKeyword(value)
        case .module(.screenshot):
            // 截图不接收输入：把刚打进来的字符弹回去。
            if fromField { textToken += 1 }
        case .module(let module):
            switch module {
            case .clipboard:
                clipboardQuery = value
                controllers[.clipboard]?.didChangeText(value, router: self)
            case .calculator:
                calcExpression = value
                controllers[.calculator]?.didChangeText(value, router: self)
            case .translation:
                translationSource = value
                controllers[.translation]?.didChangeText(value, router: self)
            case .screenshot:
                break
            }
        }
    }

    /// 程序化写入当前层级的文本（划词预填、关键词直达等）。
    func setText(_ value: String) {
        applyText(value, fromField: false)
        textToken += 1
    }

    /// 关键词必须**全文命中**才激活；`=` 开头视为计算器表达式直接进入。
    private func activateByKeyword(_ buffer: String) {
        guard !buffer.isEmpty else { return }
        if buffer.hasPrefix("=") {
            enter(.calculator, seed: String(buffer.dropFirst()))
            return
        }
        guard let table = settings?.keywordTable, let module = table[buffer] else { return }
        enter(module, seed: nil)
    }

    /// 当前输入是否恰好命中某个关键词（用于工具条提示）。
    func keywordMatch(_ buffer: String) -> ModuleID? {
        guard !buffer.isEmpty, !buffer.hasPrefix("=") else { return nil }
        return settings?.keywordTable[buffer]
    }

    /// 是否存在以当前输入为前缀的关键词（用于「需完整输入」的提示）。
    func hasKeywordPrefix(_ buffer: String) -> Bool {
        guard !buffer.isEmpty else { return false }
        return settings?.keywordTable.keys.contains { $0.hasPrefix(buffer) } ?? false
    }

    // MARK: 状态转移

    func open() {
        dismissTask?.cancel()
        isDismissing = false
        keywordBuffer = ""
        // 设置里指定了默认功能就直接进去；否则停在工具条（Spotlight 式空态）。
        if let module = settings?.defaultModule {
            enter(module, seed: nil)
        } else {
            level = .bar
            textToken += 1
        }
        showPanel()
    }

    func open(at module: ModuleID, seed: String? = nil) {
        dismissTask?.cancel()
        isDismissing = false
        enter(module, seed: seed)
        showPanel()
    }

    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }

    /// 关键词 / 外部入口进入功能：清空输入框（可带 seed）。
    func enter(_ module: ModuleID, seed: String?) {
        #if DEBUG
        HUDDebug.trace("enter(\(module.rawValue)) seed=\(seed ?? "nil") from=\(level)")
        #endif
        if let previous = currentModule, previous != module {
            controllers[previous]?.didLeave(router: self)
        }
        resetText(for: module, seed: seed)
        keywordBuffer = ""
        level = .module(module)
        controllers[module]?.didEnter(router: self)
        requestFocus()
    }

    /// Tab / ⌘1–4 / 点击按钮：切换激活功能，输入框文本随行（计算器除外，见下）。
    func switchTo(_ module: ModuleID) {
        if case .module(let current) = level, current == module {
            requestFocus()
            return
        }
        let carried = text
        if let previous = currentModule {
            controllers[previous]?.didLeave(router: self)
        }
        resetText(for: module, seed: nil)
        // 先切层级再派发文本：applyText 按当前激活的功能落库。
        level = .module(module)
        // 计算器不接管上一条输入。翻译的原文/译文、剪贴板搜索词都是自然语言，
        // 带进计算器只会求不出值——输入框里留着一句算不了的文本，比空着更像 bug。
        // 想从工具条直达表达式，用 `=` 前缀，或进计算器后再输入。
        if module.acceptsText, module != .calculator, !carried.isEmpty {
            applyText(carried, fromField: false)
        }
        keywordBuffer = ""
        controllers[module]?.didEnter(router: self)
        requestFocus()
    }

    /// 在四个功能间循环。未激活时正向取第一个、反向取最后一个。
    func cycle(by direction: Int) {
        let all = ModuleID.allCases
        guard !all.isEmpty else { return }

        switch level {
        case .hidden:
            return
        case .bar:
            switchTo(direction >= 0 ? all[0] : all[all.count - 1])
        case .module(let current):
            guard let index = all.firstIndex(of: current) else { return }
            let next = (index + direction + all.count) % all.count
            switchTo(all[next])
        }
    }

    func back() {
        #if DEBUG
        HUDDebug.trace("back() from=\(level)")
        #endif
        guard case .module(let module) = level else {
            close()
            return
        }
        controllers[module]?.didLeave(router: self)
        keywordBuffer = ""
        level = .bar
        textToken += 1
        requestFocus()
    }

    private func resetText(for module: ModuleID, seed: String?) {
        switch module {
        case .clipboard:
            clipboardQuery = ""
        case .calculator:
            calcExpression = seed ?? ""
        case .translation:
            translationSource = seed ?? ""
        case .screenshot:
            break
        }
        textToken += 1
    }

    /// 执行主操作后关闭（粘贴/复制/翻译完成）。返回后调用方负责完成动作。
    func close() {
        #if DEBUG
        HUDDebug.trace("close() level=\(level) dismissing=\(isDismissing)")
        #endif
        guard level != .hidden, !isDismissing else { return }
        isDismissing = true
        dismissTask?.cancel()

        if let panel {
            panel.releaseKeyboard()
            panel.fadeOutAndOrderOut(duration: dismissDuration) { [weak self] in
                self?.finishDismiss()
            }
        } else {
            finishDismiss()
        }
    }

    /// 关闭动画时长（Reduce Motion 时立即关闭）
    var dismissDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Motion.dismissDuration
    }

    /// 供“动作型关闭”使用：先让出 key 并隐藏面板，再执行动作（粘贴时序的地基）。
    func closeForAction(duration: Double = 0.10, then action: @escaping @MainActor @Sendable () -> Void) {
        guard level != .hidden, !isDismissing else { return }
        isDismissing = true
        dismissTask?.cancel()

        let perform: @MainActor @Sendable () -> Void = { [weak self] in
            action()
            self?.finishDismiss()
        }

        if let panel {
            panel.releaseKeyboard()
            panel.fadeOutAndOrderOut(duration: duration, completion: perform)
        } else {
            perform()
        }
    }

    /// 立即离场（无动画）后执行动作。
    ///
    /// 截图必须走这条：浮窗哪怕半透明也会被拍进去，而“动画时长 + 完成回调 + 兜底定时器”
    /// 三重时序在真机上并不可靠（动画被系统合并 / 回调迟到时会整条链路哑掉）。
    /// `orderOut` 是同步生效的，随后立刻抓屏既不入镜，也没有竞态。
    func dismissImmediately(then action: @escaping @MainActor @Sendable () -> Void) {
        guard level != .hidden else {
            action()
            return
        }
        dismissTask?.cancel()
        statusTask?.cancel()
        statusMessage = nil
        isDismissing = false
        level = .hidden
        if let panel {
            panel.releaseKeyboard()
            panel.orderOut(nil)
            panel.resetAfterDismiss()
        }
        action()
    }

    private func finishDismiss() {
        statusTask?.cancel()
        statusMessage = nil
        level = .hidden
        isDismissing = false
        panel?.resetAfterDismiss()
    }

    // MARK: 按键派发

    @discardableResult
    func handle(_ key: HUDKey) -> Bool {
        switch level {
        case .hidden:
            return false
        case .bar:
            return handleInBar(key)
        case .module(let module):
            if let controller = controllers[module], controller.handle(key, router: self) {
                return true
            }
            switch key {
            case .tab:
                cycle(by: 1)
                return true
            case .shiftTab:
                cycle(by: -1)
                return true
            case .escape:
                back()
                return true
            case .enter:
                if module == .screenshot {
                    onStartScreenshot?()
                    return true
                }
                return false
            case .command(let character):
                if let index = Int(character), (1...ModuleID.allCases.count).contains(index) {
                    switchTo(ModuleID.allCases[index - 1])
                    return true
                }
                return false
            case .backspace:
                return handleBackspaceFallback()
            default:
                return false
            }
        }
    }

    private func handleInBar(_ key: HUDKey) -> Bool {
        switch key {
        case .tab, .arrowRight, .arrowDown:
            cycle(by: 1)
            return true
        case .shiftTab, .arrowLeft, .arrowUp:
            cycle(by: -1)
            return true
        case .enter:
            if keywordBuffer.isEmpty {
                flashStatus("输入指令激活功能，或按 Tab 切换")
            } else {
                flashStatus("没有匹配的指令")
            }
            return true
        case .escape:
            close()
            return true
        case .command(let character):
            if let index = Int(character), (1...ModuleID.allCases.count).contains(index) {
                switchTo(ModuleID.allCases[index - 1])
                return true
            }
            return false
        case .backspace:
            return handleBackspaceFallback()
        }
    }

    /// 焦点不在隐形输入框时的退格兜底（保证任何情况下都能删字符）。
    @discardableResult
    func handleBackspaceFallback() -> Bool {
        let current = text
        guard !current.isEmpty else { return false }
        applyText(String(current.dropLast()), fromField: true)
        textToken += 1
        return true
    }

    /// 点击面板透明区域：等价于 Esc（按当前层级关闭/返回）。
    func clickOutside() {
        switch level {
        case .hidden:
            break
        case .bar:
            close()
        case .module:
            back()
        }
    }

    // MARK: 面板

    private func showPanel() {
        guard let panel else { return }
        panel.positionOnActiveScreen()
        panel.engageKeyboard()
        requestFocus()
    }

    func requestFocus() {
        focusToken += 1
        guard let panel, let keyField else { return }
        panel.makeFirstResponder(keyField)
    }

    // MARK: 状态行提示

    func flashStatus(_ message: String, duration: Duration = .seconds(2.4)) {
        statusTask?.cancel()
        statusMessage = message
        statusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
}
