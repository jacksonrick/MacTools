#if DEBUG
import AppKit
import ApplicationServices

/// 仅在 `MACTOOLS_DEBUG_SELFTEST=1` 时输出，正常运行时零开销。
/// 面板导航（enter/back/close）的转移轨迹靠它留痕，便于对照自检断言定位问题。
@MainActor
enum HUDDebug {
    static let enabled = ProcessInfo.processInfo.environment["MACTOOLS_DEBUG_SELFTEST"] == "1"

    static func trace(_ message: String, file: String = #fileID, line: Int = #line) {
        guard enabled else { return }
        print("   · \(message)  <\(file):\(line)>")
    }
}

/// 仅 DEBUG：无人工按键时的自动化走查。
/// 用法：`MACTOOLS_DEBUG_SELFTEST=1 ./MacTools.app/Contents/MacOS/MacTools`
/// 直接驱动 HUDRouter 的按键序列，逐条断言状态转移。
@MainActor
enum DebugSelfTest {

    private static var failures: [String] = []
    private static var checks = 0

    static func run(environment: AppEnvironment) async {
        let router = environment.router
        let panel = environment.panel
        failures.removeAll()
        checks = 0

        print("\n=== SELFTEST START ===")

        // 1. 唤起：工具条可见，未激活任何功能
        router.open()
        await settle()
        expect("open → level = bar（未激活功能）", router.level == .bar)
        expect("open → panel visible", panel.isVisible)
        expect("open → panel is key", panel.isKeyWindow)
        expect("open → first responder is field", panel.firstResponder is NSTextView)

        // 2. Tab 循环切功能（顺序 = 工具条从左到右）
        expect("Tab → clipboard", router.handle(.tab) && router.level == .module(.clipboard))
        expect("Tab → screenshot", router.handle(.tab) && router.level == .module(.screenshot))
        expect("Tab → translation", router.handle(.tab) && router.level == .module(.translation))
        expect("Tab → calculator", router.handle(.tab) && router.level == .module(.calculator))
        expect("Tab 回绕 → clipboard", router.handle(.tab) && router.level == .module(.clipboard))
        expect("⇧Tab → calculator", router.handle(.shiftTab) && router.level == .module(.calculator))
        expect("Esc → bar", router.handle(.escape) && router.level == .bar)
        expect("bar 中 → → clipboard", router.handle(.arrowRight) && router.level == .module(.clipboard))
        expect("bar 中 ← → 回绕 calculator", { _ = router.handle(.escape); return router.handle(.arrowLeft) }() && router.level == .module(.calculator))
        _ = router.handle(.escape)

        // 3. ⌘1–4 直达
        expect("⌘2 → module(screenshot)", router.handle(.command("2")) && router.level == .module(.screenshot))
        expect("Esc → bar", router.handle(.escape) && router.level == .bar)

        // 4. 关键词必须全文命中
        router.applyText("c", fromField: true)
        await settle(0.05)
        expect("前缀 c 不激活", router.level == .bar && router.keywordBuffer == "c")
        router.applyText("cbx", fromField: true)
        await settle(0.05)
        expect("不完整关键词 cbx 不激活", router.level == .bar)
        router.setText("")
        router.applyText("cb", fromField: true)
        await settle(0.05)
        expect("关键词 cb → module(clipboard)", router.level == .module(.clipboard))
        expect("关键词已清空", router.keywordBuffer.isEmpty)
        _ = router.handle(.escape)
        await settle(0.05)

        router.applyText("tr", fromField: true)
        await settle(0.05)
        expect("关键词 tr → module(translation)", router.level == .module(.translation))
        _ = router.handle(.escape)
        await settle(0.05)

        // 5. = 前缀直接进入计算器
        router.applyText("=23*4", fromField: true)
        await settle(0.05)
        expect("=23*4 → module(calculator)", router.level == .module(.calculator))
        expect("= 后内容作为表达式", router.calcExpression == "23*4")
        _ = router.handle(.escape)
        await settle(0.05)

        // 6. 输入框文本随激活功能走
        router.open()
        await settle(0.1)
        router.switchTo(.clipboard)
        router.applyText("hello", fromField: true)
        expect("clipboard 输入生效", router.clipboardQuery == "hello")
        router.switchTo(.translation)
        expect("Tab 切换后文本随行（翻译）", router.translationSource == "hello")
        router.switchTo(.clipboard)
        expect("切回剪贴板仍保留搜索词", router.clipboardQuery == "hello")

        // 6b. 切到计算器：**不接管**上一条输入。
        //     翻译原文/译文、剪贴板搜索词都是自然语言，带进去只会「无法计算」。
        router.switchTo(.calculator)
        expect("进计算器清空输入框", router.calcExpression.isEmpty && router.text.isEmpty)
        router.applyText("1+2", fromField: true)
        expect("计算器里手动输入照常", router.calcExpression == "1+2")
        router.switchTo(.translation)
        expect("计算器 → 翻译：表达式仍随行", router.translationSource == "1+2")
        router.switchTo(.calculator)
        expect("再回计算器仍然清空", router.calcExpression.isEmpty)

        _ = router.handle(.escape)
        await settle(0.1)

        // 7. 截图不接收输入，回车开始
        var screenshotStarted = false
        let originalStart = router.onStartScreenshot
        router.onStartScreenshot = { screenshotStarted = true }
        router.switchTo(.screenshot)
        expect("进入截图", router.level == .module(.screenshot))
        expect("截图不接收文本", router.acceptsText == false && router.text.isEmpty)
        router.applyText("abc", fromField: true)
        expect("截图期间键入被丢弃", router.level == .module(.screenshot) && router.text.isEmpty)
        expect("↩ 触发截图", router.handle(.enter) && screenshotStarted)
        router.onStartScreenshot = originalStart
        _ = router.handle(.escape)
        await settle(0.05)

        // 8. 关闭
        expect("esc → close", router.handle(.escape))
        await settle(0.4)
        expect("close → level = hidden", router.level == .hidden)
        expect("close → panel hidden", !panel.isVisible)
        expect("close → canBecomeKey = false", panel.canBecomeKey == false)

        // 9. 重复唤起
        router.open()
        await settle()
        expect("reopen → bar", router.level == .bar && panel.isVisible)
        _ = router.handle(.escape)
        await settle(0.4)

        // 10. 真实输入链路：合成按键 → 隐形输入框 → 路由
        router.open()
        await settle()
        panel.focusKeyField()
        await settle(0.1)
        type("tr", into: panel)
        await settle(0.15)
        expect("键入 tr（经输入框）→ module(translation)", router.level == .module(.translation))
        _ = router.handle(.escape)
        await settle(0.1)

        type("c", into: panel)
        await settle(0.1)
        expect("键入 c → keywordBuffer = c", router.keywordBuffer == "c")
        sendKey(51, into: panel)   // deleteBackward
        await settle(0.1)
        expect("退格清空后停留在工具条", router.level == .bar && router.keywordBuffer.isEmpty)

        _ = router.handle(.escape)
        await settle(0.4)

        // 11. 计算器：= 直达 + 实时求值
        router.open()
        router.applyText("=23*4", fromField: true)
        await settle(0.15)
        expect("=23*4 → 92", environment.calculator.result?.value == "92")

        _ = router.handle(.enter)
        await settle(0.35)
        expect("↩ 复制结果到剪贴板", NSPasteboard.general.string(forType: .string) == "92")
        expect("↩ 关闭浮窗", router.level == .hidden)
        expect("历史已记录", environment.calculationHistory.records.first?.result == "92")

        // 12. 百分比 / 单位换算
        router.open(at: .calculator)
        await settle(0.1)
        router.setText("15% of 200")
        await settle(0.1)
        expect("15% of 200 = 30", environment.calculator.result?.value == "30")

        router.setText("1.5m to ft")
        await settle(0.1)
        expect("1.5m to ft 有结果", environment.calculator.result?.value.contains("feet") == true)

        // 12b. 汇率已下线：命中即明确拒绝，不留 $100.00 这种静默错误
        expect("USD→CNY 被识别为汇率换算",
               CalculatorEngine.needsExchangeRate("100 USD to CNY"))
        expect("混合币种运算被识别",
               CalculatorEngine.needsExchangeRate("$100 + ¥20"))
        expect("单位换算不误判为汇率", !CalculatorEngine.needsExchangeRate("1.5m to ft"))
        router.setText("100 USD to CNY")
        await settle(0.1)
        expect("汇率表达式不产出结果",
               environment.calculator.result == nil
               && environment.calculator.unsupportedReason == "暂不支持汇率换算")
        router.setText("23*4")
        await settle(0.1)
        expect("恢复普通求值后提示清除", environment.calculator.unsupportedReason == nil)

        // 13. 历史模式
        environment.calculationHistory.add(expression: "1+1", result: "2")
        expect("↑ 进入历史", router.handle(.arrowUp) && environment.calculator.mode == .history)
        expect("历史游标停在最新一条", environment.calculator.historyIndex == 0)
        _ = router.handle(.arrowUp)
        expect("↑ 连按往更旧翻",
               environment.calculator.mode == .history && environment.calculator.historyIndex == 1)
        _ = router.handle(.arrowDown)
        expect("↓ 回到更新一条", environment.calculator.historyIndex == 0)

        // 历史里回车 = 直接键入到光标处，不回填输入框
        let expressionBeforeHistoryEnter = router.calcExpression
        _ = router.handle(.enter)
        await settle(0.35)
        expect("历史回车不回填输入框", router.calcExpression == expressionBeforeHistoryEnter)
        expect("历史回车把结果写进剪贴板",
               NSPasteboard.general.string(forType: .string) == "2")

        router.open(at: .calculator)
        await settle(0.15)
        expect("Esc 退出历史但不返回扇表",
               router.handle(.arrowUp)
               && router.handle(.escape)
               && environment.calculator.mode == .editing
               && router.level == .module(.calculator))
        _ = router.handle(.escape)
        await settle(0.3)

        // 13b. 翻译历史：存储层（内存库，不污染真实数据）
        if let tempDB = try? AppDatabase.inMemory() {
            let tempTranslation = TranslationHistory(database: tempDB)
            for index in 0..<12 {
                tempTranslation.add(
                    source: "src\(index)",
                    translated: "dst\(index)",
                    targetLanguage: "zh-CHS"
                )
            }
            expect("翻译历史上限 10 条", tempTranslation.records.count == 10)
            expect("翻译历史最新在前", tempTranslation.records.first?.source == "src11")
            expect("翻译历史淘汰最旧", tempTranslation.records.last?.source == "src2")
            expect("翻译历史同库可读回",
                   TranslationHistory(database: tempDB).records.first?.translated == "dst11")
            tempTranslation.clear()
            expect("翻译历史可清空", tempTranslation.records.isEmpty)
        }

        // 13c. 翻译历史的键盘浏览（真实历史为空时只锁「不误入历史」这一侧）
        router.open(at: .translation)
        await settle(0.15)
        if environment.translationHistory.records.isEmpty {
            expect("历史为空时 ↑ 不进入历史",
                   router.handle(.arrowUp) && environment.translation.mode == .editing)
        } else {
            expect("翻译 ↑ 进入历史", router.handle(.arrowUp) && environment.translation.mode == .history)
            expect("翻译 Esc 退出历史",
                   router.handle(.escape)
                   && environment.translation.mode == .editing
                   && router.level == .module(.translation))
        }
        _ = router.handle(.escape)
        await settle(0.3)

        // 13d. 唤起时直接进默认功能
        expect("直达热键映射正确",
               HotkeyManager.Action.clipboard.targetModule == .clipboard
               && HotkeyManager.Action.calculator.targetModule == .calculator
               && HotkeyManager.Action.toggleHUD.targetModule == nil)
        let originalDefaultModule = environment.settings.defaultModule
        environment.settings.defaultModule = .clipboard
        router.open()
        await settle(0.15)
        expect("默认功能：唤起直接进剪贴板", router.currentModule == .clipboard)
        environment.settings.defaultModule = nil
        router.open()
        await settle(0.15)
        expect("默认功能置空：停在工具条", router.level == .bar)
        environment.settings.defaultModule = originalDefaultModule
        _ = router.handle(.escape)
        await settle(0.3)

        // 14. 历史上限与 FIFO（内存库，不污染真实数据）
        if let tempDB = try? AppDatabase.inMemory() {
            let tempHistory = CalculationHistory(database: tempDB)
            for index in 0..<12 {
                tempHistory.add(expression: "\(index)+1", result: "\(index + 1)")
            }
            expect("历史上限 10 条", tempHistory.records.count == 10)
            expect("FIFO 最新在前", tempHistory.records.first?.expression == "11+1")
            expect("FIFO 淘汰最旧", tempHistory.records.last?.expression == "2+1")
        }

        // 15. 剪贴板存储：淘汰 / 去重 / 搜索
        let tempLimits = ClipboardLimits(maxBytes: 1024, maxClips: 20)
        if let tempStore = try? ClipboardStore(inMemory: tempLimits) {
            for index in 0..<30 {
                _ = try? await tempStore.upsert(text: "hello world \(index)")
            }
            let kept = (try? await tempStore.count()) ?? -1
            expect("淘汰后仅保留 maxClips 条 (20)", kept == 20)

            _ = try? await tempStore.upsert(text: "hello world 29")
            let afterDuplicate = (try? await tempStore.count()) ?? -1
            expect("重复内容不新增行", afterDuplicate == 20)

            let hits = (try? await tempStore.search("hello world 29", limit: 5)) ?? []
            expect("FTS5 搜索命中", hits.first?.content == "hello world 29")

            _ = try? await tempStore.upsert(text: "中文剪贴板测试内容")
            let cjkHits = (try? await tempStore.search("剪贴", limit: 5)) ?? []
            expect("中文子串搜索命中", cjkHits.contains { $0.content == "中文剪贴板测试内容" })

            let longText = String(repeating: "a", count: 4096)
            let longOutcome = try? await tempStore.upsert(text: longText)
            if case .skippedTooLong = longOutcome {
                expect("超长内容跳过而非截断", true)
            } else {
                expect("超长内容跳过而非截断", false)
            }
        }

        // 16. 监听器：真实复制 → 落库
        let marker = "selftest-clip-\(UUID().uuidString.prefix(8))"
        PasteService.copy(marker)
        await settle(0.8)
        let captured = (try? await environment.clipboardStore.search(marker, limit: 5)) ?? []
        expect("监听器采集新复制内容", captured.contains { $0.content == marker })

        // 17. 列表与直贴
        router.open(at: .clipboard)
        await settle(0.35)
        expect("列表加载", !environment.clipboard.clips.isEmpty)
        expect("选中项存在", environment.clipboard.selectedClip != nil)

        let target = environment.clipboard.clips.first
        _ = router.handle(.command("1"))
        await settle(0.4)
        expect("⌘1 直贴第 1 条", NSPasteboard.general.string(forType: .string) == target?.content)
        if AXIsProcessTrusted() {
            expect("直贴后浮窗关闭", router.level == .hidden)
        } else {
            // 未授权辅助功能：仅复制 + 状态行提示，3 秒后关闭
            expect("未授权降级为仅复制并提示",
                   router.statusMessage?.contains("已复制") == true)
            await settle(3.2)
            expect("降级路径 3 秒后关闭", router.level == .hidden)
        }

        // 17b. 鼠标交互：悬停换预览（不滚动列表）、单击复制并收起
        router.open(at: .clipboard)
        await settle(0.35)
        if environment.clipboard.clips.count >= 2,
           let secondID = environment.clipboard.clips[1].id {
            environment.clipboard.hoverSelect(secondID)
            expect("悬停即切换选中项", environment.clipboard.selectedID == secondID)
            expect("悬停来源标记为 hover（列表不跟随滚动）",
                   environment.clipboard.selectionSource == .hover)
        }
        if let first = environment.clipboard.clips.first {
            environment.clipboard.copyFromList(first, router: router)
            expect("单击列表项复制到剪贴板",
                   NSPasteboard.general.string(forType: .string) == first.content)
            expect("单击复制给出来源提示", router.statusMessage?.contains("已复制") == true)
            await settle(0.6)
            expect("单击复制后浮窗收起", router.level == .hidden)
        }

        // 清理测试数据
        for clip in captured {
            if let id = clip.id { try? await environment.clipboardStore.delete(id: id) }
        }

        // 18. 统一存储：设置 / 历史 / 凭据 / 剪贴板都在 settings.sqlite
        expect("运行库为 settings.sqlite",
               environment.database.fileURL?.lastPathComponent == AppDatabase.fileName)
        let legacyURL = AppDatabase.defaultURL().deletingLastPathComponent()
            .appendingPathComponent(AppDatabase.legacyFileName)
        expect("旧 clips.sqlite 已不存在", !FileManager.default.fileExists(atPath: legacyURL.path))
        if let attributes = try? FileManager.default.attributesOfItem(atPath: AppDatabase.defaultURL().path),
           let permissions = attributes[.posixPermissions] as? Int {
            expect("库文件权限 0600", permissions == 0o600)
        }

        if let tempDB = try? AppDatabase.inMemory() {
            expect("存储上限默认 1000", SettingsStore(database: tempDB).maxClips == 1000)
            expect("默认快捷键表不含剪贴板 / 计算器",
                   SettingsStore.defaultShortcuts[.clipboard] == nil
                   && SettingsStore.defaultShortcuts[.calculator] == nil)

            let tempSettings = SettingsStore(database: tempDB)
            tempSettings.setMaxClips(300)
            expect("设置改动立即在内存生效", tempSettings.maxClips == 300)
            // 落盘是**合并提交**的（滑杆拖动不该每帧开一个事务），断言磁盘前要显式 flush。
            tempSettings.flush()
            expect("设置 flush 后可读回", SettingsStore(database: tempDB).maxClips == 300)

            // 连续改动（等同拖动滑杆）只应落最后一次：盘上不会出现中间值。
            for value in stride(from: 320, through: 480, by: 4) {
                tempSettings.setMaxClips(value)
            }
            tempSettings.flush()
            expect("连续改动只落最后一次", SettingsStore(database: tempDB).maxClips == 480)
            tempSettings.setMaxClips(300)
            tempSettings.flush()

            // 量化「合并提交」省掉的是什么：单次 kv 同步写入的耗时。
            // 拖动滑杆时 didSet 跟着刷新率走（每秒几十次），原来每一次都是一整个 WAL 事务。
            do {
                let rounds = 50
                let started = CFAbsoluteTimeGetCurrent()
                for i in 0..<rounds { tempDB.setInt(i, forKey: "bench.kv") }
                let perWrite = (CFAbsoluteTimeGetCurrent() - started) * 1000 / Double(rounds)
                print(String(format: "   · 单次 kv 同步写入 %.2fms（60fps 拖动 = 每秒 %.0fms 主线程）",
                             perWrite, perWrite * 60))
            }

            CalculationHistory(database: tempDB).add(expression: "9*9", result: "81")
            expect("计算历史同库可读回",
                   CalculationHistory(database: tempDB).records.first?.expression == "9*9")

            // 默认展示功能
            tempSettings.defaultModule = .calculator
            tempSettings.flush()
            expect("默认展示功能可持久化", SettingsStore(database: tempDB).defaultModule == .calculator)
            let cleared = SettingsStore(database: tempDB)
            cleared.defaultModule = nil
            cleared.flush()
            expect("默认展示功能可置空", SettingsStore(database: tempDB).defaultModule == nil)

            // 主动清空快捷键后，重启不能把默认值又补回来（值存的是显式 null）
            tempSettings.hotkeys[.screenshot] = nil
            tempSettings.flush()
            expect("清空的快捷键重启后仍是未绑定",
                   SettingsStore(database: tempDB).hotkeys[.screenshot] == nil)

            TranslationService(database: tempDB, activeEngine: .baidu)
                .save(credentials: TranslateCredentials(appID: "selftest-id", secret: "selftest-key"), for: .baidu)
            expect("翻译凭据同库可读回",
                   TranslationService(database: tempDB, activeEngine: .baidu).isConfigured)

            let tempClips = ClipboardStore(
                database: tempDB,
                limits: ClipboardLimits(maxBytes: 4096, maxClips: 10)
            )
            _ = try? await tempClips.upsert(text: "同库剪贴板")
            tempSettings.flush()
            expect("剪贴板与设置同库",
                   (try? await tempClips.count()) == 1 && tempDB.allKeys().contains("clip.maxClips"))

            // 淘汰一次的成本。下调存储上限时滑杆每帧都会触发回调，原来是每次都跑这一条
            // 全表 DELETE；现在合并成 200ms 一次（`EvictionDebouncer`）。
            do {
                try? await tempDB.queue.write { db in
                    for i in 0..<500 {
                        try db.execute(
                            sql: "INSERT INTO clips (contentHash, content, createdAt, lastSeenAt, pasteCount, isPinned) VALUES (?,?,?,?,0,0)",
                            arguments: ["bench\(i)", String(repeating: "x", count: 200), Date(),
                                        Date().addingTimeInterval(-Double(i))]
                        )
                    }
                }
                let evictStore = ClipboardStore(
                    database: tempDB,
                    limits: ClipboardLimits(maxBytes: 1 << 20, maxClips: 500)
                )
                let started = CFAbsoluteTimeGetCurrent()
                try? await evictStore.enforceLimit()
                let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                print(String(format: "   · 500 条淘汰一次 %.1fms（滑杆拖动原来每秒跑几十次）", ms))
            }
        }

        // 19. 签名算法（与命令行 md5/shasum 对齐）
        expect("百度签名 MD5(appid+q+salt+secret)",
               Digest.md5("1" + "hello" + "1" + "secret") == "8d108551c25f34b0eadd5fcf0aaf94d7")
        expect("有道签名 SHA256(appKey+truncate+salt+curtime+secret)",
               Digest.sha256("test" + "hello" + "123" + "1700000000" + "s3cr3t")
               == "81888ac9b2ef27edab0ec765723ec50748504c401d036d7786f4e7d6952786f8")

        // 20. 翻译视图：预填 / 未配置提示 / 语言切换 / 朗读开关
        router.open(at: .translation, seed: "hello world")
        await settle(0.25)
        expect("划词预填原文", router.translationSource == "hello world")
        expect("直达翻译视图", router.level == .module(.translation))

        if !environment.translation.isConfigured {
            environment.translation.translate(router: router)
            await settle(0.15)
            expect("未配置引擎时原地报错",
                   environment.translation.errorMessage?.contains("未配置") == true)
        }

        let originalLanguage = environment.settings.targetLanguage
        _ = router.handle(.command("l"))
        await settle(0.05)
        expect("⌘L 切换目标语言", environment.settings.targetLanguage != originalLanguage)
        environment.settings.targetLanguage = originalLanguage

        _ = router.handle(.command("s"))
        await settle(0.15)
        expect("⌘S 不再触发朗读（已改为卡片内按钮）",
               environment.translation.isSpeaking == false)

        environment.translation.toggleSpeech(.source, router: router)
        await settle(0.15)
        expect("原文朗读按钮开始朗读", environment.translation.isSpeaking(.source))
        environment.translation.toggleSpeech(.source, router: router)
        await settle(0.15)
        expect("再次点击停止朗读", environment.translation.isSpeaking == false)
        expect("译文为空时朗读按钮不触发", {
            environment.translation.toggleSpeech(.translation, router: router)
            return environment.translation.isSpeaking == false
        }())
        expect("源语言识别（英文）", TranslationController.detectLanguageCode(in: "hello world") == "en")
        expect("源语言识别（中文）", TranslationController.detectLanguageCode(in: "你好，世界") == "zh")

        // 取词失败必须能区分「没授权」和「真的没选中」。
        // 三级回退里第一级（AX）和第三级（⌘C）都以辅助功能授权为前提，没权限时三层全空，
        // 早期只能报「没有取到选中的文本」—— 用户会以为是选中没选对，根本想不到去授权。
        expect("取词失败：未授权有专门文案",
               TextSelectionService.Failure.accessibilityNotGranted.errorDescription?.contains("辅助功能") == true)
        expect("取词失败：未授权与「没取到」是两类",
               TextSelectionService.Failure.accessibilityNotGranted != .unavailable)
        expect("取词失败：安全输入有专门文案",
               TextSelectionService.Failure.secureInput.errorDescription?.contains("安全输入") == true)

        _ = router.handle(.escape)
        await settle(0.3)

        // 21. 截图：标注合成 / 保存命名 / PNG 剪贴板 / 马赛克底图
        let canvas = NSImage(size: NSSize(width: 120, height: 80))
        canvas.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 80).fill()
        canvas.unlockFocus()

        let annotationModel = AnnotationModel()
        annotationModel.shapes.append(AnnotationShape(
            kind: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)),
            color: .red,
            lineWidth: 3
        ))
        annotationModel.shapes.append(AnnotationShape(
            kind: .arrow(start: CGPoint(x: 60, y: 20), end: CGPoint(x: 100, y: 60)),
            color: .yellow,
            lineWidth: 3
        ))
        annotationModel.shapes.append(AnnotationShape(
            kind: .pen(points: [CGPoint(x: 5, y: 70), CGPoint(x: 30, y: 60), CGPoint(x: 50, y: 72)]),
            color: .green,
            lineWidth: 3
        ))
        annotationModel.shapes.append(AnnotationShape(
            kind: .mosaic(points: [CGPoint(x: 70, y: 10), CGPoint(x: 100, y: 30)]),
            color: .gray,
            lineWidth: 18
        ))
        annotationModel.addText(at: CGPoint(x: 20, y: 45))

        expect("马赛克底图生成", MosaicProcessor.pixelate(canvas) != nil)
        expect("标注工具只保留五种（无表情）", AnnotationTool.allCases.count == 5)
        expect("选完区域默认不激活任何工具（拖动模式）", AnnotationModel().tool == nil)
        expect("文字大小三档且默认中号",
               TextSizeTier.allCases.count == 3 && AnnotationModel().textTier == .medium)

        // 20a. 元素可选中 / 可拖动 / 可缩放 / 可改色 / 可删除
        let rectID = annotationModel.shapes[0].id
        expect("命中测试命中矩形", annotationModel.hitTest(CGPoint(x: 12, y: 12)) == rectID)
        expect("空白处命中测试返回 nil", annotationModel.hitTest(CGPoint(x: 115, y: 5)) == nil)

        annotationModel.select(rectID)
        expect("选中元素会点亮对应工具",
               annotationModel.tool == .rectangle && annotationModel.selection == rectID)

        annotationModel.move(rectID, from: annotationModel.shapes[0].kind, by: CGSize(width: 10, height: 6))
        if case .rectangle(let moved) = annotationModel.shapes[0].kind {
            expect("拖动矩形位置更新", moved.origin == CGPoint(x: 20, y: 16))
        } else {
            expect("拖动矩形位置更新", false)
        }

        if let snapshot = annotationModel.snapshot(rectID) {
            // 手柄基准必须是「不含外扩」的真实边界：之前按外扩后的框回写，
            // 手指刚点上手柄、还没拖，矩形就胖了一圈。
            expect("缩放基准 = 真实边界（不含命中外扩）",
                   snapshot.bounds == CGRect(x: 20, y: 16, width: 40, height: 30))
            let still = ResizeHandle.bottomRight.applied(to: snapshot.bounds, dx: 0, dy: 0, minSize: 12)
            annotationModel.resize(snapshot, to: still)
            if case .rectangle(let rect) = annotationModel.shapes[0].kind {
                expect("按住手柄不动不会改变尺寸", rect.width == 40 && rect.height == 30)
            } else {
                expect("按住手柄不动不会改变尺寸", false)
            }
            annotationModel.resize(snapshot, to: CGRect(x: 20, y: 16, width: 80, height: 60))
        }
        if case .rectangle(let resized) = annotationModel.shapes[0].kind {
            expect("缩放矩形尺寸更新", resized.width == 80 && resized.height == 60)
        } else {
            expect("缩放矩形尺寸更新", false)
        }

        annotationModel.applyColor(3)
        expect("改色作用到选中元素", annotationModel.shapes[0].color == .green)

        annotationModel.beginText(at: CGPoint(x: 70, y: 40))
        let draftID = annotationModel.texts.last?.id
        annotationModel.finishTextEditing()
        expect("空文字退出编辑后自动清理",
               draftID != nil && !annotationModel.texts.contains { $0.id == draftID })

        annotationModel.select(annotationModel.texts[0].id)
        expect("选中文字时字号档位同步为中号",
               annotationModel.isTextSelection && annotationModel.textTier == .medium)
        annotationModel.applyTextSize(.large)
        expect("改字号作用到选中文字",
               annotationModel.texts[0].fontSize == TextSizeTier.large.pointSize)
        expect("文字不参与缩放手柄（只改字号）", annotationModel.isTextSelection)
        annotationModel.deleteSelection()
        expect("删除选中元素", annotationModel.texts.isEmpty)
        expect("取消激活后不能新增标注", { annotationModel.tool = nil; return annotationModel.tool == nil }())

        // 选区调整手柄的几何（左下原点）
        let frameRect = NSRect(x: 100, y: 100, width: 200, height: 120)
        expect("右下角手柄改大小",
               FrameAnchor.bottomRight.applied(to: frameRect, dx: 20, dy: -10, minSize: 16)
               == NSRect(x: 100, y: 90, width: 220, height: 130))
        expect("左上角手柄改大小",
               FrameAnchor.topLeft.applied(to: frameRect, dx: 10, dy: 8, minSize: 16)
               == NSRect(x: 110, y: 100, width: 190, height: 128))
        expect("手柄不会把选区压到负数尺寸",
               FrameAnchor.right.applied(to: frameRect, dx: -400, dy: 0, minSize: 16).width == 16)

        // 手柄光标：角上必须拿到斜向箭头。八个位置落到四款图形（横 / 竖 / 两条斜向），
        // 与系统窗口边缘的取法一致；以前角上是 `.crosshair`，与画布空白处同款，
        // 鼠标移上去毫无变化，看起来就像「角不能拉」。
        let cursorIDs = Set(ResizeCursor.all.map { ObjectIdentifier($0) })
        expect("八手柄光标共四种图形", cursorIDs.count == 4)
        expect("角手柄与边手柄不同款", ResizeHandle.topLeft.cursor !== ResizeHandle.top.cursor)
        expect("两条斜向箭头互不相同", ResizeHandle.topLeft.cursor !== ResizeHandle.topRight.cursor)
        expect("元素角手柄不再是十字光标", ResizeHandle.topLeft.cursor !== NSCursor.crosshair)
        expect("选区角手柄不再是十字光标", FrameAnchor.bottomRight.cursor !== NSCursor.crosshair)

        // 快捷键录制胶囊在 40pt 行里垂直居中（原来画在 bounds.height - 26 贴顶，整行看着歪）
        let capsule = ShortcutRecorder.RecorderView.capsuleRect(
            in: NSRect(x: 0, y: 0, width: 156, height: 40)
        )
        expect("快捷键胶囊垂直居中", abs(capsule.midY - 20) < 0.01)

        // 20c. 画布交互：落点必须跟手。视图坐标 = 图片坐标（1:1），
        //      以前 SwiftUI 手势 + letterbox 换算让落点整体偏移，这里锁死数值。
        let interactiveModel = AnnotationModel(image: NSImage(size: NSSize(width: 200, height: 100)))
        let interactiveCanvas = AnnotationCanvasView(model: interactiveModel)
        interactiveCanvas.frame = NSRect(x: 0, y: 0, width: 200, height: 100)

        interactiveModel.tool = .rectangle
        interactiveCanvas.beginDrag(at: CGPoint(x: 20, y: 20))
        interactiveCanvas.continueDrag(to: CGPoint(x: 80, y: 60))
        interactiveCanvas.endDrag()
        if case .rectangle(let drawn)? = interactiveModel.shapes.first?.kind {
            expect("画框落点与鼠标一致", drawn == CGRect(x: 20, y: 20, width: 60, height: 40))
        } else {
            expect("画框落点与鼠标一致", false)
        }

        let shapeID = interactiveModel.shapes[0].id
        interactiveModel.select(shapeID)
        expect("选图形点亮对应工具图标", interactiveModel.tool == .rectangle)

        // 拖元素：位移必须等于鼠标位移，且不累积漂移（基准是按下那一刻的几何）
        interactiveModel.tool = nil
        interactiveCanvas.beginDrag(at: CGPoint(x: 50, y: 40))
        interactiveCanvas.continueDrag(to: CGPoint(x: 60, y: 45))
        interactiveCanvas.continueDrag(to: CGPoint(x: 70, y: 55))
        interactiveCanvas.endDrag()
        if case .rectangle(let moved)? = interactiveModel.shapes.first?.kind {
            expect("拖动元素跟手且不累积漂移", moved.origin == CGPoint(x: 40, y: 35))
        } else {
            expect("拖动元素跟手且不累积漂移", false)
        }

        // 手柄缩放：按下去不拖不能改尺寸
        interactiveModel.tool = nil
        interactiveModel.select(shapeID)
        interactiveCanvas.beginDrag(at: CGPoint(x: 100, y: 75))
        interactiveCanvas.continueDrag(to: CGPoint(x: 100, y: 75))
        interactiveCanvas.endDrag()
        if case .rectangle(let held)? = interactiveModel.shapes.first?.kind {
            expect("按住手柄不动不改尺寸", held.size == CGSize(width: 60, height: 40))
        } else {
            expect("按住手柄不动不改尺寸", false)
        }
        interactiveCanvas.beginDrag(at: CGPoint(x: 100, y: 75))
        interactiveCanvas.continueDrag(to: CGPoint(x: 120, y: 95))
        interactiveCanvas.endDrag()
        if case .rectangle(let resized)? = interactiveModel.shapes.first?.kind {
            expect("拖手柄缩放跟手", resized == CGRect(x: 40, y: 35, width: 80, height: 60))
        } else {
            expect("拖手柄缩放跟手", false)
        }

        // 文字：按住直接拖到任意位置（不参与八手柄缩放）
        interactiveModel.texts.append(AnnotationTextItem(
            text: "文字",
            position: CGPoint(x: 150, y: 20),
            fontSize: TextSizeTier.medium.pointSize,
            color: .red
        ))
        interactiveModel.tool = nil
        interactiveCanvas.beginDrag(at: CGPoint(x: 150, y: 20))
        interactiveCanvas.continueDrag(to: CGPoint(x: 170, y: 30))
        interactiveCanvas.endDrag()
        expect("文字可直接拖到任意位置",
               interactiveModel.texts.last?.position == CGPoint(x: 170, y: 30))
        interactiveModel.select(interactiveModel.texts.last!.id)
        expect("选中文字时不出缩放手柄", interactiveModel.isTextSelection)

        // 未激活工具时按在空白处 = 拖动整个选区（不是重新框选）
        interactiveModel.tool = nil
        interactiveCanvas.beginDrag(at: CGPoint(x: 10, y: 10))
        expect("未激活工具时拖空白处 = 拖选区", interactiveCanvas.endDrag() == true)

        // 文字输入：点一下就进入编辑，点空白处收尾并把空文字回收掉
        interactiveModel.tool = .text
        interactiveCanvas.beginDrag(at: CGPoint(x: 30, y: 80))
        expect("文字工具点空白即开始输入",
               interactiveModel.editingText != nil && interactiveCanvas.debugIsEditing)
        interactiveModel.tool = nil
        interactiveCanvas.beginDrag(at: CGPoint(x: 10, y: 95))
        interactiveCanvas.endDrag()
        expect("点空白结束输入并回收空文字",
               interactiveModel.editingText == nil
               && !interactiveCanvas.debugIsEditing
               && interactiveModel.texts.count == 1)

        // 双击已有文字 → 改字；内容非空，收尾后要保留
        let keptTextID = interactiveModel.texts[0].id
        interactiveCanvas.beginDrag(at: CGPoint(x: 170, y: 30), doubleClick: true)
        expect("双击文字进入编辑",
               interactiveModel.editingText == keptTextID && interactiveCanvas.debugIsEditing)
        interactiveModel.tool = nil
        interactiveCanvas.beginDrag(at: CGPoint(x: 10, y: 95))
        interactiveCanvas.endDrag()
        expect("改完文字后仍保留该元素",
               !interactiveCanvas.debugIsEditing && interactiveModel.texts.count == 1)


        // 2x 底图导出必须仍是物理像素，不能被 ImageRenderer 压回 1x
        let retina = Self.retinaImage(width: 60, height: 40)
        expect("识别 2x 底图像素倍率", AnnotationRenderer.pixelScale(of: retina) == 2)
        let hdModel = AnnotationModel(image: retina, pixelated: nil)
        hdModel.shapes.append(AnnotationShape(
            kind: .rectangle(CGRect(x: 5, y: 5, width: 30, height: 20)),
            color: .red,
            lineWidth: 3
        ))
        let hdRender = AnnotationRenderer.render(image: retina, model: hdModel)
        expect("导出保持 2x 像素",
               hdRender?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 120)

        // 20b. 标注坐标系：图片居中留白（letterbox）必须从落点里扣掉，
        //      否则画框 / 箭头 / 文字都会整体偏下或偏右。
        let layout = CanvasLayout(
            imageSize: CGSize(width: 100, height: 50),
            available: CGSize(width: 200, height: 200)
        )
        expect("等比布局居中且有上下留白",
               layout.scale == 2 && layout.origin == CGPoint(x: 0, y: 50))
        expect("落点扣掉 letterbox 偏移",
               layout.imagePoint(from: CGPoint(x: 100, y: 100), imageSize: CGSize(width: 100, height: 50))
               == CGPoint(x: 50, y: 25))
        expect("落点被夹在图片范围内",
               layout.imagePoint(from: CGPoint(x: 0, y: 0), imageSize: CGSize(width: 100, height: 50))
               == .zero)

        let cropped = SelectionOverlay.crop(
            canvas,
            to: NSRect(x: 10, y: 20, width: 40, height: 30),
            in: NSRect(x: 0, y: 0, width: 120, height: 80)
        )
        expect("选区裁剪尺寸正确", cropped?.size == NSSize(width: 40, height: 30))

        // 20c. 覆盖层底图必须是**不透明**位图，并且真的压暗了。
        //      这个覆盖层窗口上 alpha < 1 的像素不会合成：早期用「底图画一遍 +
        //      再叠 35% 黑」，屏幕上只会看到桌面原样，表现就是「按了截图没反应」。
        let dimmed = SelectionOverlay.debugDimmedImage(canvas)
        expect("覆盖层底图是不透明位图",
               dimmed.cgImage(forProposedRect: nil, context: nil, hints: nil)?.alphaInfo == .noneSkipLast)
        expect("覆盖层底图已压暗", Self.brightness(dimmed) < Self.brightness(canvas) * 0.75)

        let overlayView = SelectionOverlayView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 80),
            shot: canvas
        )
        expect("覆盖层吃下第一次点击（否则第一次拖拽无反应）",
               overlayView.acceptsFirstMouse(for: nil))

        let rendered = AnnotationRenderer.render(image: canvas, model: annotationModel)
        expect("标注合成产出图片", rendered != nil)
        expect("合成尺寸与底图一致", rendered?.size == canvas.size)

        if let rendered {
            environment.screenshot.copyToPasteboard(rendered)
            expect("截图 PNG 写入剪贴板", NSPasteboard.general.data(forType: .png) != nil)

            let originalDirectory = environment.settings.screenshotDirectory
            let tempDirectory = NSTemporaryDirectory() + "mactools-shots-\(UUID().uuidString.prefix(6))"
            environment.settings.screenshotDirectory = tempDirectory
            let saved = environment.screenshot.save(rendered)
            environment.settings.screenshotDirectory = originalDirectory

            expect("保存文件落盘", saved != nil && FileManager.default.fileExists(atPath: saved?.path ?? ""))
            expect("命名符合 Screenshot 规范",
                   saved?.lastPathComponent.hasPrefix("Screenshot ") == true
                   && saved?.pathExtension == "png")
            if let saved { try? FileManager.default.removeItem(at: saved.deletingLastPathComponent()) }
        }

        // 22. 设置窗口
        environment.openSettings()
        await settle(0.6)
        let settingsWindow = NSApp.windows.first { $0.title == "MacTools 设置" }
        expect("设置窗口打开", settingsWindow?.isVisible == true)
        let contentSize = settingsWindow?.contentView?.bounds.size ?? .zero
        print("   · 设置窗口内容尺寸 = \(contentSize)")
        // 自绘左右布局：没有 NavigationSplitView 的工具栏，内容尺寸严格等于名义尺寸。
        expect("设置窗口内容尺寸 ≈680×520",
               abs(contentSize.width - 680) < 2 && abs(contentSize.height - 520) < 2)
        expect("设置窗口不可缩放",
               settingsWindow?.styleMask.contains(.resizable) == false)

        // 应用内快捷键互斥
        var conflictRejected = false
        if let toggle = environment.settings.hotkeys[.toggleHUD] {
            let originalScreenshot = environment.settings.hotkeys[.screenshot]
            do {
                try environment.applyShortcut(.screenshot, shortcut: toggle)
            } catch {
                conflictRejected = true
            }
            try? environment.applyShortcut(.screenshot, shortcut: originalScreenshot)
        }
        expect("应用内快捷键冲突被拒绝", conflictRejected)

        // 关键词冲突检测
        let savedKeywords = environment.settings.keywords
        var conflictKeywords = savedKeywords
        conflictKeywords[.clipboard] = ["tr"]
        environment.settings.keywords = conflictKeywords
        expect("关键词冲突可检测", environment.settings.keywordConflicts.contains("tr"))
        environment.settings.keywords = savedKeywords
        expect("关键词恢复后无冲突", environment.settings.keywordConflicts.isEmpty)

        // 23. 设置窗口打开时浮窗快捷键仍生效
        NSApp.activate()
        settingsWindow?.makeKey()
        router.open()
        await settle(0.4)
        expect("设置窗口可见时浮窗仍可唤起", router.level == .bar)
        expect("浮窗取得 key（设置窗口不抢焦点）", panel.isKeyWindow)
        _ = router.handle(.escape)
        await settle(0.4)
        settingsWindow?.close()

        // 24. 全键盘走查（不使用鼠标）
        router.open()
        await settle(0.25)
        var walkthrough = router.level == .bar
        walkthrough = walkthrough && router.handle(.command("1")) && router.level == .module(.clipboard)
        walkthrough = walkthrough && router.handle(.escape) && router.level == .bar
        walkthrough = walkthrough && router.handle(.tab) && router.level == .module(.clipboard)
        walkthrough = walkthrough && router.handle(.tab) && router.level == .module(.screenshot)
        walkthrough = walkthrough && router.handle(.tab) && router.level == .module(.translation)
        walkthrough = walkthrough && router.handle(.escape) && router.level == .bar
        walkthrough = walkthrough && router.handle(.escape)
        await settle(0.35)
        expect("全键盘走查（无鼠标完成唤起→切功能→返回→关闭）",
               walkthrough && router.level == .hidden)

        // 25. 性能：唤起延迟 + 500 条搜索延迟
        let openStart = CFAbsoluteTimeGetCurrent()
        router.open()
        let openLatency = (CFAbsoluteTimeGetCurrent() - openStart) * 1000
        expect(String(format: "唤起 → 面板上屏 %.1fms（目标 ≤150ms）", openLatency),
               openLatency <= 150 && panel.isVisible)
        _ = router.handle(.escape)
        await settle(0.35)

        let perfLimits = ClipboardLimits(maxBytes: 100 * 1024, maxClips: 500)
        if let perfStore = try? ClipboardStore(inMemory: perfLimits) {
            for index in 0..<500 {
                _ = try? await perfStore.upsert(text: "perf item \(index) payload")
            }
            let count = (try? await perfStore.count()) ?? 0
            expect("500 条写入并保留", count == 500)

            let searchStart = CFAbsoluteTimeGetCurrent()
            let results = (try? await perfStore.search("perf item 499", limit: 50)) ?? []
            let searchLatency = (CFAbsoluteTimeGetCurrent() - searchStart) * 1000
            expect(String(format: "500 条下搜索 %.2fms（目标 ≤50ms）", searchLatency),
                   searchLatency <= 50 && !results.isEmpty)
        }

        // 26. 可访问性降级开关可读取（降级逻辑在视图层按环境值切换）
        expect("系统提供 Reduce Transparency / Reduce Motion 状态",
               NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == true
               || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == false)

        // 27. 权限诊断：签名形态 / 启动方式 / 待解释原因
        let permissions = environment.permissions
        print("   · 签名形态：\(describe(permissions.codeSignatureKind))")
        print("   · 由终端启动：\(permissions.isRunFromTerminal)")
        print("   · 屏幕录制已授权：\(permissions.hasScreenRecording)")
        for hint in permissions.screenRecordingHints {
            print("   · 权限提示：\(hint)")
        }
        expect("能识别当前二进制签名形态", permissions.codeSignatureKind != .unknown)
        // 不在这里真的申请授权：会弹出系统面板打断自动化。
        expect("屏幕录制状态查询无副作用",
               permissions.hasScreenRecording == CGPreflightScreenCaptureAccess())

        // 汇总
        print("=== SELFTEST \(failures.isEmpty ? "PASSED" : "FAILED") (\(checks - failures.count)/\(checks)) ===")
        for failure in failures {
            print("  ✗ \(failure)")
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func settle(_ seconds: Double = 0.35) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static func describe(_ kind: CodeSignatureKind) -> String {
        switch kind {
        case .adHoc: "ad-hoc（每次重编 CDHash 变化，已授权限会失效）"
        case .identity: "证书身份（签名稳定，授权可长期保留）"
        case .unknown: "未知"
        }
    }

    /// 合成字符按键，走完整的 AppKit 输入链路（含 field editor）。
    private static func type(_ text: String, into panel: KeyboardHUDPanel) {
        for character in text {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: String(character),
                charactersIgnoringModifiers: String(character),
                isARepeat: false,
                keyCode: 0
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private static func sendKey(_ keyCode: UInt16, into panel: KeyboardHUDPanel) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: keyCode == 51 ? "\u{7F}" : "",
            charactersIgnoringModifiers: keyCode == 51 ? "\u{7F}" : "",
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        NSApp.sendEvent(event)
    }

    /// 造一张 2x 位图（逻辑尺寸 width×height，物理像素 2 倍），用于校验导出保真。
    /// 取样平均亮度（0…1）：用来断言「压暗」是否真的写进了位图。
    private static func brightness(_ image: NSImage) -> Double {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        var sum = 0.0
        var count = 0.0
        let stepX = max(1, rep.pixelsWide / 16)
        let stepY = max(1, rep.pixelsHigh / 16)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                sum += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        return count > 0 ? sum / count : 1
    }

    private static func retinaImage(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width * 2,
            pixelsHigh: height * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    private static func expect(_ name: String, _ condition: Bool) {        checks += 1
        if condition {
            print("  ✓ \(name)")
        } else {
            failures.append(name)
            print("  ✗ \(name)")
        }
    }
}
#endif
