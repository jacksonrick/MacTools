import Foundation

/// 有道智云 v3：SHA256(appKey + truncate(q) + salt + curtime + appSecret)。
/// 朗读：ttsapi，签名 MD5(appKey + q + salt + appSecret)。
struct YoudaoProvider: TranslationProvider {

    let id: TranslationEngineID = .youdao
    let credentials: TranslateCredentials

    private static let endpoint = "https://openapi.youdao.com/api"
    private static let ttsEndpoint = "https://openapi.youdao.com/ttsapi"

    func translate(_ text: String, from: String, to: String) async throws -> TranslationResult {
        guard credentials.isConfigured else { throw TranslationError.notConfigured }

        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let sign = Digest.sha256(credentials.appID + Self.truncate(text) + salt + curtime + credentials.secret)

        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let fromCode = from.isEmpty ? "auto" : LanguageCatalog.youdao(from)
        let body: [String: String] = [
            "q": text,
            "from": fromCode,
            "to": LanguageCatalog.youdao(to),
            "appKey": credentials.appID,
            "salt": salt,
            "sign": sign,
            "signType": "v3",
            "curtime": curtime,
        ]
        request.httpBody = Self.formEncode(body).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let payload = try JSONDecoder().decode(Response.self, from: data)

        guard payload.errorCode == "0" else {
            throw TranslationError.service(Self.message(for: payload.errorCode))
        }
        guard let translated = payload.translation?.joined(), !translated.isEmpty else {
            throw TranslationError.invalidResponse
        }
        let detected = payload.l?.components(separatedBy: "2").first
        return TranslationResult(translatedText: translated, detectedSourceLanguage: detected)
    }

    func synthesizeSpeech(_ text: String, language: String) async throws -> URL? {
        guard credentials.isConfigured else { throw TranslationError.notConfigured }

        let salt = UUID().uuidString
        let sign = Digest.md5(credentials.appID + text + salt + credentials.secret)
        var request = URLRequest(url: URL(string: Self.ttsEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "q": text,
            "langType": LanguageCatalog.youdao(language),
            "appKey": credentials.appID,
            "salt": salt,
            "sign": sign,
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           contentType.contains("audio") {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("mactools-tts-\(UUID().uuidString).mp3")
            try data.write(to: target)
            return target
        }
        return nil
    }

    private static func truncate(_ text: String) -> String {
        let characters = Array(text)
        if characters.count <= 20 { return text }
        let head = String(characters.prefix(10))
        let tail = String(characters.suffix(10))
        return head + String(characters.count) + tail
    }

    private static func formEncode(_ parameters: [String: String]) -> String {
        parameters
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    private struct Response: Decodable {
        let errorCode: String
        let translation: [String]?
        let l: String?

        enum CodingKeys: String, CodingKey {
            case errorCode
            case translation
            case l
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .errorCode) {
                errorCode = text
            } else if let number = try? container.decode(Int.self, forKey: .errorCode) {
                errorCode = String(number)
            } else {
                errorCode = "0"
            }
            translation = try? container.decode([String].self, forKey: .translation)
            l = try? container.decode(String.self, forKey: .l)
        }
    }

    private static func message(for code: String) -> String {
        switch code {
        case "108": "应用 ID 无效"
        case "110": "无相关服务权限"
        case "202": "签名校验失败"
        case "203": "翻译文本过长"
        case "401": "账户余额不足"
        case "411": "访问频率受限"
        case "113": "查询为空"
        default: "有道翻译错误 \(code)"
        }
    }
}
