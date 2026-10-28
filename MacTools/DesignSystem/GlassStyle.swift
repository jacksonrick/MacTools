import SwiftUI

/// 强制实体材质（等价于 Reduce Transparency）。
/// 用于离屏渲染检查版式：Liquid Glass 无法在无窗口合成的环境里绘制。
private struct ForceSolidSurfacesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var forceSolidSurfaces: Bool {
        get { self[ForceSolidSurfacesKey.self] }
        set { self[ForceSolidSurfacesKey.self] = newValue }
    }
}

/// Liquid Glass 封装 + 可访问性降级（Reduce Transparency）。
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forceSolidSurfaces) private var forceSolid

    func body(content: Content) -> some View {
        if reduceTransparency || forceSolid {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
        } else if let tint {
            content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// 非玻璃但仍需背景的容器（列表行、文本块），保持与玻璃视觉同一套圆角语义。
struct SolidSurface: ViewModifier {    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

/// 圆形玻璃（工具条上的功能按钮）。激活态由调用方自绘，不叠玻璃。
struct CircleGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forceSolidSurfaces) private var forceSolid

    func body(content: Content) -> some View {
        if reduceTransparency || forceSolid {
            content
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1) }
        } else {
            content
                .background(Circle().fill(Color.white.opacity(0.02)))
                .glassEffect(.regular, in: .circle)
        }
    }
}

extension View {
    /// 允许使用玻璃的控件（状态行、工具条、HUD 外框）。
    func controlGlass(cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, tint: nil))
    }

    func controlGlass(cornerRadius: CGFloat = 22, tint: Color?) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, tint: tint))
    }

    /// 圆形玻璃按钮底板。
    func circleGlass() -> some View {
        modifier(CircleGlass())
    }

    /// 禁止使用玻璃的内容容器（列表行、预览区、文本块）。
    func solidSurface(cornerRadius: CGFloat = 10) -> some View {
        modifier(SolidSurface(cornerRadius: cornerRadius))
    }
}
