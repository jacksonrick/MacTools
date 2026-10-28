import SwiftUI

/// 截图选区下方的就地工具条（微信 / 钉钉式）。
/// 深色实体底色而不是玻璃：它压在冻结的截图上，玻璃会把底图透出来导致图标糊在一起。
struct ScreenshotToolbar: View {
    @Bindable var model: AnnotationModel
    /// 工具激活 / 选中项变化（外层据此切换「调整选区」手势层并重排工具条宽度）
    var onToolChange: (() -> Void)?
    let onCopy: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(AnnotationTool.allCases) { tool in
                toolButton(tool)
            }

            separator

            HStack(spacing: 5) {
                ForEach(Array(model.colors.enumerated()), id: \.offset) { index, color in
                    colorDot(index: index, color: color)
                }
            }

            // 颜色右侧：文字大小（小 / 中 / 大）
            sizePicker

            separator

            iconButton("arrow.uturn.backward", id: "undo", help: "撤销 ⌘Z") {
                model.undo()
                onToolChange?()
            }

            // 一直占位，宽度才不会随着选中与否跳动
            iconButton("trash", id: "trash", help: "删除所选元素 ⌫", enabled: model.hasSelection) {
                model.deleteSelection()
                onToolChange?()
            }

            separator

            iconButton("xmark", id: "cancel", help: "取消 Esc") {
                onCancel()
            }

            iconButton("square.and.arrow.down", id: "save", help: "保存到文件 ⌘S") {
                onSave()
            }

            copyButton
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        // 整条都可命中：否则点到按钮之间的空隙会漏到下面的覆盖层，把截图状态弄丢。
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .fixedSize()
    }

    // MARK: 工具

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let active = model.tool == tool
        return Button {
            // 再次点击已激活的图标 = 取消激活（此时回到拖动 / 调整选区模式）
            model.tool = active ? nil : tool
            if model.tool == nil { model.clearSelection() }
            onToolChange?()
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? Color.black.opacity(0.85) : Color.white.opacity(0.92))
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background(active: active, hovered: hovered == tool.id))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = tool.id } else if hovered == tool.id { hovered = nil }
        }
        .help("\(tool.title)（\(tool.key.uppercased())）")
    }

    private func colorDot(index: Int, color: Color) -> some View {
        let selected = model.colorIndex == index
        return Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay {
                Circle().strokeBorder(
                    .white.opacity(selected ? 0.95 : 0.22),
                    lineWidth: selected ? 2 : 1
                )
            }
            .padding(3)
            .background {
                Circle()
                    .fill(.white.opacity(hovered == "color\(index)" ? 0.14 : 0.001))
            }
            .contentShape(Circle())
            .onHover { inside in
                if inside { hovered = "color\(index)" } else if hovered == "color\(index)" { hovered = nil }
            }
            .onTapGesture { model.applyColor(index) }
    }

    // MARK: 文字大小

    private var sizePicker: some View {
        let enabled = model.isTextContext
        return HStack(spacing: 1) {
            ForEach(TextSizeTier.allCases) { tier in
                let active = model.textTier == tier
                Button {
                    model.applyTextSize(tier)
                } label: {
                    Text(tier.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(enabled
                                         ? (active ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                                         : Color.white.opacity(0.35))
                        .frame(width: 20, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(enabled && active ? Color.white.opacity(0.92) : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("文字大小：\(tier.title)")
            }
        }
        .padding(1)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white.opacity(enabled ? 0.10 : 0.05))
        }
        .disabled(!enabled)
        .help("先选文字工具或选中一段文字，再调字号")
    }

    private func background(active: Bool, hovered: Bool) -> Color {
        if active { return Color.white.opacity(0.92) }
        if hovered { return Color.white.opacity(0.14) }
        return Color.white.opacity(0.001)
    }

    // MARK: 动作按钮

    private func iconButton(
        _ symbol: String,
        id: String,
        help: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hovered == id && enabled
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? (isHovered ? 1 : 0.86) : 0.3))
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(isHovered ? 0.16 : 0.001))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .help(help)
    }

    private var copyButton: some View {
        let isHovered = hovered == "copy"
        return Button(action: onCopy) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: isHovered ? .heavy : .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 24)
                .background {
                    Circle().fill(Color.accentColor.opacity(isHovered ? 1 : 0.92))
                }
                .overlay {
                    if isHovered {
                        Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = "copy" } else if hovered == "copy" { hovered = nil }
        }
        .help("复制到剪贴板 ↩")
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.16))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }
}
