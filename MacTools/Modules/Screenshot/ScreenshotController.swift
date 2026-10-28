import AppKit
import ImageIO
import Observation
import ScreenCaptureKit
import UniformTypeIdentifiers

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@Observable
@MainActor
final class ScreenshotController {

    private(set) var lastImage: NSImage?

    @ObservationIgnored var onStatus: ((String) -> Void)?
    /// 抓屏失败时把浮窗叫回来并给出原因，而不是静默什么都不发生。
    @ObservationIgnored var onCaptureFailed: ((String) -> Void)?
    /// 最近一次失败原因（诊断打印用）
    @ObservationIgnored private var lastFailure: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let permissions: PermissionCoordinator
    @ObservationIgnored private var overlay: SelectionOverlay?
    /// 预热缓存：`SCShareableContent` 的枚举是最慢的一步（冷启动要一两秒），
    /// 挪到「Tab 激活截图」时就做掉，回车时只剩一次 captureImage。
    @ObservationIgnored private var cachedDisplays: [SCDisplay] = []
    /// 截图请求的兜底看门狗：1.6s 还没出覆盖层就判定失败并说明原因，绝不静默。
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    init(settings: SettingsStore, permissions: PermissionCoordinator) {
        self.settings = settings
        self.permissions = permissions
    }

    /// 启动时预热 ScreenCaptureKit。
    /// 首次 `SCShareableContent` 枚举要一两秒（进程刚起来、XPC 还没热），
    /// 不预热的话「回车 → 抓屏」第一次会空等甚至直接拿不到画面，看起来就像没触发。
    func warmUpIfAuthorized() {
        prepare()
    }

    /// 预热显示器列表（激活截图功能时调用，不抓图、不弹授权）。
    func prepare() {
        guard permissions.hasScreenRecording else { return }
        Task { @MainActor [weak self] in
            _ = await self?.displays()
        }
    }

    private func displays() async -> [SCDisplay] {
        if !cachedDisplays.isEmpty { return cachedDisplays }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedDisplays = content.displays
        } catch {
            lastFailure = error.localizedDescription
            cachedDisplays = []
        }
        return cachedDisplays
    }

    // MARK: - 捕获

    func beginCapture() {
        // 上一轮覆盖层如果还挂着（被系统收走、上一轮异常退出等），先清掉再开新的。
        // 否则这里的 guard 会静默吃掉本次请求，表现就是「点了截图没反应」。
        if let overlay {
            overlay.hide()
            self.overlay = nil
        }
        Log.trace("[capture] beginCapture 权限=\(permissions.hasScreenRecording) 已请求=\(permissions.didRequestScreenRecording)")
        scheduleWatchdog()

        if permissions.hasScreenRecording {
            presentSelectionOverlay()
            return
        }

        // 首次申请：系统面板本身会提示「退出并重新打开」，不必再叠一个自家弹窗。
        let alreadyRequested = permissions.didRequestScreenRecording
        if permissions.requestScreenRecordingIfNeeded() {
            presentSelectionOverlay()
            return
        }
        if alreadyRequested {
            // 申请过还是没拿到：多半是授权未对新进程生效，或签名变了导致旧授权失效。
            presentPermissionAlert()
        }
    }

    /// 先冻结每块屏幕，再上覆盖层：选区确定后直接在这张静止画面上就地标注，
    /// 不会出现「另开一个标注窗口」这一步。
    private func presentSelectionOverlay() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.overlay == nil else {
                Log.trace("[capture] 已有一层覆盖层在场，本次请求忽略")
                return
            }

            // 第一次抓屏有可能什么都拿不到（SCK 冷启动、显示器枚举还没就绪），
            // 直接重试一次，而不是静默返回让用户以为快捷键坏了。
            var shots: [ScreenCaptureShot] = []
            for attempt in 1...2 {
                self.lastFailure = nil
                shots = await self.captureScreens()
                if !shots.isEmpty { break }
                Log.trace("[capture] 第 \(attempt) 次抓屏没有拿到画面：\(self.lastFailure ?? "未知原因")")
                if attempt == 1 {
                    try? await Task.sleep(for: .milliseconds(260))
                }
            }

            guard !shots.isEmpty else {
                let reason = self.lastFailure ?? "未取到屏幕画面"
                self.onCaptureFailed?("截图失败：\(reason)")
                return
            }
            guard self.overlay == nil else { return }

            let overlay = SelectionOverlay(
                shots: shots,
                onFinish: { [weak self] action, image in
                    guard let self else { return }
                    self.overlay = nil
                    self.lastImage = image
                    switch action {
                    case .copy:
                        self.copyToPasteboard(image)
                        self.onStatus?("截图已复制到剪贴板")
                    case .save:
                        if let url = self.save(image) {
                            self.onStatus?("截图已保存到 \(url.path)")
                        }
                    }
                },
                onCancel: { [weak self] in
                    self?.overlay = nil
                }
            )
            self.overlay = overlay
            overlay.show()
            self.watchdog?.cancel()
            #if DEBUG
            // 覆盖层的诊断视图只在 DEBUG 编译（`debugVisibility` / `debugWindowServerState`），
            // 这两行也一起圈进来，Release 里连符号都不用留。
            Log.trace("[capture] 覆盖层已上屏 \(overlay.debugVisibility) appActive=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
            Log.trace("[capture] \(overlay.debugWindowServerState)")
            #endif
        }
    }

    /// 兜底看门狗：任何一条路被静默吞掉（权限、已有覆盖层、抓屏异常）都不该让用户面对「没反应」。
    /// 1.6s 还没上覆盖层就把浮窗叫回来并说明原因。
    private func scheduleWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, !Task.isCancelled, self.overlay == nil else { return }
            let reason = self.lastFailure ?? "未取到屏幕画面"
            Log.trace("[capture] 1.6s 后仍没有覆盖层，判定失败：\(reason)")
            self.onCaptureFailed?("截图失败：\(reason)")
        }
    }

    private func captureScreens() async -> [ScreenCaptureShot] {
        let started = CFAbsoluteTimeGetCurrent()
        let available = await displays()
        guard !available.isEmpty else {
            lastFailure = lastFailure ?? "系统未返回任何显示器"
            return []
        }

        var shots: [ScreenCaptureShot] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else {
                lastFailure = "无法读取屏幕标识"
                continue
            }
            guard let display = available.first(where: { $0.displayID == displayID }) else {
                // 缓存可能是插拔显示器之前的，清掉让下一次重试重新枚举。
                cachedDisplays = []
                lastFailure = "系统未返回显示器 \(displayID)"
                continue
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            // 注意：CGDisplayPixelsWide 在 Retina 的缩放模式里返回的是**逻辑点数**
            // （实测 1512×982，而面板实际是 3024×1964），照它抓会拿到 1x 的糊图。
            // 物理像素要用「逻辑尺寸 × backingScaleFactor」。
            let scale = max(1, screen.backingScaleFactor)
            configuration.width = Int((screen.frame.width * scale).rounded())
            configuration.height = Int((screen.frame.height * scale).rounded())
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.scalesToFit = false

            do {
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                Log.trace("[capture] \(displayID) request=\(configuration.width)×\(configuration.height) got=\(cgImage.width)×\(cgImage.height) points=\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                shots.append(ScreenCaptureShot(
                    screen: screen,
                    image: NSImage(cgImage: cgImage, size: screen.frame.size)
                ))
            } catch {
                lastFailure = error.localizedDescription
            }
        }
        Log.trace(String(format: "[capture] 抓屏总耗时 %.0fms，屏数 %d", (CFAbsoluteTimeGetCurrent() - started) * 1000, shots.count))
        return shots
    }

    /// 截图没有独立视图：注册成模块控制器，只为在「Tab 激活截图」时预热 SCK。
    /// 回车仍由路由统一派发给 `onStartScreenshot`。
    @MainActor
    final class Module: ModuleControlling {
        let moduleID: ModuleID = .screenshot
        private let controller: ScreenshotController

        init(controller: ScreenshotController) {
            self.controller = controller
        }

        func handle(_ key: HUDKey, router: HUDRouter) -> Bool { false }

        func didEnter(router: HUDRouter) {
            controller.prepare()
        }
    }

    #if DEBUG
    /// 版式自查：走真实抓屏链路拿到冻结画面。
    func debugCaptureShots() async -> [ScreenCaptureShot] {
        await captureScreens()
    }

    /// 「回车 → 抓屏 → 覆盖层上屏」链路自查。
    var debugOverlayWindowCount: Int { overlay?.debugWindowCount ?? 0 }
    var debugOverlayShot: NSImage? { overlay?.debugFirstShot }
    var debugOverlayState: String { overlay?.debugLiveState ?? "无覆盖层" }
    #endif

    // MARK: - 权限提示
    private func presentPermissionAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "屏幕录制权限尚未生效"

        var lines: [String] = ["在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 MacTools。"]
        let hints = permissions.screenRecordingHints
        if !hints.isEmpty {
            lines.append("")
            lines.append(contentsOf: hints.map { "• \($0)" })
        }
        lines.append("")
        lines.append("若刚重新构建过：先在系统设置里用「−」删掉列表中的 MacTools，再点一次截图重新授权。")
        alert.informativeText = lines.joined(separator: "\n")

        alert.addButton(withTitle: "重启 MacTools")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            permissions.relaunchApp()
        case .alertSecondButtonReturn:
            permissions.openScreenRecordingSettings()
        default:
            break
        }
    }

    // MARK: - 输出

    func copyToPasteboard(_ image: NSImage) {
        guard let png = Self.pngData(for: image) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    @discardableResult
    func save(_ image: NSImage) -> URL? {
        let directory = URL(fileURLWithPath: settings.screenshotDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            onStatus?("无法创建截图目录")
            return nil
        }

        let name = "Screenshot \(Self.fileNameFormatter.string(from: Date())).png"
        let url = directory.appendingPathComponent(name)

        guard let png = Self.pngData(for: image) else { return nil }
        do {
            try png.write(to: url)
            return url
        } catch {
            onStatus?("保存失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 文件名里的时间戳：`DateFormatter` 建一次要好几毫秒（还要查 locale / 解析格式串），
    /// 没必要每次保存都新建。
    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// 直接 CGImage → PNG（ImageIO）。
    ///
    /// 原来的 `tiffRepresentation` → `NSBitmapImageRep(data:)` → `.representation(.png)` 会先把
    /// 整张图**编码成 TIFF 再解码回来**，多花 ~7ms 和一份 6MB 左右的临时内存
    /// （3024×1964 实测：58.8ms vs 51.6ms），对大图是纯浪费。
    static func pngData(for image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
