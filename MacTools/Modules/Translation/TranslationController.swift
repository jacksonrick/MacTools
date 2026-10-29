import Foundation
import NaturalLanguage
import Observation

@Observable
@MainActor
final class TranslationController: ModuleControlling {

    enum Mode: Equatable {
        case editing
        case history
    }

    let moduleID: ModuleID = .translation

    private(set) var mode: Mode = .editing
    /// 历史游标：0 = 最新一条，数值越大越旧。
    private(set) var historyIndex: Int = 0

    private(set) var translatedText: String = ""
    private(set) var detectedLanguage: String?
    private(set) var isTranslating = false
    private(set) var errorMessage: String?
    /// 当前在朗读哪一块（原文 / 译文）。朗读按钮据此显示「停止」态。
    private(set) var speakingTarget: SpeechTarget?

    /// 朗读对象：原文用系统语音（源语言不一定受 Provider TTS 支持），译文沿用原链路。
    enum SpeechTarget {
        case source
        case translation
    }

    private let service: TranslationService
    private let settings: SettingsStore
    let history: TranslationHistory
    private var translateTask: Task<Void, Never>?

    init(service: TranslationService, settings: SettingsStore, history: TranslationHistory) {
        self.service = service
        self.settings = settings
        self.history = history
    }

    var activeEngine: TranslationEngineID { service.activeEngine }
    var isSpeaking: Bool { service.speechService.isSpeaking }
    var targetLanguage: String { settings.targetLanguage }
    var isConfigured: Bool { service.isConfigured }
    var speechService: SpeechService { service.speechService }

    func isSpeaking(_ target: SpeechTarget) -> Bool {
        service.speechService.isSpeaking && speakingTarget == target
    }

    /// 译文可读（非空）
    var canReadTranslation: Bool { !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - ModuleControlling

    func didEnter(router: HUDRouter) {
        mode = .editing
        historyIndex = 0
        errorMessage = nil
    }

    func didLeave(router: HUDRouter) {
        mode = .editing
        translateTask?.cancel()
        service.speechService.stop()
        speakingTarget = nil
    }

    func didChangeText(_ text: String, router: HUDRouter) {
        // 打字即回到编辑态：历史只是查看层，不该挡住继续输入。
        mode = .editing
        historyIndex = 0
        errorMessage = nil
        if service.speechService.isSpeaking {
            service.speechService.stop()
            speakingTarget = nil
        }
        if !translatedText.isEmpty {
            translatedText = ""
            detectedLanguage = nil
        }
    }

    func handle(_ key: HUDKey, router: HUDRouter) -> Bool {
        switch key {
        case .arrowDown:
            if mode == .editing {
                guard !history.records.isEmpty else { return true }
                mode = .history
                historyIndex = 0
                return true
            }
            // 列表自上而下是「新 → 旧」，所以「往下按」= 高亮往下走 = 翻到更旧的一条；
            // 翻到底停住，不回绕。
            historyIndex = min(historyIndex + 1, max(history.records.count - 1, 0))
            return true

        case .arrowUp:
            guard mode == .history else { return true }
            // 高亮已经在最上面（最新一条）时再往上按 = 退出历史，回到输入框。
            if historyIndex == 0 {
                mode = .editing
                return true
            }
            historyIndex -= 1
            return true

        case .enter:
            if mode == .history {
                guard history.records.indices.contains(historyIndex) else { return true }
                let record = history.records[historyIndex]
                mode = .editing
                historyIndex = 0
                // 历史里回车 = 直接把那条译文打进光标处，不回填输入框。
                PasteService.paste(record.translated, router: router)
                return true
            }
            if canReadTranslation {
                // 已有译文：回车 = 把译文送进当前光标处（与剪贴板回车同一套动作）。
                PasteService.paste(translatedText, router: router)
            } else {
                translate(router: router)
            }
            return true

        case .command(let character):
            switch character {
            case "l":
                cycleLanguage(router: router)
                return true
            default:
                return false
            }

        case .escape:
            if mode == .history {
                mode = .editing
                historyIndex = 0
                return true
            }
            return false

        default:
            return false
        }
    }

    // MARK: - 动作

    func translate(router: HUDRouter) {
        let source = router.translationSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            errorMessage = "原文为空"
            return
        }
        guard service.isConfigured else {
            errorMessage = "未配置\(service.activeEngine.displayName)密钥（设置 → 翻译）"
            return
        }

        translateTask?.cancel()
        isTranslating = true
        errorMessage = nil
        let target = settings.targetLanguage

        translateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await service.translate(source, from: "auto", to: target)
                guard !Task.isCancelled else { return }
                translatedText = result.translatedText
                detectedLanguage = result.detectedSourceLanguage
                isTranslating = false
                history.add(source: source, translated: result.translatedText, targetLanguage: target)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "翻译失败"
                isTranslating = false
            }
        }
    }

    /// 点按钮朗读：同一块再点一次 = 停止。
    /// 原文走系统语音（源语言未知时先识别），译文沿用「Provider TTS → 系统合成」降级链。
    func toggleSpeech(_ target: SpeechTarget, router: HUDRouter) {
        let speech = service.speechService
        if speech.isSpeaking, speakingTarget == target {
            speech.stop()
            speakingTarget = nil
            return
        }
        speech.stop()
        speakingTarget = nil

        switch target {
        case .source:
            let text = router.translationSource
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            speakingTarget = .source
            speech.speakLocally(text, language: Self.detectLanguageCode(in: text))

        case .translation:
            guard canReadTranslation else { return }
            speakingTarget = .translation
            speakTranslated(translatedText)
        }
    }

    private func speakTranslated(_ text: String) {
        let speech = service.speechService
        let language = settings.targetLanguage

        guard settings.prefersProviderTTS,
              let provider = service.provider(for: service.activeEngine) else {
            speech.speakLocally(text, language: language)
            return
        }

        Task { @MainActor [weak self] in
            if let url = try? await provider.synthesizeSpeech(text, language: language) {
                guard self?.speakingTarget == .translation else { return }
                speech.play(fileURL: url)
            } else {
                // Provider TTS 失败降级系统合成
                guard self?.speakingTarget == .translation else { return }
                speech.speakLocally(text, language: language)
            }
        }
    }

    /// 源语言是 "auto" 时用系统识别器挑一个发音；识别不出就跟随目标语言。
    static func detectLanguageCode(in text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage {
            switch dominant {
            case .simplifiedChinese, .traditionalChinese: return "zh"
            case .english: return "en"
            case .japanese: return "ja"
            case .korean: return "ko"
            case .french: return "fr"
            case .german: return "de"
            default: return dominant.rawValue
            }
        }
        return "en"
    }

    func cycleLanguage(router: HUDRouter) {
        let next = LanguageCatalog.next(after: settings.targetLanguage)
        settings.targetLanguage = next
        // 目标语言变了，旧译文就不能再用了：清掉，让下一次回车重新翻译而不是把旧语言的
        // 结果打进光标处。
        translatedText = ""
        detectedLanguage = nil
        router.flashStatus("目标语言：\(LanguageCatalog.name(for: next))")
    }

    func swapEngine(_ engine: TranslationEngineID) {
        service.activeEngine = engine
    }
}
