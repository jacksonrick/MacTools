import SwiftUI

struct CalculatorModuleView: View {
    let controller: CalculatorController
    let router: HUDRouter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 计算器卡片按内容高度自适应：表达式在工具条里，卡片只放结果与辅助信息。
        ModuleCard(status: cardStatus, hint: cardHint, alert: router.statusMessage != nil) {
            if controller.mode == .history {
                historyList
                    .transition(.opacity)
            } else {
                editor
                    .transition(.opacity)
            }
        }
        .animation(Motion.resolve(Motion.settingSwitch, reduceMotion: reduceMotion), value: controller.mode)
    }

    private var cardStatus: String {
        if let message = router.statusMessage { return message }
        if controller.mode == .history { return "计算历史 · 最多 10 条" }
        return "实时求值 · 支持单位换算"
    }

    private var cardHint: String {
        controller.mode == .history ? "↩ 回填 · Esc 退出历史" : "↩ 复制并关闭 · ↑ 显示历史"
    }

    // MARK: 编辑

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 结果居中展示，上下留出呼吸间距，取代原来靠 Spacer 撑满的大片空白。
            Group {
                if let result = controller.result {
                    Text(result.value)
                        .font(Typography.resultValue)
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)
                } else if let reason = controller.unsupportedReason {
                    Text(reason)
                        .font(Typography.resultValueSmall)
                        .foregroundStyle(.secondary)
                } else {
                    Text(router.calcExpression.isEmpty ? "输入表达式" : "无法求值")
                        .font(Typography.resultValueSmall)
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 22)

            if !controller.history.records.isEmpty {
                divider
                recentList
                    .padding(.vertical, 12)
            }

            divider
            examples
                .padding(.top, 12)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }

    /// 最近计算（只读概览，↑ 进入完整历史）。
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近")
                .font(Typography.statusHint)
                .foregroundStyle(.tertiary)

            ForEach(Array(controller.history.records.prefix(3))) { record in
                HStack(spacing: 10) {
                    Text(record.expression)
                        .font(Typography.listRow)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("=")
                        .font(Typography.listMeta)
                        .foregroundStyle(.tertiary)
                    Text(record.result)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("支持：四则 · 括号 · 百分比 · 变量 · 单位换算")
                .font(Typography.hint)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                ForEach(["23*4", "15% of 200", "1.5m to ft", "x = 12", "(3+5)*2"], id: \.self) { sample in
                    Text(sample)
                        .font(Typography.chipLabel)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .solidSurface(cornerRadius: 6)
                }
            }
        }
    }

    // MARK: 历史

    private var historyList: some View {
        Group {
            if controller.history.records.isEmpty {
                Text("暂无历史")
                    .font(Typography.hint)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(controller.history.records.enumerated()), id: \.element.id) { index, record in
                            historyRow(record: record, selected: index == controller.historyIndex)
                        }
                    }
                }
                .frame(height: 200)
            }
        }
    }

    private func historyRow(record: CalculationRecord, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(record.expression)
                .font(Typography.listRow)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(record.result)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03))
        }
    }
}

/// 隐形输入框没有可见光标，这里补一个。
struct BlinkingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.forceSolidSurfaces) private var forceSolid
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 2, height: 20)
            .opacity(visible || forceSolid ? 1 : 0)
            .onAppear {
                guard !reduceMotion, !forceSolid else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}
