import SwiftUI

/// 顶部工具条：左侧输入框 + 右侧四个圆形功能按钮（Spotlight 式）。
/// 输入框始终可见、始终持有焦点；Tab 循环切换激活的功能。
struct SpotlightBarView: View {
    let router: HUDRouter
    let settings: SettingsStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forceSolidSurfaces) private var forceSolid

    static var width: CGFloat { PanelPositioner.contentWidth }
    static let height: CGFloat = 58
    private let circleSize: CGFloat = 52
    private let gap: CGFloat = 10
    private let inputGap: CGFloat = 12

    private var inputWidth: CGFloat {
        Self.width - (circleSize * 4 + gap * 3) - inputGap
    }

    var body: some View {
        HStack(spacing: inputGap) {
            inputCapsule
                .frame(width: inputWidth)
            HStack(spacing: gap) {
                ForEach(ModuleID.allCases) { module in
                    circleButton(for: module)
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
    }

    // MARK: 输入框

    private var inputCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: leadingSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(router.currentModule == nil ? Color.secondary : Color.accentColor)
                .frame(width: 18)

            HStack(spacing: 2) {
                Text(displayText)
                    .font(inputFont)
                    .foregroundStyle(router.text.isEmpty ? Color.secondary.opacity(0.75) : Color.primary)
                    .lineLimit(1)
                    // 占位文案尾部截断；用户输入时保留末尾（光标所在处）可见。
                    .truncationMode(router.text.isEmpty ? .tail : .head)

                if router.acceptsText {
                    BlinkingCaret()
                }
                Spacer(minLength: 0)
            }

            trailingHint
        }
        .padding(.horizontal, 18)
        .frame(height: Self.height)
        .controlGlass(cornerRadius: Self.height / 2)
        .contentShape(Capsule())
        .onTapGesture { router.requestFocus() }
    }

    private var leadingSymbol: String {
        router.currentModule?.symbol ?? "magnifyingglass"
    }

    private var inputFont: Font {
        if case .module(.calculator) = router.level {
            return Typography.expression
        }
        return .system(size: 17, weight: .regular)
    }

    private var displayText: String {
        if !router.text.isEmpty { return router.text }
        switch router.level {
        case .hidden, .bar:
            return "输入指令"
        case .module(.clipboard):
            return "搜索剪贴板"
        case .module(.translation):
            return "输入翻译文本"
        case .module(.calculator):
            return "输入计算表达式"
        case .module(.screenshot):
            return "回车开始截图"
        }
    }

    @ViewBuilder
    private var trailingHint: some View {
        // 未激活功能时的关键词反馈直接放在输入框右侧（状态行已收进卡片，栏位不再单独占一行）。
        if case .bar = router.level, !router.keywordBuffer.isEmpty {
            Text(router.hasKeywordPrefix(router.keywordBuffer) ? "请输入指令" : "无匹配")
                .font(Typography.hint)
                .foregroundStyle(Color.orange)
        } else {
            HStack(spacing: 4) {
                KeyCap(text: "Tab")
                Text("切换")
                    .font(Typography.keyCap)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 圆形按钮

    @ViewBuilder
    private func circleButton(for module: ModuleID) -> some View {
        let active = router.currentModule == module
        let keyword = settings.keywords(for: module).first ?? module.title

        Button {
            router.switchTo(module)
        } label: {
            Image(systemName: module.symbol)
                .font(.system(size: 19, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.82))
                .frame(width: circleSize, height: circleSize)
                .background { circleBackground(active: active) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("\(module.title)（\(keyword)）")
        .animation(Motion.resolve(Motion.settingSwitch, reduceMotion: reduceMotion), value: active)
    }

    @ViewBuilder
    private func circleBackground(active: Bool) -> some View {
        if active {
            Circle()
                .fill(Color.accentColor)
                .shadow(color: Color.accentColor.opacity(0.45), radius: 12, y: 3)
        } else if reduceTransparency || forceSolid {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1) }
        } else {
            Circle()
                .fill(Color.white.opacity(0.04))
                .glassEffect(.regular, in: .circle)
        }
    }
}
