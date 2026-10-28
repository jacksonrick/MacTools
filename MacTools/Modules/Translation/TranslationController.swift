import Foundation
import NaturalLanguage
import Observation

@Observable
@MainActor
final class TranslationController: ModuleControlling {

    let moduleID: ModuleID = .translation

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
    private var translateTask: Task<Void, Never>?

    init(service: TranslationService, settings: SettingsStore) {
        self.service = service
        self.settings = settings
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
        errorMessage = nil
    }

    func didLeave(router: HUDRouter) {
        translateTask?.cancel()
        service.speechService.stop()
        speakingTarget = nil
    }

    func didChangeText(_ text: String, router: HUDRouter) {
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
        case .enter:
            translate(router: router)
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
        router.flashStatus("目标语言：\(LanguageCatalog.name(for: next))")
    }

    func swapEngine(_ engine: TranslationEngineID) {
        service.activeEngine = engine
    }
}
