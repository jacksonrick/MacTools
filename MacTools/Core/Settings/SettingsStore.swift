import Foundation
import Observation

enum MenuBarIconMode: String, Codable, CaseIterable, Sendable {
    case symbol
    case dot
}

/// 唯一状态源：所有设置即时生效、无保存按钮。
/// 全部落在 `settings.sqlite` 的 `kv` 表（与剪贴板同库，不再使用 UserDefaults）。
@Observable
@MainActor
final class SettingsStore {

    enum Key {
        static let maxClips = "clip.maxClips"
        static let displayCount = "clip.displayCount"
        static let maxClipBytes = "clip.maxClipBytes"
        static let keywords = "hud.keywords"
        static let hotkeys = "hud.hotkeys"
        static let launchAtLogin = "general.launchAtLogin"
        static let menuBarIcon = "general.menuBarIcon"
        static let engine = "translation.engine"
        static let targetLanguage = "translation.targetLanguage"
        static let providerTTS = "translation.providerTTS"
        static let screenshotDir = "screenshot.directory"
    }

    static let defaultsRange = (
        maxClips: 100...5000,
        displayCount: 10...100,
        maxClipBytes: 10 * 1024...(1024 * 1024)
    )

    static let defaultKeywords: [ModuleID: [String]] = [
        .clipboard: ["cb", "clip"],
        .screenshot: ["sc", "shot"],
        .translation: ["tr", "fy"],
        .calculator: ["="],
    ]

    static let defaultShortcuts: [HotkeyManager.Action: HotkeyManager.Shortcut] = [
        .toggleHUD: .init(keyCode: 49, modifiers: HotkeyManager.carbonOption),          // ⌥Space
        .screenshot: .init(keyCode: 21, modifiers: HotkeyManager.carbonOption | HotkeyManager.carbonShift),   // ⌥⇧4
        .selectionTranslate: .init(keyCode: 17, modifiers: HotkeyManager.carbonOption), // ⌥T
    ]

    @ObservationIgnored private let database: AppDatabase

    /// 剪贴板存储上限下调后立即触发淘汰。
    @ObservationIgnored var onMaxClipsReduced: ((Int) -> Void)?
    /// 单条最大字节变化（不回溯删除已有数据）。
    @ObservationIgnored var onMaxClipBytesChanged: ((Int) -> Void)?

    var maxClips: Int {
        didSet {
            persist(Key.maxClips) { [database, maxClips] in database.setInt(maxClips, forKey: Key.maxClips) }
            // 回调必须立即：下调上限要马上触发淘汰，攒着写会让用户看到「条数没少」。
            onMaxClipsReduced?(maxClips)
        }
    }

    var displayCount: Int {
        didSet {
            persist(Key.displayCount) { [database, displayCount] in
                database.setInt(displayCount, forKey: Key.displayCount)
            }
        }
    }

    var maxClipBytes: Int {
        didSet {
            persist(Key.maxClipBytes) { [database, maxClipBytes] in
                database.setInt(maxClipBytes, forKey: Key.maxClipBytes)
            }
            onMaxClipBytesChanged?(maxClipBytes)
        }
    }

    var keywords: [ModuleID: [String]] {
        didSet { saveKeywords() }
    }

    var hotkeys: [HotkeyManager.Action: HotkeyManager.Shortcut] {
        didSet { saveHotkeys() }
    }

    var launchAtLogin: Bool {
        didSet {
            persist(Key.launchAtLogin) { [database, launchAtLogin] in
                database.setBool(launchAtLogin, forKey: Key.launchAtLogin)
            }
        }
    }

    var menuBarIconMode: MenuBarIconMode {
        didSet {
            persist(Key.menuBarIcon) { [database, menuBarIconMode] in
                database.setString(menuBarIconMode.rawValue, forKey: Key.menuBarIcon)
            }
        }
    }

    var translationEngine: TranslationEngineID {
        didSet {
            persist(Key.engine) { [database, translationEngine] in
                database.setString(translationEngine.rawValue, forKey: Key.engine)
            }
        }
    }

    var targetLanguage: String {
        didSet {
            persist(Key.targetLanguage) { [database, targetLanguage] in
                database.setString(targetLanguage, forKey: Key.targetLanguage)
            }
        }
    }

    var prefersProviderTTS: Bool {
        didSet {
            persist(Key.providerTTS) { [database, prefersProviderTTS] in
                database.setBool(prefersProviderTTS, forKey: Key.providerTTS)
            }
        }
    }

    var screenshotDirectory: String {
        didSet {
            persist(Key.screenshotDir) { [database, screenshotDirectory] in
                database.setString(screenshotDirectory, forKey: Key.screenshotDir)
            }
        }
    }

    init(database: AppDatabase) {
        self.database = database

        let savedMax = database.int(forKey: Key.maxClips) ?? 500
        maxClips = min(max(savedMax, Self.defaultsRange.maxClips.lowerBound), Self.defaultsRange.maxClips.upperBound)

        let savedDisplay = database.int(forKey: Key.displayCount) ?? 50
        displayCount = min(max(savedDisplay, Self.defaultsRange.displayCount.lowerBound), Self.defaultsRange.displayCount.upperBound)

        let savedBytes = database.int(forKey: Key.maxClipBytes) ?? 100 * 1024
        maxClipBytes = min(max(savedBytes, Self.defaultsRange.maxClipBytes.lowerBound), Self.defaultsRange.maxClipBytes.upperBound)

        keywords = Self.loadKeywords(from: database)
        hotkeys = Self.loadHotkeys(from: database)

        launchAtLogin = database.bool(forKey: Key.launchAtLogin) ?? false
        menuBarIconMode = MenuBarIconMode(rawValue: database.string(forKey: Key.menuBarIcon) ?? "") ?? .symbol
        translationEngine = TranslationEngineID(rawValue: database.string(forKey: Key.engine) ?? "") ?? .baidu
        targetLanguage = database.string(forKey: Key.targetLanguage) ?? "zh-CHS"
        prefersProviderTTS = database.bool(forKey: Key.providerTTS) ?? true
        screenshotDirectory = database.string(forKey: Key.screenshotDir)
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Pictures/Screenshots")
    }

    // MARK: - 派生值

    /// 关键词 → 功能的反向查表（运行时字典查表，变更即时生效）。
    var keywordTable: [String: ModuleID] {
        var table: [String: ModuleID] = [:]
        for module in ModuleID.allCases {
            for keyword in keywords[module] ?? [] where !keyword.isEmpty {
                table[keyword] = module
            }
        }
        return table
    }

    func keywords(for module: ModuleID) -> [String] {
        keywords[module] ?? []
    }

    func setKeywords(_ list: [String], for module: ModuleID) {
        keywords[module] = list
    }

    /// 关键词冲突：返回冲突的 (关键词, 涉及功能) 列表。
    var keywordConflicts: [String] {
        var owners: [String: Set<ModuleID>] = [:]
        for module in ModuleID.allCases {
            for keyword in keywords[module] ?? [] where !keyword.isEmpty {
                owners[keyword, default: []].insert(module)
            }
        }
        return owners.filter { $0.value.count > 1 }.keys.sorted()
    }

    func restoreDefaultKeywords() {
        keywords = Self.defaultKeywords
    }

    // MARK: - 修正入口（UI 不走 setter 直接赋值，避免越界）

    func setMaxClips(_ value: Int) {
        let clamped = min(max(value, Self.defaultsRange.maxClips.lowerBound), Self.defaultsRange.maxClips.upperBound)
        maxClips = clamped
    }

    func setDisplayCount(_ value: Int) {
        let upper = min(Self.defaultsRange.displayCount.upperBound, maxClips)
        displayCount = min(max(value, Self.defaultsRange.displayCount.lowerBound), upper)
    }

    func setMaxClipBytes(_ value: Int) {
        let step = 10 * 1024
        let lower = Self.defaultsRange.maxClipBytes.lowerBound
        let upper = Self.defaultsRange.maxClipBytes.upperBound
        let snapped = (min(max(value, lower), upper) / step) * step
        maxClipBytes = min(max(snapped, lower), upper)
    }

    // MARK: - 持久化

    /// 待落库的写入，按 key 合并。
    @ObservationIgnored private var pendingWrites: [String: @MainActor () -> Void] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// 静默多久后统一提交。
    @ObservationIgnored private static let persistDelay = 200

    /// 合并短时间内的重复写入。
    ///
    /// 设置页三个滑杆都是**连续**回调（拖一次能产生几十上百次 didSet），
    /// 而 `AppDatabase` 的 `setInt` / `setString` 是**同步**提交：一次调用就是一整个
    /// WAL 事务，直接跑在主线程上。拖动时的观感是每帧卡一下、磁盘被反复刷。
    /// 这里按 key 合并，最后一次改动之后静默 200ms 再落库。
    ///
    /// 内存中的值是立即生效的（观察者立刻看到新值），只有落盘被推迟；
    /// 退出前由 `flush()` 兜住，最多丢「退出前 200ms 内的设置改动」。
    private func persist(_ key: String, _ write: @escaping @MainActor () -> Void) {
        pendingWrites[key] = write
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.persistDelay))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 立即把所有待写项落库（退出前 / 需要磁盘快照时调用）。
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingWrites.isEmpty else { return }
        let writes = pendingWrites
        pendingWrites.removeAll()
        for write in writes.values { write() }
    }

    private func saveKeywords() {
        let raw = keywords.reduce(into: [String: [String]]()) { partial, item in
            partial[item.key.rawValue] = item.value
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        persist(Key.keywords) { [database] in database.setData(data, forKey: Key.keywords) }
    }

    private func saveHotkeys() {
        let raw = hotkeys.reduce(into: [String: HotkeyManager.Shortcut]()) { partial, item in
            partial[item.key.rawValue] = item.value
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        persist(Key.hotkeys) { [database] in database.setData(data, forKey: Key.hotkeys) }
    }

    private static func loadKeywords(from database: AppDatabase) -> [ModuleID: [String]] {
        guard let data = database.data(forKey: Key.keywords),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return defaultKeywords
        }
        var result: [ModuleID: [String]] = [:]
        for (key, value) in raw {
            if let module = ModuleID(rawValue: key) {
                result[module] = value
            }
        }
        for module in ModuleID.allCases where result[module] == nil {
            result[module] = defaultKeywords[module]
        }
        return result
    }

    private static func loadHotkeys(from database: AppDatabase) -> [HotkeyManager.Action: HotkeyManager.Shortcut] {
        guard let data = database.data(forKey: Key.hotkeys),
              let raw = try? JSONDecoder().decode([String: HotkeyManager.Shortcut].self, from: data) else {
            return defaultShortcuts
        }
        var result: [HotkeyManager.Action: HotkeyManager.Shortcut] = [:]
        for (key, value) in raw {
            if let action = HotkeyManager.Action(rawValue: key) {
                result[action] = value
            }
        }
        for action in HotkeyManager.Action.allCases where result[action] == nil {
            result[action] = defaultShortcuts[action]
        }
        return result
    }
}
