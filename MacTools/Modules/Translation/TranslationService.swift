import Foundation
import Observation
import AVFoundation

enum EngineVerification: Equatable {
    case unconfigured
    case verified
    case failed(String)

    var label: String {
        switch self {
        case .unconfigured: "未配置"
        case .verified: "已验证"
        case .failed(let message): message
        }
    }
}

/// 翻译能力装配：凭证（`settings.sqlite` 的 kv 表）+ Provider + 选定引擎。
@Observable
@MainActor
final class TranslationService {

    private(set) var credentials: [TranslationEngineID: TranslateCredentials] = [:]
    private(set) var verification: [TranslationEngineID: EngineVerification] = [:]

    var activeEngine: TranslationEngineID {
        didSet { engineDidChange?(activeEngine) }
    }

    @ObservationIgnored var engineDidChange: ((TranslationEngineID) -> Void)?

    private let speech = SpeechService()
    private let database: AppDatabase

    init(database: AppDatabase, activeEngine: TranslationEngineID) {
        self.database = database
        self.activeEngine = activeEngine
        for engine in TranslationEngineID.allCases {
            let loaded = Self.load(engine: engine, from: database)
            credentials[engine] = loaded
            verification[engine] = .unconfigured
        }
    }

    var speechService: SpeechService { speech }

    var isConfigured: Bool {
        credentials[activeEngine]?.isConfigured == true
    }

    func credentials(for engine: TranslationEngineID) -> TranslateCredentials {
        credentials[engine] ?? TranslateCredentials()
    }

    func verificationStatus(for engine: TranslationEngineID) -> EngineVerification {
        verification[engine] ?? .unconfigured
    }

    func save(credentials newValue: TranslateCredentials, for engine: TranslationEngineID) {
        credentials[engine] = newValue
        persist(newValue, engine: engine)
        verification[engine] = .unconfigured
    }

    func provider(for engine: TranslationEngineID) -> (any TranslationProvider)? {
        let config = credentials(for: engine)
        guard config.isConfigured else { return nil }
        switch engine {
        case .baidu: return BaiduProvider(credentials: config)
        case .youdao: return YoudaoProvider(credentials: config)
        }
    }

    func translate(_ text: String, from: String = "auto", to: String) async throws -> TranslationResult {
        guard let provider = provider(for: activeEngine) else { throw TranslationError.notConfigured }
        return try await provider.translate(text, from: from, to: to)
    }

    /// 测试连接：用短文本验证凭证。
    func verify(_ engine: TranslationEngineID) async -> EngineVerification {
        let config = credentials(for: engine)
        guard config.isConfigured else {
            verification[engine] = .unconfigured
            return .unconfigured
        }

        let provider: any TranslationProvider = engine == .baidu
            ? BaiduProvider(credentials: config)
            : YoudaoProvider(credentials: config)

        do {
            _ = try await provider.translate("hello", from: "en", to: engine == .baidu ? "zh" : "zh-CHS")
            verification[engine] = .verified
            // 最后验证成功的作为默认引擎
            activeEngine = engine
            return .verified
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "连接失败"
            verification[engine] = .failed(message)
            return .failed(message)
        }
    }

    // MARK: 凭证持久化（settings.sqlite）

    static func credentialsKey(for engine: TranslationEngineID) -> String {
        "translation.credentials.\(engine.rawValue)"
    }

    private static func load(engine: TranslationEngineID, from database: AppDatabase) -> TranslateCredentials {
        guard let data = database.data(forKey: credentialsKey(for: engine)),
              let decoded = try? JSONDecoder().decode(TranslateCredentials.self, from: data) else {
            return TranslateCredentials()
        }
        return decoded
    }

    private func persist(_ credentials: TranslateCredentials, engine: TranslationEngineID) {
        guard credentials.isConfigured else {
            database.removeValue(forKey: Self.credentialsKey(for: engine))
            return
        }
        database.setData(try? JSONEncoder().encode(credentials), forKey: Self.credentialsKey(for: engine))
    }
}

/// TTS：优先 Provider 音频，失败降级系统合成。
@Observable
@MainActor
final class SpeechService {

    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegateProxy: SpeechDelegateProxy?

    init() {
        let proxy = SpeechDelegateProxy()
        proxy.onFinish = { [weak self] in
            self?.isSpeaking = false
        }
        synthesizer.delegate = proxy
        delegateProxy = proxy
    }

    func speakLocally(_ text: String, language: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.systemLanguageCode(language))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func play(fileURL: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.prepareToPlay()
            player.play()
            self.player = player
            isSpeaking = true
            Task { @MainActor [weak self] in
                let duration = player.duration
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 120))
                if self?.player === player {
                    self?.isSpeaking = false
                    self?.player = nil
                }
            }
        } catch {
            isSpeaking = false
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        player?.stop()
        player = nil
        isSpeaking = false
    }

    static func systemLanguageCode(_ code: String) -> String {
        switch code {
        case "zh-CHS", "zh": "zh-CN"
        case "zh-CHT": "zh-TW"
        case "en": "en-US"
        case "ja": "ja-JP"
        case "ko": "ko-KR"
        case "fr": "fr-FR"
        case "de": "de-DE"
        default: Locale.current.identifier
        }
    }
}

private final class SpeechDelegateProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: (@MainActor () -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in onFinish?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in onFinish?() }
    }
}
