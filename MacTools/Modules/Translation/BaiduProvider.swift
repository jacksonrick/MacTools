import Foundation

/// 百度翻译：签名 MD5(appid + q + salt + secretKey)。
/// 朗读：翻译请求带 tts=1&tts_speed=5，响应含 tts 音频 URL。
struct BaiduProvider: TranslationProvider {

    let id: TranslationEngineID = .baidu
    let credentials: TranslateCredentials

    private static let endpoint = "https://fanyi-api.baidu.com/api/trans/vip/translate"

    func translate(_ text: String, from: String, to: String) async throws -> TranslationResult {
        guard credentials.isConfigured else { throw TranslationError.notConfigured }

        let salt = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Digest.md5(credentials.appID + text + salt + credentials.secret)
        let fromCode = from.isEmpty ? "auto" : LanguageCatalog.baidu(from)

        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "from", value: fromCode),
            URLQueryItem(name: "to", value: LanguageCatalog.baidu(to)),
            URLQueryItem(name: "appid", value: credentials.appID),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "tts", value: "1"),
            URLQueryItem(name: "tts_speed", value: "5"),
        ]

        guard let url = components?.url else { throw TranslationError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        let payload = try JSONDecoder().decode(Response.self, from: data)

        if let code = payload.errorCode, code != "52000" {
            throw TranslationError.service(Self.message(for: code))
        }
        guard let translated = payload.trans_result?.compactMap({ $0.dst }).joined(), !translated.isEmpty else {
            throw TranslationError.invalidResponse
        }
        return TranslationResult(translatedText: translated, detectedSourceLanguage: payload.from)
    }

    func synthesizeSpeech(_ text: String, language: String) async throws -> URL? {
        guard credentials.isConfigured else { throw TranslationError.notConfigured }

        let salt = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Digest.md5(credentials.appID + text + salt + credentials.secret)
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: LanguageCatalog.baidu(language)),
            URLQueryItem(name: "appid", value: credentials.appID),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "tts", value: "1"),
            URLQueryItem(name: "tts_speed", value: "5"),
        ]
        guard let url = components?.url else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        let payload = try JSONDecoder().decode(Response.self, from: data)
        guard let tts = payload.tts, let remote = URL(string: tts) else { return nil }
        return try await Self.download(remote)
    }

    static func download(_ url: URL) async throws -> URL? {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard !data.isEmpty else { return nil }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactools-tts-\(UUID().uuidString).mp3")
        try data.write(to: target)
        return target
    }

    private struct Response: Decodable {
        let from: String?
        let trans_result: [Item]?
        let tts: String?
        let error_code: String?

        var errorCode: String? { error_code }

        struct Item: Decodable {
            let src: String?
            let dst: String?
        }
    }

    private static func message(for code: String) -> String {
        switch code {
        case "52001": "请求超时"
        case "52003": "APP ID 未授权"
        case "54001": "签名错误，请检查密钥"
        case "54003": "访问频率受限"
        case "54004": "账户余额不足"
        case "58001": "语言方向不支持"
        default: "百度翻译错误 \(code)"
        }
    }
}
