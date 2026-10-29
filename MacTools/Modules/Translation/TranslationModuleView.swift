import SwiftUI

struct TranslationModuleView: View {
    let controller: TranslationController
    let router: HUDRouter

    /// 原文块 + 译文块的高度是固定的：既保证译文滚动区稳定，又不会像以前那样撑到 540。
    private static let cardHeight: CGFloat = 330

    var body: some View {
        ModuleCard(
            height: Self.cardHeight,
            status: cardStatus,
            hint: cardHint,
            alert: router.statusMessage != nil
        ) {
            if controller.mode == .history {
                historyList
            } else {
                VStack(spacing: 10) {
                    sourceBlock
                    translatedBlock
                }
            }
        }
    }

    private var cardStatus: String {
        if let message = router.statusMessage { return message }
        if controller.mode == .history { return "翻译历史 · 最多 \(TranslationHistory.limit) 条" }
        if controller.isTranslating { return "翻译中…" }
        if let error = controller.errorMessage { return error }
        if !controller.isConfigured { return "未配置翻译引擎" }
        if let detected = controller.detectedLanguage { return "已翻译 · 识别为 \(detected)" }
        return "\(controller.activeEngine.displayName) → \(LanguageCatalog.name(for: controller.targetLanguage))"
    }

    private var cardHint: String {
        if controller.mode == .history { return "↩ 键入译文 · ↑↓ 选择 · Esc 退出历史" }
        if controller.canReadTranslation { return "↩ 键入译文 · ↓ 历史 · ⌘L 切换语言" }
        return "↩ 翻译 · ↓ 历史 · ⌘L 切换语言 · Esc 返回"
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
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func historyRow(record: TranslationRecord, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.source)
                .font(Typography.listRow)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(record.translated)
                .font(Typography.listMeta)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03))
        }
    }

    // MARK: 原文

    private var sourceBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockHeader(title: "原文") {
                speakButton(
                    target: .source,
                    enabled: !router.translationSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    help: "朗读原文"
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if router.translationSource.isEmpty {
                    Text("输入原文，或选中文本后按快捷键")
                        .font(Typography.expression)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(router.translationSource)
                        .font(Typography.expression)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .solidSurface(cornerRadius: 12)
    }

    // MARK: 译文

    private var translatedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockHeader(title: "译文") {
                speakButton(
                    target: .translation,
                    enabled: controller.canReadTranslation,
                    help: "朗读译文"
                )
            }

            ScrollView {
                Text(translatedContent)
                    .font(Typography.expression)
                    .foregroundStyle(controller.errorMessage == nil ? Color.primary : Color.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .solidSurface(cornerRadius: 12)
    }

    private var translatedContent: String {
        if let error = controller.errorMessage { return error }
        if controller.isTranslating { return "…" }
        if controller.translatedText.isEmpty {
            if !controller.isConfigured {
                return "尚未配置 \(controller.activeEngine.displayName) 密钥，去「设置 → 翻译」填入 APP ID 与密钥后即可翻译。"
            }
            return "按 ↩ 开始翻译"
        }
        return controller.translatedText
    }

    // MARK: 块头 + 朗读按钮

    private func blockHeader<Accessory: View>(
        title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Typography.statusHint)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            accessory()
        }
    }

    private func speakButton(
        target: TranslationController.SpeechTarget,
        enabled: Bool,
        help: String
    ) -> some View {
        let speaking = controller.isSpeaking(target)
        return Button {
            controller.toggleSpeech(target, router: router)
        } label: {
            Image(systemName: speaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(speaking ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}
