import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var environment: AppEnvironment?
    private var menuBar: MenuBarController?
    #if DEBUG
    private var debugOverlay: SelectionOverlay?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        setvbuf(stdout, nil, _IONBF, 0)
        #endif

        let environment = AppEnvironment()
        self.environment = environment
        let menuBar = MenuBarController(environment: environment)
        self.menuBar = menuBar
        environment.menuBar = menuBar

        #if DEBUG
        let debugEnv = ProcessInfo.processInfo.environment
        if let permPath = debugEnv["MACTOOLS_DEBUG_PERM"] ?? UserDefaults.standard.string(forKey: "debugPermProbePath") {
            // 权限排障探针：把签名形态、启动方式、屏幕录制预检结果写到文件后退出。
            let permissions = environment.permissions
            let lines = [
                "bundle: \(Bundle.main.bundlePath)",
                "signature: \(permissions.codeSignatureKind)",
                "adHoc: \(permissions.codeSignatureKind == .adHoc)",
                "runFromTerminal: \(permissions.isRunFromTerminal)",
                "ppid: \(getppid())",
                "screenRecording: \(permissions.hasScreenRecording)",
                "accessibility: \(permissions.isAccessibilityTrusted)"
            ]
            try? lines.joined(separator: "\n").write(toFile: permPath, atomically: true, encoding: .utf8)
            exit(0)
        }
        if let snapshotPath = debugEnv["MACTOOLS_DEBUG_SNAPSHOT"] {
            let state = debugEnv["MACTOOLS_DEBUG_SNAPSHOT_STATE"] ?? "bar"
            let page = SettingsPage(rawValue: debugEnv["MACTOOLS_DEBUG_SNAPSHOT_PAGE"] ?? "") ?? .general
            if debugEnv["MACTOOLS_DEBUG_APPEARANCE"] == "light" {
                NSApp.appearance = NSAppearance(named: .aqua)
            } else if debugEnv["MACTOOLS_DEBUG_APPEARANCE"] == "dark" {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                var target: NSWindow = environment.panel
                switch state {
                case "clipboard": environment.router.open(at: .clipboard)
                case "translation": environment.router.open(at: .translation, seed: "Hello, world.")
                case "translation-history":
                    // 抓历史列表版式用。假记录写进当前库——排查时配合
                    // CFFIXED_USER_HOME=/tmp/... 跑，避免污染真实历史。
                    let samples = [
                        ("Hello, world.", "你好，世界。"),
                        ("Good morning.", "早上好。"),
                        ("How are you today?", "你今天好吗？"),
                        ("The quick brown fox jumps over the lazy dog.", "敏捷的棕色狐狸跳过了懒狗。"),
                    ]
                    for (source, translated) in samples {
                        environment.translationHistory.add(
                            source: source,
                            translated: translated,
                            targetLanguage: "zh-CHS"
                        )
                    }
                    environment.router.open(at: .translation)
                    _ = environment.translation.handle(.arrowUp, router: environment.router)
                case "calculator": environment.router.open(at: .calculator, seed: "23*4")
                case "screenshot": environment.router.open(at: .screenshot)
                case "settings":
                    environment.openSettings(page: page)
                    if let settingsWindow = NSApp.windows.first(where: { $0.title == "MacTools 设置" }) {
                        target = settingsWindow
                    }
                case "annotate", "annotate-real":
                    let shots: [ScreenCaptureShot]
                    if state == "annotate-real" {
                        shots = await environment.screenshot.debugCaptureShots()
                    } else if let screen = NSScreen.main ?? NSScreen.screens.first {
                        shots = [ScreenCaptureShot(screen: screen, image: DebugScreenMock.image(size: screen.frame.size))]
                    } else {
                        shots = []
                    }
                    if let first = shots.first {
                        let overlay = SelectionOverlay(
                            shots: shots,
                            onFinish: { _, _ in },
                            onCancel: {}
                        )
                        overlay.show()
                        // 选区用比例表示：x,y,w,h ∈ [0,1]，默认避开屏幕边缘。
                        let parts = (debugEnv["MACTOOLS_DEBUG_SELECTION"] ?? "0.16,0.34,0.41,0.35")
                            .split(separator: ",")
                            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        let frame = first.screen.frame
                        if parts.count == 4 {
                            // MACTOOLS_DEBUG_TOOL=none 用来核「拖动 / 调整选区」状态（工具全部取消激活），
                            // =text 用来核文字属性（字号档位）。
                            let raw = debugEnv["MACTOOLS_DEBUG_TOOL"]
                            let tool: AnnotationTool?
                            if raw == "none" {
                                tool = nil
                            } else if let raw, let parsed = AnnotationTool(rawValue: raw) {
                                tool = parsed
                            } else {
                                tool = .rectangle
                            }
                            overlay.debugFixSelection(NSRect(
                                x: frame.width * parts[0],
                                y: frame.height * parts[1],
                                width: frame.width * parts[2],
                                height: frame.height * parts[3]
                            ), tool: tool)
                        }
                        if let window = overlay.debugWindows.first {
                            target = window
                        }
                        self.debugOverlay = overlay
                    }
                default: environment.router.open()
                }
                try? await Task.sleep(for: .milliseconds(900))
                do {
                    try HUDSnapshot.capture(window: target, to: snapshotPath)
                    print("[snapshot] \(state) → \(snapshotPath)")
                } catch {
                    print("[snapshot] 失败：\(error)")
                }
                try? await Task.sleep(for: .milliseconds(300))
                if let hold = debugEnv["MACTOOLS_DEBUG_HOLD"], let seconds = Double(hold) {
                    try? await Task.sleep(for: .seconds(seconds))
                }
                exit(0)
            }
        } else if debugEnv["MACTOOLS_DEBUG_SELFTEST"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                await DebugSelfTest.run(environment: environment)
            }
        } else if debugEnv["MACTOOLS_DEBUG_FLOW"] == "shot-key" {
            // 「真实按键事件」链路自查：合成 keyDown 走窗口派发，而不是直接调 router.handle。
            Task { @MainActor in
                let panel = environment.panel
                try? await Task.sleep(for: .milliseconds(600))
                environment.router.open()
                try? await Task.sleep(for: .milliseconds(500))
                print("[key] 唤起：level=\(environment.router.level) first=\(String(describing: panel.firstResponder))")
                Self.postKey(48, characters: "\t", to: panel)
                try? await Task.sleep(for: .milliseconds(250))
                print("[key] Tab：level=\(environment.router.level) first=\(String(describing: panel.firstResponder))")
                Self.postKey(48, characters: "\t", to: panel)
                try? await Task.sleep(for: .milliseconds(250))
                print("[key] Tab2：level=\(environment.router.level)")
                Self.postKey(36, characters: "\r", to: panel)
                for step in 1...12 {
                    try? await Task.sleep(for: .milliseconds(250))
                    print("[key] 回车后 \(step)：level=\(environment.router.level) overlay=\(environment.screenshot.debugOverlayWindowCount) panelVisible=\(panel.isVisible)")
                    if environment.screenshot.debugOverlayWindowCount > 0 {
                        if let path = debugEnv["MACTOOLS_DEBUG_SAVE_SHOT"],
                           let image = environment.screenshot.debugOverlayShot,
                           let tiff = image.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: path))
                            print("[key] 冻结画面已存 \(path)")
                        }
                        break
                    }
                    if step == 12 { break }
                }
                exit(0)
            }
        } else if debugEnv["MACTOOLS_DEBUG_FLOW"] == "shot-direct" {
            // 快捷方式路径：浮窗不在场，直接抓屏。用来对比「回车路径（先 orderOut 浮窗）」
            // 与「快捷键路径」出的覆盖层是否都能真的显示。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                print("[direct] 触发前 level=\(environment.router.level) appActive=\(NSApp.isActive)")
                environment.screenshot.beginCapture()
                for step in 1...10 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if environment.screenshot.debugOverlayWindowCount > 0 { break }
                    _ = step
                }
                print("[direct] 覆盖层状态 \(environment.screenshot.debugOverlayState)")
                if let hold = debugEnv["MACTOOLS_DEBUG_HOLD"], let seconds = Double(hold) {
                    try? await Task.sleep(for: .seconds(seconds))
                }
                exit(0)
            }
        } else if debugEnv["MACTOOLS_DEBUG_FLOW"] == "shot-real" {
            // 「真实键盘 → 回车 → 覆盖层」全链路：按键走事件队列（等同真键盘），
            // 结束后把**合成后的屏幕**抓下来，用来确认覆盖层到底有没有真的画在屏上。
            Task { @MainActor in
                let panel = environment.panel
                try? await Task.sleep(for: .milliseconds(600))
                environment.router.open()
                try? await Task.sleep(for: .milliseconds(450))
                environment.router.switchTo(.screenshot)
                try? await Task.sleep(for: .milliseconds(250))
                print("[real] 回车前 level=\(environment.router.level) appActive=\(NSApp.isActive) panelKey=\(panel.isKeyWindow)")
                Self.postKey(36, characters: "\r", to: panel)
                for step in 1...16 {
                    try? await Task.sleep(for: .milliseconds(200))
                    print("[real] \(step * 200)ms overlay=\(environment.screenshot.debugOverlayWindowCount) appActive=\(NSApp.isActive)")
                    if environment.screenshot.debugOverlayWindowCount > 0 { break }
                }
                try? await Task.sleep(for: .milliseconds(500))
                Self.dumpWindowServer()
                if let path = debugEnv["MACTOOLS_DEBUG_SAVE_SCREEN"],
                   let shot = await environment.screenshot.debugCaptureShots().first,
                   let tiff = shot.image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("[real] 合成画面已存 \(path)")
                }
                if let hold = debugEnv["MACTOOLS_DEBUG_HOLD"], let seconds = Double(hold) {
                    let deadline = Date().addingTimeInterval(seconds)
                    while Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(1000))
                        print("[hold] \(environment.screenshot.debugOverlayState)")
                    }
                }
                exit(0)
            }
        } else if debugEnv["MACTOOLS_DEBUG_FLOW"] == "shot-enter" {
            // 「Tab 激活截图 → 回车」链路自查：不依赖真实按键，直接驱动路由。
            Task { @MainActor in
                let t0 = CFAbsoluteTimeGetCurrent()
                func stamp() -> String { String(format: "%.0fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000) }
                try? await Task.sleep(for: .milliseconds(500))
                environment.router.open()
                try? await Task.sleep(for: .milliseconds(400))
                environment.router.switchTo(.screenshot)
                print("[flow] t=\(stamp()) level=\(environment.router.level) panelVisible=\(environment.panel.isVisible)")
                _ = environment.router.handle(.enter)
                print("[flow] t=\(stamp()) 回车已派发，level=\(environment.router.level)")
                for step in 1...24 {
                    try? await Task.sleep(for: .milliseconds(250))
                    let count = environment.screenshot.debugOverlayWindowCount
                    print("[flow] t=\(stamp()) overlayWindows=\(count) level=\(environment.router.level) panelVisible=\(environment.panel.isVisible)")
                    if count > 0 || step == 24 { break }
                }
                exit(0)
            }
        } else if debugEnv["MACTOOLS_DEBUG_FLOW"] == "tab-calc" {
            // 「翻译里已有文本 → Tab 进计算器」链路自查：投递真按键，
            // 核对输入框是否被清空（带过去的自然语言只会得到「无法计算」）。
            Task { @MainActor in
                let router = environment.router
                let panel = environment.panel
                try? await Task.sleep(for: .milliseconds(500))
                router.open(at: .translation, seed: "Hello, world. 你好，世界")
                try? await Task.sleep(for: .milliseconds(400))
                print("[flow] 翻译态 level=\(router.level) text=\(router.text)")
                if let path = debugEnv["MACTOOLS_DEBUG_SAVE_SCREEN"] {
                    try? HUDSnapshot.capture(window: panel, to: path + "-before.png")
                }
                Self.postKey(48, characters: "\t", to: panel)
                try? await Task.sleep(for: .milliseconds(400))
                print("[flow] Tab 后 level=\(router.level) text=\(router.text) calc=\(router.calcExpression) 输入框=\((router.keyField as? HUDKeyField)?.currentString ?? "nil")")
                if let path = debugEnv["MACTOOLS_DEBUG_SAVE_SCREEN"] {
                    try? HUDSnapshot.capture(window: panel, to: path + "-after.png")
                }
                exit(0)
            }
        } else if debugEnv["MACTOOLS_DEBUG_FLOW"] == "translate" {
            // 「⌥T 取词」链路自查：只跑取词本身（不触发授权弹窗），
            // 核对失败时归到哪一类原因（未授权 / 安全输入 / 真的没选中）。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                let permissions = environment.permissions
                print("[flow] accessibility=\(permissions.isAccessibilityTrusted) signature=\(permissions.codeSignatureKind) runFromTerminal=\(permissions.isRunFromTerminal) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
                let result = await TextSelectionService.readSelection()
                switch result {
                case .success(let text):
                    print("[flow] 取词成功，长度=\(text.count) 首行=\(text.split(separator: "\n").first.map(String.init) ?? "")")
                case .failure(let failure):
                    print("[flow] 取词失败 \(failure) → \(failure.errorDescription ?? "")")
                }
                exit(0)
            }
        } else if debugEnv["MACTOOLS_DEBUG_AUTOOPEN"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                environment.router.open()
                try? await Task.sleep(for: .milliseconds(700))
                self.dumpHUDSnapshot(environment)
            }
        }
        #endif
    }

    #if DEBUG
    /// 直接把 WindowServer 的窗口表打出来：分辨「窗口没上屏」和「整个屏幕列表都是空的」。
    static func dumpWindowServer() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        print("[ws] onScreen 窗口总数=\(onScreen.count)")
        for item in onScreen.prefix(12) {
            let bounds = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print("[ws]  #\(item[kCGWindowNumber as String] ?? 0) pid=\(item[kCGWindowOwnerPID as String] ?? 0) layer=\(item[kCGWindowLayer as String] ?? 0) bounds=\(bounds) owner=\(item[kCGWindowOwnerName as String] ?? "-")")
        }
        let mine = onScreen.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        print("[ws] 本进程 onScreen 窗口=\(mine.count)")
        for item in mine {
            let bounds = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print("[ws]  本进程 #\(item[kCGWindowNumber as String] ?? 0) layer=\(item[kCGWindowLayer as String] ?? 0) bounds=\(bounds) alpha=\(item[kCGWindowAlpha as String] ?? 0)")
        }
    }

    /// 合成按键：投进应用事件队列，让局部监视器 + 窗口派发完整走一遍（等同真实键盘）。
    static func postKey(
        _ keyCode: UInt16,
        characters: String,
        to window: NSWindow,
        flags: NSEvent.ModifierFlags = []
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: NSPoint(x: window.frame.midX, y: window.frame.midY),
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// 无 GUI 交互时的自检输出：确认面板确实上屏且拿到 key。
    @MainActor
    private func dumpHUDSnapshot(_ environment: AppEnvironment) {
        let panel = environment.panel
        print("=== HUD snapshot ===")
        print("screens:", NSScreen.screens.map { NSStringFromRect($0.frame) })
        print("level:", environment.router.level)
        print("panelVisible:", panel.isVisible)
        print("panelKey:", panel.isKeyWindow)
        print("panelFrame:", NSStringFromRect(panel.frame))
        print("alpha:", panel.alphaValue)
        print("firstResponder:", String(describing: panel.firstResponder))
        print("activeModule:", environment.router.currentModule?.rawValue ?? "none")
        print("text:", environment.router.text)
        print("====================")
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 设置写入是合并提交的（见 `SettingsStore.persist`）：退出前把还攒着的那几笔落库，
    /// 否则「改完设置立刻 ⌘Q」会丢掉最后 200ms 内的改动。
    func applicationWillTerminate(_ notification: Notification) {
        environment?.settings.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
