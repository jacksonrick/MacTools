import SwiftUI

/// 浮窗根视图。尺寸固定；内容从上到下只有工具条与功能卡片两块。
/// 工具条始终贴面板顶部固定高度，卡片按各功能自身高度向下伸展——切功能时输入框不跳动。
/// 透明区域的点击等价于 Esc。
struct HUDRootView: View {
    let router: HUDRouter
    let settings: SettingsStore
    let calculator: CalculatorController?
    let clipboard: ClipboardController?
    let translation: TranslationController?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation? {
        Motion.resolve(Motion.morphForward, reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { router.clickOutside() }

            VStack(spacing: PanelPositioner.contentGap) {
                SpotlightBarView(router: router, settings: settings)

                if let module = router.currentModule {
                    moduleContent(module)
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(y: -8))
                                    .combined(with: .scale(scale: 0.985, anchor: .top)),
                                removal: .opacity.combined(with: .offset(y: -6))
                            )
                        )
                }
            }
            .frame(width: SpotlightBarView.width, alignment: .top)
            .padding(.top, PanelPositioner.topInset)

            // 唯一文本入口：放在输入框内，让 IME 候选窗贴着光标出现。
            KeyCaptureField(
                router: router,
                text: router.text,
                focusToken: router.focusToken,
                textToken: router.textToken
            )
            .frame(width: 2, height: 12)
            .position(x: 300, y: fieldCenterY)
        }
        .frame(width: PanelPositioner.panelSize.width, height: PanelPositioner.panelSize.height)
        .animation(animation, value: router.level)
    }

    /// 隐形输入框的中心 y（布局固定，因此可直接算）。
    private var fieldCenterY: CGFloat {
        PanelPositioner.topInset + SpotlightBarView.height / 2
    }

    @ViewBuilder
    private func moduleContent(_ module: ModuleID) -> some View {
        switch module {
        case .clipboard:
            if let clipboard {
                ClipboardModuleView(controller: clipboard, router: router)
            } else {
                PlaceholderModuleView(module: .clipboard)
            }
        case .screenshot:
            ScreenshotHintView(router: router)
        case .translation:
            if let translation {
                TranslationModuleView(controller: translation, router: router)
            } else {
                PlaceholderModuleView(module: .translation)
            }
        case .calculator:
            if let calculator {
                CalculatorModuleView(controller: calculator, router: router)
            } else {
                PlaceholderModuleView(module: .calculator)
            }
        }
    }
}
