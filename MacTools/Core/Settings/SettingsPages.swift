import SwiftUI
import AppKit
import ServiceManagement

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case clipboard
    case translation
    case keywords
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .clipboard: "剪贴板"
        case .translation: "翻译"
        case .keywords: "指令"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .clipboard: "doc.on.clipboard"
        case .translation: "character.bubble"
        case .keywords: "text.cursor"
        case .about: "info.circle"
        }
    }
}

struct SettingsRootView: View {
    let environment: AppEnvironment
    @State private var selection: SettingsPage
    @State private var hovered: SettingsPage?

    init(environment: AppEnvironment, page: SettingsPage = .general) {
        self.environment = environment
        _selection = State(initialValue: page)
    }

    var body: some View {
        // 固定左右布局：左侧自绘导航，右侧内容区。不用 NavigationSplitView，
        // 避免它自动挂载工具栏（那条半透明长块会盖住第一项设置），也避免侧栏可折叠。
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                sidebarRow(page)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 156, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        let isSelected = page == selection
        let isHovered = hovered == page

        return Button {
            guard !isSelected else { return }
            selection = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18, alignment: .center)
                Text(page.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.82))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fillColor(selected: isSelected, hovered: isHovered))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = page
            } else if hovered == page {
                hovered = nil
            }
        }
    }

    private func fillColor(selected: Bool, hovered: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.18) }
        if hovered { return Color.primary.opacity(0.06) }
        return .clear
    }

    // MARK: 内容区

    private var detail: some View {
        ZStack {
            pageView(selection)
                .id(selection)
                .transition(.opacity.combined(with: .offset(y: 4)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.settingSwitch, value: selection)
    }

    @ViewBuilder
    private func pageView(_ page: SettingsPage) -> some View {
        switch page {
        case .general:
            GeneralSettingsView(environment: environment)
        case .clipboard:
            ClipboardSettingsView(environment: environment)
        case .translation:
            TranslationSettingsView(environment: environment)
        case .keywords:
            KeywordsSettingsView(environment: environment)
        case .about:
            AboutSettingsView()
        }
    }
}

// MARK: - 通用

struct GeneralSettingsView: View {
    let environment: AppEnvironment
    @State private var launchError: String?

    private var settings: SettingsStore { environment.settings }

    var body: some View {
        Form {
            Section("通用") {
                Picker("默认展示", selection: defaultModuleBinding) {
                    Text("仅工具条").tag(ModuleID?.none)
                    ForEach(SettingsStore.defaultModuleOptions, id: \.self) { module in
                        Text(module.title).tag(ModuleID?.some(module))
                    }
                }
                Text("按 ⌥Space 唤起时直接停在选中的功能上，省掉一次 Tab。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("登录时启动", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        if let message = LaunchAtLogin.set(newValue) {
                            launchError = message
                            settings.launchAtLogin = LaunchAtLogin.isEnabled
                        } else {
                            launchError = nil
                            settings.launchAtLogin = newValue
                        }
                    }
                ))
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("快捷键") {
                ForEach(HotkeyManager.Action.allCases, id: \.self) { action in
                    HStack {
                        Text(action.displayName)
                        Spacer()
                        ShortcutRecorder(
                            shortcut: binding(for: action),
                            onCommit: { newValue in
                                try environment.applyShortcut(action, shortcut: newValue)
                            },
                            onClear: {
                                try? environment.applyShortcut(action, shortcut: nil)
                            }
                        )
                        .frame(width: 156, height: 40)
                        softHint(for: action)
                            .frame(width: 170, alignment: .leading)
                    }
                }
                Text("录制时需按下至少一个修饰键；Esc 取消，Delete 清空（禁用该入口）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("数据") {
                ClearHistoryRow(
                    title: "清空剪贴板历史…",
                    confirmTitle: "确定清空全部剪贴板历史？",
                    message: "已记录的内容会全部删除，该操作不可撤销。"
                ) {
                    await environment.clipboard.clearHistory()
                }
                ClearHistoryRow(
                    title: "清空翻译历史…",
                    confirmTitle: "确定清空全部翻译历史？",
                    message: "最近 \(TranslationHistory.limit) 条翻译记录会被删除，该操作不可撤销。"
                ) {
                    environment.translationHistory.clear()
                }
                ClearHistoryRow(
                    title: "清空计算历史…",
                    confirmTitle: "确定清空全部计算历史？",
                    message: "最近 \(CalculationHistory.limit) 条计算记录会被删除，该操作不可撤销。"
                ) {
                    environment.calculationHistory.clear()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var defaultModuleBinding: Binding<ModuleID?> {
        Binding(
            get: { settings.defaultModule },
            set: { settings.defaultModule = $0 }
        )
    }

    private func binding(for action: HotkeyManager.Action) -> Binding<HotkeyManager.Shortcut?> {
        Binding(
            get: { settings.hotkeys[action] },
            set: { settings.hotkeys[action] = $0 }
        )
    }

    @ViewBuilder
    private func softHint(for action: HotkeyManager.Action) -> some View {
        if let shortcut = settings.hotkeys[action],
           let hint = HotkeyManager.softConflictHints[shortcut.displayString] {
            Text("冲突：\(hint)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .help("可能与「\(hint)」冲突")
        } else {
            Text("")
        }
    }
}

/// 通用页里的一行「清空某类历史」：按钮 + 二次确认 + 结果回执。
private struct ClearHistoryRow: View {
    let title: String
    let confirmTitle: String
    let message: String
    let action: () async -> Void

    @State private var isConfirming = false
    @State private var result: String?

    var body: some View {
        HStack {
            Button(title) { isConfirming = true }
            Spacer()
            if let result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $isConfirming, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task {
                    await action()
                    result = "已清空"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

// MARK: - 剪贴板

struct ClipboardSettingsView: View {
    let environment: AppEnvironment

    private var settings: SettingsStore { environment.settings }

    var body: some View {
        Form {
            Section("存储") {
                LabeledContent("存储上限") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.maxClips) },
                                set: { settings.setMaxClips(Int(($0 / 100).rounded()) * 100) }
                            ),
                            in: 100...5000
                        )
                        .frame(width: 220)
                        Text("\(settings.maxClips) 条")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }

                LabeledContent("展示条数") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.displayCount) },
                                set: { settings.setDisplayCount(Int(($0 / 5).rounded()) * 5) }
                            ),
                            in: 10...Double(min(100, settings.maxClips))
                        )
                        .frame(width: 220)
                        Text("\(settings.displayCount) 条")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }

                LabeledContent("单条最大字节") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.maxClipBytes / 1024) },
                                set: { settings.setMaxClipBytes(Int(($0 / 10).rounded()) * 10 * 1024) }
                            ),
                            in: 10...1024
                        )
                        .frame(width: 220)
                        Text("\(settings.maxClipBytes / 1024) KB")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }

                Text("超长内容直接跳过（不截断）。调整上限只影响后续写入，不回溯删除已有数据。清空历史在「通用 → 数据」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 翻译

struct TranslationSettingsView: View {
    let environment: AppEnvironment

    private var settings: SettingsStore { environment.settings }
    private var service: TranslationService { environment.translationService }

    var body: some View {
        Form {
            Section("引擎") {
                ForEach(TranslationEngineID.allCases, id: \.self) { engine in
                    CredentialCard(
                        engine: engine,
                        service: service,
                        isActive: settings.translationEngine == engine,
                        onSelect: {
                            settings.translationEngine = engine
                            service.activeEngine = engine
                        }
                    )
                }
            }

            Section("默认") {
                Picker("默认目标语言", selection: Binding(
                    get: { settings.targetLanguage },
                    set: { settings.targetLanguage = $0 }
                )) {
                    ForEach(LanguageCatalog.options) { option in
                        Text(option.name).tag(option.code)
                    }
                }

                Toggle("优先使用引擎 TTS（失败时使用系统合成）", isOn: Binding(
                    get: { settings.prefersProviderTTS },
                    set: { settings.prefersProviderTTS = $0 }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

private struct CredentialCard: View {
    let engine: TranslationEngineID
    let service: TranslationService
    let isActive: Bool
    let onSelect: () -> Void

    @State private var appID: String = ""
    @State private var secret: String = ""
    @State private var isVerifying = false
    @State private var statusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(engine.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if isActive {
                    Text("默认")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Spacer()
                Button("使用此引擎") { onSelect() }
                    .controlSize(.small)
                    .disabled(isActive)
                Button("测试连接") {
                    commit()
                    Task {
                        isVerifying = true
                        let result = await service.verify(engine)
                        isVerifying = false
                        statusText = result.label
                    }
                }
                .controlSize(.small)
                .disabled(isVerifying)
            }

            VStack(alignment: .leading, spacing: 8) {
                credentialField("APP ID") {
                    TextField("", text: $appID)
                }
                credentialField("密钥") {
                    SecureField("", text: $secret)
                }
            }

            HStack(spacing: 6) {
                if isVerifying {
                    ProgressView().controlSize(.mini)
                }
                Text(statusText ?? service.verificationStatus(for: engine).label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            let credentials = service.credentials(for: engine)
            appID = credentials.appID
            secret = credentials.secret
        }
        .onSubmit { commit() }
        .onDisappear { commit() }
    }

    private var statusColor: Color {
        switch service.verificationStatus(for: engine) {
        case .unconfigured: .secondary
        case .verified: .green
        case .failed: .red
        }
    }

    /// 标签紧跟输入框、宽度固定，不跟着窗口两端对齐拉伸。
    private func credentialField<Field: View>(
        _ label: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            field()
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            Spacer(minLength: 0)
        }
    }

    private func commit() {
        service.save(
            credentials: TranslateCredentials(appID: appID, secret: secret),
            for: engine
        )
        statusText = service.verificationStatus(for: engine).label
    }
}

// MARK: - 关键词（指令）

struct KeywordsSettingsView: View {
    let environment: AppEnvironment
    @State private var drafts: [ModuleID: String] = [:]
    @State private var conflicts: Set<ModuleID> = []
    @State private var message: String?

    private var settings: SettingsStore { environment.settings }

    var body: some View {
        Form {
            Section("指令") {
                ForEach(ModuleID.allCases, id: \.self) { module in
                    HStack(spacing: 10) {
                        Text(module.title)
                            .frame(width: 70, alignment: .leading)
                        keywordField(module)
                        Text(conflicts.contains(module) ? "冲突" : " ")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(width: 34, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                }

                Text("逗号分隔，1–8 字符，不含空格；指令变更即时生效。例如剪贴板填 `cb, clip`，在浮窗里输入 cb 直接进入剪贴板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("恢复默认") {
                        settings.restoreDefaultKeywords()
                        syncDrafts()
                        conflicts = []
                        message = "已恢复默认指令"
                    }
                    Spacer()
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { syncDrafts() }
    }

    /// 每个功能一行输入框：标签紧跟固定宽度的输入框，不跟着窗口两端对齐拉伸。
    /// 占位提示自绘而不是用 `prompt:`——grouped Form 里 prompt 有可能被当成行标签画到框外。
    private func keywordField(_ module: ModuleID) -> some View {
        let hint = SettingsStore.defaultKeywords[module]?.joined(separator: ", ") ?? ""
        let text = binding(for: module)
        return TextField("", text: text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
            .overlay(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .onSubmit { commit(module: module, raw: text.wrappedValue) }
    }

    private func binding(for module: ModuleID) -> Binding<String> {
        Binding(
            get: { drafts[module] ?? settings.keywords(for: module).joined(separator: ", ") },
            set: { newValue in
                drafts[module] = newValue
                commit(module: module, raw: newValue)
            }
        )
    }

    private func commit(module: ModuleID, raw: String) {
        let parsed = raw
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard parsed.allSatisfy({ $0.count >= 1 && $0.count <= 8 && !$0.contains(" ") }) else {
            conflicts.insert(module)
            message = "指令长度需为 1–8 字符且不含空格"
            return
        }

        var candidate = settings.keywords
        candidate[module] = parsed

        // 冲突检测：同一关键词被多个功能占用
        var owners: [String: Set<ModuleID>] = [:]
        for (owner, list) in candidate {
            for keyword in list {
                owners[keyword, default: []].insert(owner)
            }
        }
        let duplicated = owners.filter { $0.value.count > 1 }
        if duplicated.isEmpty {
            settings.keywords = candidate
            conflicts.remove(module)
            message = nil
        } else {
            conflicts = Set(duplicated.values.flatMap { $0 })
            message = "指令冲突：\(duplicated.keys.sorted().joined(separator: "、"))"
        }
    }

    private func syncDrafts() {
        var next: [ModuleID: String] = [:]
        for module in ModuleID.allCases {
            next[module] = settings.keywords(for: module).joined(separator: ", ")
        }
        drafts = next
    }
}

// MARK: - 关于

struct AboutSettingsView: View {
    @State private var showLicenses = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("MacTools")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("MacOS工具集 · 版本 \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("剪贴板历史 · 截图标注 · 划词翻译 · 计算器")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
            Text("© 2026 MacTools. Developed by liu-nian.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLicenses) {
            LicensesView()
        }
    }
}

private struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private let items: [(String, String)] = [
        ("GRDB.swift", "MIT License · Copyright © Gwendal Roué"),
        ("SoulverCore", "SoulverCore 商业授权（分发需自行购买授权）· Copyright © Zac Cohan"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开源许可")
                .font(.title3.weight(.semibold))
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.system(size: 12, weight: .semibold))
                    Text(item.1).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 260)
    }
}
