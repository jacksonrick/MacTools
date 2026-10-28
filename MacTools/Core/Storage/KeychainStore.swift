import Foundation
import Security

/// 仅用于**一次性迁移**：读取旧版本存在钥匙串里的翻译凭据。
///
/// 应用运行时不再写钥匙串——凭据统一落在 `settings.sqlite` 的 kv 表
/// （见 `TranslationService` 与 `LegacyImporter`）。迁移完成后钥匙串条目即被删除。
enum KeychainStore {

    private static let service = "dev.mactools.MacTools.translation"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
