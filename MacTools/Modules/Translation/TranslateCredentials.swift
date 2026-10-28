import Foundation
import CryptoKit

struct TranslateCredentials: Codable, Equatable, Sendable {
    var appID: String = ""
    var secret: String = ""

    var isConfigured: Bool {
        !appID.trimmingCharacters(in: .whitespaces).isEmpty
            && !secret.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum LanguageCatalog {
    struct Option: Identifiable, Sendable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let options: [Option] = [
        .init(code: "zh-CHS", name: "中文"),
        .init(code: "en", name: "English"),
        .init(code: "ja", name: "日本語"),
        .init(code: "ko", name: "한국어"),
    ]

    static func name(for code: String) -> String {
        options.first { $0.code == code }?.name ?? code
    }

    static func next(after code: String) -> String {
        guard let index = options.firstIndex(where: { $0.code == code }) else {
            return options[0].code
        }
        return options[(index + 1) % options.count].code
    }

    /// 百度语言代码
    static func baidu(_ code: String) -> String {
        switch code {
        case "zh-CHS", "zh-CHT": "zh"
        case "ja": "jp"
        case "ko": "kor"
        case "auto": "auto"
        default: code
        }
    }

    /// 有道语言代码
    static func youdao(_ code: String) -> String {
        switch code {
        case "zh-CHS": "zh-CHS"
        case "zh-CHT": "zh-CHT"
        default: code
        }
    }
}

enum Digest {
    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
