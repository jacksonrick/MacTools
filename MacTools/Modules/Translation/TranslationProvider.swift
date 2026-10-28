import Foundation

enum TranslationEngineID: String, Codable, CaseIterable, Sendable {
    case baidu
    case youdao

    var displayName: String {
        switch self {
        case .baidu: "百度"
        case .youdao: "有道"
        }
    }
}

struct TranslationResult: Sendable {
    let translatedText: String
    let detectedSourceLanguage: String?
}

enum TranslationError: LocalizedError {
    case notConfigured
    case invalidResponse
    case service(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "未配置密钥"
        case .invalidResponse: "响应解析失败"
        case .service(let message): message
        case .network(let message): message
        }
    }
}

protocol TranslationProvider: Sendable {
    var id: TranslationEngineID { get }
    func translate(_ text: String, from: String, to: String) async throws -> TranslationResult
    func synthesizeSpeech(_ text: String, language: String) async throws -> URL?
}
