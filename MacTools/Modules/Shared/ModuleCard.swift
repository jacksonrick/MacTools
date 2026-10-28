import SwiftUI

/// 卡片尺寸（放在非泛型容器里，泛型类型内不能声明存储型静态属性）。
enum CardMetrics {
    static var width: CGFloat { PanelPositioner.contentWidth }
    /// 剪贴板固定高度：保证列表滚动区稳定，切换条目时卡片不跳动。
    static let listHeight: CGFloat = 400
}

/// 功能内容卡片：工具条在卡片之上。
/// 内容占上半部，状态与按键提示收在卡片内部左下角（不再浮在工具条与卡片之间）。
/// 高度有两种模式：给定 `height` 固定（列表类需要稳定滚动区），为 nil 时按内容自适应。
struct ModuleCard<Content: View>: View {
    var height: CGFloat?
    var status: String?
    var hint: String?
    /// 状态为临时提示（如「已复制」）时用强调色，区别于常规状态。
    var alert: Bool = false
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forceSolidSurfaces) private var forceSolid

    var body: some View {
        stack
            .frame(width: CardMetrics.width, height: height, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity((reduceTransparency || forceSolid) ? 1 : 0.94))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
            }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .frame(
                    maxWidth: .infinity,
                    maxHeight: height == nil ? nil : .infinity,
                    alignment: .topLeading
                )
            footer
        }
        .padding(18)
    }

    /// 左下角状态行：`状态 · 按键提示`。
    @ViewBuilder
    private var footer: some View {
        if status != nil || hint != nil {
            HStack(spacing: 6) {
                if let status {
                    Text(status)
                        .foregroundStyle(alert ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                if status != nil, hint != nil {
                    Text("·")
                        .foregroundStyle(.tertiary)
                }
                if let hint {
                    Text(hint).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(Typography.statusHint)
            .lineLimit(1)
            .padding(.top, 12)
        }
    }
}

/// 键帽（提示用）
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.keyCap)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.09))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
    }
}

/// 占位功能视图。
struct PlaceholderModuleView: View {
    let module: ModuleID

    var body: some View {
        ModuleCard(status: module.subtitle) {
            VStack(spacing: 10) {
                Image(systemName: module.symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(module.subtitle)
                    .font(Typography.hint)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
}

/// 截图功能页：截图不经过浮窗，回车即进入选区覆盖层。
struct ScreenshotHintView: View {
    let router: HUDRouter

    var body: some View {
        ModuleCard(status: "支持全局快捷键", hint: "按Esc 返回") {
            VStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.accentColor.opacity(0.8))

                Text("回车开始截图")
                    .font(.system(size: 19, weight: .medium, design: .rounded))

                HStack(spacing: 12) {
                    KeyCap(text: "↩")
                    Text("开始截图").font(Typography.hint).foregroundStyle(.secondary)
                    KeyCap(text: "⌘S")
                    Text("保存本地").font(Typography.hint).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
    }
}
