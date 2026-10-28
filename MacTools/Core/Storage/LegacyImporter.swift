import Foundation

/// 一次性搬迁：把历史分散存储合并进 `settings.sqlite`。
///
/// 旧版本布局：剪贴板 → `clips.sqlite`；设置 / 计算历史 / 汇率快照 → UserDefaults；
/// 翻译凭据 → Keychain。现在统一为单库，本搬迁器在首次启动时执行：
/// 1. UserDefaults 里已知键 → `kv` 表（保留原始类型）
/// 2. Keychain 里的翻译凭据 → `kv` 表
/// 3. 原始 UserDefaults 内容打一份带类型标签的备份存进 `kv`（`meta.legacyUserDefaultsBackup`）
/// 4. 确认写入成功后清掉旧位置，避免两处并存
@MainActor
enum LegacyImporter {

    static let markerKey = "meta.legacyImported"
    static let backupKey = "meta.legacyUserDefaultsBackup"

    /// UserDefaults 中需要搬迁的键（含计算历史；汇率旧键仅作清理，不再被读取）。
    static var legacyKeys: [String] {
        [
            SettingsStore.Key.maxClips,
            SettingsStore.Key.displayCount,
            SettingsStore.Key.maxClipBytes,
            SettingsStore.Key.keywords,
            SettingsStore.Key.hotkeys,
            SettingsStore.Key.launchAtLogin,
            SettingsStore.Key.menuBarIcon,
            SettingsStore.Key.engine,
            SettingsStore.Key.targetLanguage,
            SettingsStore.Key.providerTTS,
            SettingsStore.Key.screenshotDir,
            "calc.currencySource",
            "calc.history",
            "calc.currencySnapshot",
        ]
    }

    static func run(on database: AppDatabase, defaults: UserDefaults = .standard) {
        guard !database.containsKey(markerKey) else { return }

        migrateDefaults(on: database, defaults: defaults)
        migrateKeychain(on: database)

        database.setBool(true, forKey: markerKey)
    }

    // MARK: - UserDefaults

    private static func migrateDefaults(on database: AppDatabase, defaults: UserDefaults) {
        var backup: [String: String] = [:]
        var migrated: [String] = []

        for key in legacyKeys {
            guard let object = defaults.object(forKey: key) else { continue }

            if let number = object as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    database.setBool(number.boolValue, forKey: key)
                    backup[key] = "bool:\(number.boolValue ? 1 : 0)"
                } else {
                    database.setInt(number.intValue, forKey: key)
                    backup[key] = "int:\(number.intValue)"
                }
            } else if let data = object as? Data {
                database.setData(data, forKey: key)
                backup[key] = "data:\(data.base64EncodedString())"
            } else if let string = object as? String {
                database.setString(string, forKey: key)
                backup[key] = "string:\(string)"
            } else {
                continue
            }

            // 写成功才删旧值，避免中途失败丢数据
            if database.containsKey(key) {
                migrated.append(key)
            }
        }

        if let backupData = try? JSONEncoder().encode(backup), !backup.isEmpty {
            database.setData(backupData, forKey: backupKey)
        }

        for key in migrated {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Keychain

    private static func migrateKeychain(on database: AppDatabase) {
        for engine in TranslationEngineID.allCases {
            let account = "translation.\(engine.rawValue)"
            guard let raw = KeychainStore.read(account: account) else { continue }
            database.setData(Data(raw.utf8), forKey: TranslationService.credentialsKey(for: engine))
            guard database.containsKey(TranslationService.credentialsKey(for: engine)) else { continue }
            KeychainStore.delete(account: account)
        }
    }
}
