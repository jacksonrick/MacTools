import AppKit
import SwiftUI

/// 一次冻结的屏幕画面：`image.size` 与 `screen.frame.size` 一致（1pt = 1pt）。
struct ScreenCaptureShot {
    let screen: NSScreen
    let image: NSImage
}

/// 每屏一个无边框窗口，冻结画面 + 选区 + 就地标注。
///
/// 流程：拖选区域 → 松手即固定（选区内的冻结画面按 1:1 显示，可直接标注），
/// 工具条贴在选区下方（空间不够时移到上方）；↩ / ✓ 复制，⌘S 保存，Esc 取消。
/// 工具全部取消激活时可以拖动选区、拉边角改大小。
@MainActor
final class SelectionOverlay {

    enum FinishAction {
        case copy
        case save
    }

    private enum Phase {
        case selecting
        case annotating
    }

    private struct Suspended {
        let rect: NSRect
        let view: SelectionOverlayView
        let image: NSImage
        let model: AnnotationModel
    }

    enum FrameKind {
        case move
        case resize(FrameAnchor)
    }

    private struct FrameDrag {
        let kind: FrameKind
        let startRect: NSRect
        let startPoint: NSPoint
    }

    private var windows: [SelectionWindow] = []
    private let shots: [ScreenCaptureShot]

    private var activeView: SelectionOverlayView?
    private var selectionRect: NSRect = .zero
    private var dragOrigin: NSPoint = .zero
    private var isDragging = false
    /// 标注态下按在暗区的点：拖过阈值才重新框选，单纯点一下不闪。
    private var pendingPress: (point: NSPoint, view: SelectionOverlayView)?
    private var phase: Phase = .selecting
    private var suspended: Suspended?

    private var model: AnnotationModel?
    private var croppedImage: NSImage?
    private var canvasView: AnnotationCanvasView?
    private var toolbarHost: MouseFirstHostingView<ScreenshotToolbar>?
    private var toolbarSize: NSSize = NSSize(width: 451, height: 38)
    private var sizeBadge: SelectionSizeBadge?
    /// 角标最近一次量过的文本与尺寸（拖动选区时文本只有整数位在变，没必要每帧重新排版）。
    private var badgeMetrics: (text: String, size: NSSize)?
    private var frameLayer: [NSView] = []
    private var frameDrag: FrameDrag?

    private let onFinish: (FinishAction, NSImage) -> Void
    private let onCancel: () -> Void

    init(
        shots: [ScreenCaptureShot],
        onFinish: @escaping (FinishAction, NSImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.shots = shots
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    func show() {
        // 覆盖层是**非激活面板**（`.nonactivatingPanel`）：不抢应用激活，也不调用
        // `NSApp.activate()`。原因：激活是异步的，而且对 accessory 应用可能被系统拒绝。
        // 激活没跟上时窗口虽在屏上，却既不收键盘也不收第一次点击——就成了
        // 「回车好像没反应」「第一次拖拽没反应」。非激活面板可以直接成为 key，
        // 键盘（Esc / ⌘S / 打字）与鼠标都在同一次 runloop 里就可用。
        for shot in shots {
            let window = SelectionWindow(screen: shot.screen)
            let view = SelectionOverlayView(
                frame: NSRect(origin: .zero, size: shot.screen.frame.size),
                shot: shot.image
            )
            view.overlay = self
            window.contentView = view
            windows.append(window)
            window.setFrame(shot.screen.frame, display: true)
            window.orderFrontRegardless()
        }
        let key = windows.first { $0.screen == PanelPositioner.activeScreen() } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        key?.makeKey()
    }

    func hide() {
        removeAnnotationUI()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        activeView = nil
        model = nil
        croppedImage = nil
        suspended = nil
        pendingPress = nil
        frameDrag = nil
    }

    // MARK: - 鼠标（选区阶段）

    fileprivate func mouseDown(at point: NSPoint, in view: SelectionOverlayView) {
        activeView = view

        if phase == .annotating {
            // 工具条自己的点击交给 SwiftUI；命中失败也不能把截图状态弄丢。
            if toolbarHost?.frame.contains(point) == true { return }
            // 选区内部归画布 / 元素选中处理。
            if selectionRect.contains(point) { return }
            pendingPress = (point, view)
            return
        }

        beginSelection(at: point, in: view)
    }

    fileprivate func mouseDragged(to point: NSPoint) {
        if let pending = pendingPress {
            guard hypot(point.x - pending.point.x, point.y - pending.point.y) > 3 else { return }
            pendingPress = nil
            suspendAnnotations()
            beginSelection(at: pending.point, in: pending.view)
        }
        guard isDragging else { return }
        selectionRect = NSRect(
            x: min(dragOrigin.x, point.x),
            y: min(dragOrigin.y, point.y),
            width: abs(point.x - dragOrigin.x),
            height: abs(point.y - dragOrigin.y)
        )
        layoutBadge()
        refresh()
    }

    fileprivate func mouseUp() {
        if pendingPress != nil {
            pendingPress = nil
            return
        }
        guard isDragging else { return }
        isDragging = false

        guard selectionRect.width >= 4, selectionRect.height >= 4, let view = activeView else {
            restoreSuspended()
            return
        }

        suspended = nil
        guard let cropped = Self.crop(view.shot, to: selectionRect, in: view.bounds) else {
            cancel()
            return
        }
        croppedImage = cropped
        // 马赛克底图不在这里算：CIPixellate 要几十毫秒，会让「松手出画布」顿一下。
        // 真正用到马赛克笔刷时再按需生成。
        let model = AnnotationModel(image: cropped)
        self.model = model
        phase = .annotating
        mountAnnotationUI(in: view, rect: selectionRect, model: model)
        layoutBadge()
        refresh()
    }

    fileprivate func cancel() {
        hide()
        onCancel()
    }

    // MARK: - 选区状态

    private func beginSelection(at point: NSPoint, in view: SelectionOverlayView) {
        activeView = view
        isDragging = true
        dragOrigin = point
        selectionRect = .zero
        layoutBadge()
        refresh()
    }

    /// 在暗区重新拖选：先把标注层收起来，拖不够长再原样放回去。
    private func suspendAnnotations() {
        guard phase == .annotating, let model, let image = croppedImage,
              let view = activeView else { return }
        suspended = Suspended(rect: selectionRect, view: view, image: image, model: model)
        removeAnnotationUI()
        phase = .selecting
    }

    private func restoreSuspended() {
        guard let state = suspended else {
            if phase == .selecting { cancel() }
            return
        }
        suspended = nil
        activeView = state.view
        phase = .annotating
        selectionRect = state.rect
        croppedImage = state.image
        model = state.model
        mountAnnotationUI(in: state.view, rect: state.rect, model: state.model)
        layoutBadge()
        refresh()
    }

    // MARK: - 标注层

    private func mountAnnotationUI(
        in view: SelectionOverlayView,
        rect: NSRect,
        model: AnnotationModel
    ) {
        removeAnnotationUI()

        let canvas = AnnotationCanvasView(model: model)
        canvas.overlay = self
        canvas.onToolChange = { [weak self] in self?.syncFrameMode() }
        canvas.frame = rect
        view.addSubview(canvas)
        canvasView = canvas

        let toolbar = MouseFirstHostingView(rootView: ScreenshotToolbar(
            model: model,
            onToolChange: { [weak self] in self?.syncFrameMode() },
            onCopy: { [weak self] in self?.finish(.copy) },
            onSave: { [weak self] in self?.finish(.save) },
            onCancel: { [weak self] in self?.cancel() }
        ))
        view.addSubview(toolbar)
        toolbarHost = toolbar

        measureToolbar()
        layoutToolbar()
        syncFrameMode()
        layoutBadge()
    }

    /// 工具条尺寸只在内容布局结算后量一次。
    /// 之前每次拖动都调 `layoutSubtreeIfNeeded` + `fittingSize`，
    /// SwiftUI 布局在拖拽循环里反复跑，手感直接烂掉。
    private func measureToolbar() {
        guard let toolbarHost else { return }
        toolbarHost.layoutSubtreeIfNeeded()
        let size = toolbarHost.fittingSize
        toolbarSize = NSSize(width: max(size.width, 240), height: max(size.height, 38))
    }

    private var toolbarFittingSize: NSSize { toolbarSize }

    private func removeAnnotationUI() {
        removeFrameLayer()
        canvasView?.removeFromSuperview()
        canvasView = nil
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
        sizeBadge?.removeFromSuperview()
        sizeBadge = nil
    }

    private static func toolbarOrigin(for size: NSSize, selection: NSRect, bounds: NSRect) -> NSPoint {
        let gap: CGFloat = 10
        var y = selection.minY - gap - size.height
        if y < 8 {
            y = selection.maxY + gap
        }
        if y + size.height > bounds.maxY - 8 {
            y = max(8, bounds.maxY - size.height - 8)
        }
        let x = min(
            max(selection.midX - size.width / 2, 8),
            max(bounds.maxX - size.width - 8, 8)
        )
        return NSPoint(x: x, y: y)
    }

    private func layoutToolbar() {
        positionToolbar()
        // SwiftUI 的布局下一轮才结算：首次挂载后再量一次，之后拖拽只挪位置不再重排。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            self.measureToolbar()
            self.positionToolbar()
        }
    }

    private func positionToolbar() {
        guard let toolbarHost, let view = activeView else { return }
        let frame = NSRect(
            origin: Self.toolbarOrigin(for: toolbarSize, selection: selectionRect, bounds: view.bounds),
            size: toolbarSize
        )
        guard toolbarHost.frame != frame else { return }
        toolbarHost.frame = frame
    }

    /// 右下角常显的分辨率（按真实像素算，Retina 下是 2 倍点值）。
    private func layoutBadge() {
        guard let view = activeView else { return }
        guard selectionRect.width >= 1, selectionRect.height >= 1 else {
            sizeBadge?.isHidden = true
            return
        }
        // 框选阶段还没有标注层，角标在这里按需创建。
        let badge: SelectionSizeBadge
        if let existing = sizeBadge {
            badge = existing
        } else {
            let created = SelectionSizeBadge()
            view.addSubview(created, positioned: .above, relativeTo: nil)
            sizeBadge = created
            badge = created
        }
        badge.isHidden = false
        let scale = view.pixelScale
        let text = "\(Int((selectionRect.width * scale).rounded())) × \(Int((selectionRect.height * scale).rounded()))"
        // 拖动选区时这个方法跟着每个鼠标事件跑，而文本只有整数位在变：
        // 同一个字符串就不要重新量一遍排版（`size(for:)` 每次都要建属性字典 + 走文本测量）。
        let size: NSSize
        if let cached = badgeMetrics, cached.text == text {
            size = cached.size
        } else {
            size = SelectionSizeBadge.size(for: text)
            badgeMetrics = (text, size)
        }
        badge.text = text
        let inset: CGFloat = 8
        var origin = NSPoint(x: selectionRect.maxX - size.width - inset, y: selectionRect.minY + inset)
        if selectionRect.width < size.width + inset * 2 {
            origin.x = selectionRect.maxX + 6
        }
        if selectionRect.height < size.height + inset * 2 {
            origin.y = selectionRect.minY - size.height - 6
        }
        origin.x = min(max(origin.x, 4), view.bounds.maxX - size.width - 4)
        origin.y = min(max(origin.y, 4), view.bounds.maxY - size.height - 4)
        badge.frame = NSRect(origin: origin, size: size)
    }

    /// 从整屏冻结画面里裁出选区（视图坐标左下原点，CGImage 左上原点）。
    static func crop(_ image: NSImage, to rect: NSRect, in bounds: NSRect) -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let scaleX = CGFloat(cgImage.width) / bounds.width
        let scaleY = CGFloat(cgImage.height) / bounds.height
        let pixelRect = CGRect(
            x: rect.minX * scaleX,
            y: (bounds.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    // MARK: - 选区调整（工具全部取消激活时）

    /// 工具为 nil 时在选区边框上装八个手柄；画布自己负责内部（选元素 / 拖元素 / 拖选区），
    /// 所以不再需要压住画布的整块手势层——那层正是「点了元素却拖不动」的元凶。
    private func syncFrameMode() {
        guard phase == .annotating, let view = activeView, let model else {
            removeFrameLayer()
            return
        }
        if model.tool == nil {
            model.clearSelection()
            installFrameLayer(in: view, rect: selectionRect)
        } else {
            removeFrameLayer()
        }
        layoutToolbar()
    }

    private func installFrameLayer(in view: SelectionOverlayView, rect: NSRect) {
        removeFrameLayer()
        guard rect.width > 2, rect.height > 2 else { return }

        for anchor in FrameAnchor.allCases {
            let handle = FrameHandleView(anchor: anchor)
            handle.overlay = self
            handle.frame = anchor.frame(in: rect)
            view.addSubview(handle, positioned: .above, relativeTo: canvasView)
            frameLayer.append(handle)
        }

        if let toolbarHost {
            view.addSubview(toolbarHost, positioned: .above, relativeTo: nil)
        }
        if let sizeBadge {
            view.addSubview(sizeBadge, positioned: .above, relativeTo: nil)
        }
    }

    private func removeFrameLayer() {
        for view in frameLayer {
            view.removeFromSuperview()
        }
        frameLayer.removeAll()
        frameDrag = nil
    }

    func beginFrameDrag(_ kind: FrameKind, at point: NSPoint) {
        guard phase == .annotating else { return }
        frameDrag = FrameDrag(kind: kind, startRect: selectionRect, startPoint: point)
        if case .move = kind { NSCursor.closedHand.set() }
    }

    func updateFrameDrag(to point: NSPoint, in view: SelectionOverlayView) {
        guard let drag = frameDrag else { return }
        let dx = point.x - drag.startPoint.x
        let dy = point.y - drag.startPoint.y
        let bounds = view.bounds

        var rect: NSRect
        switch drag.kind {
        case .move:
            rect = drag.startRect.offsetBy(dx: dx, dy: dy)
            if rect.minX < 0 { rect.origin.x = 0 }
            if rect.minY < 0 { rect.origin.y = 0 }
            if rect.maxX > bounds.maxX { rect.origin.x = bounds.maxX - rect.width }
            if rect.maxY > bounds.maxY { rect.origin.y = bounds.maxY - rect.height }
        case .resize(let anchor):
            rect = anchor.applied(to: drag.startRect, dx: dx, dy: dy, minSize: 16)
            rect.origin.x = max(0, rect.origin.x)
            rect.origin.y = max(0, rect.origin.y)
            rect.size.width = min(rect.width, bounds.maxX - rect.minX)
            rect.size.height = min(rect.height, bounds.maxY - rect.minY)
        }
        applyFrame(rect)
    }

    func endFrameDrag() {
        frameDrag = nil
        guard let image = croppedImage else { return }
        // 只有真的打过马赛克才重算底图：大区域 CIPixellate 要几十毫秒，白算松手会顿一下。
        let hasMosaic = model?.shapes.contains { shape in
            if case .mosaic = shape.kind { return true }
            return false
        } ?? false
        guard hasMosaic else { return }
        model?.pixelated = MosaicProcessor.pixelate(image)
    }

    /// 选区变化：重新裁剪底图、跟着挪画布 / 工具条 / 分辨率角标。
    private func applyFrame(_ rect: NSRect) {
        guard let view = activeView, let model, rect.width >= 8, rect.height >= 8 else { return }
        guard let cropped = Self.crop(view.shot, to: rect, in: view.bounds) else { return }

        selectionRect = rect
        croppedImage = cropped
        model.image = cropped
        model.pixelated = nil

        canvasView?.frame = rect
        for subview in frameLayer {
            if let handle = subview as? FrameHandleView {
                handle.frame = handle.anchor.frame(in: rect)
            } else {
                subview.frame = rect
            }
        }
        positionToolbar()
        layoutBadge()
        refresh()
    }

    // MARK: - 完成 / 键盘

    private func finish(_ action: FinishAction) {
        guard phase == .annotating, let image = croppedImage else { return }
        model?.finishTextEditing()
        let rendered: NSImage
        if let model, !model.isEmpty {
            rendered = AnnotationRenderer.render(image: image, model: model) ?? image
        } else {
            rendered = image
        }
        hide()
        onFinish(action, rendered)
    }

    fileprivate func handleKey(_ event: NSEvent, editingText: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                model?.undo()
                return phase == .annotating
            case "c":
                guard phase == .annotating else { return false }
                finish(.copy)
                return true
            case "s":
                guard phase == .annotating else { return false }
                finish(.save)
                return true
            default:
                return false
            }
        }

        switch event.keyCode {
        case 53:                    // Esc
            cancel()
            return true
        case 51, 117:               // ⌫ / ⌦：删除选中的元素
            guard phase == .annotating, !editingText, model?.hasSelection == true else { return false }
            model?.deleteSelection()
            return true
        case 36, 76:                // ↩
            guard phase == .annotating else { return false }
            finish(.copy)
            return true
        default:
            guard phase == .annotating, !editingText,
                  let characters = event.charactersIgnoringModifiers?.lowercased(),
                  let tool = AnnotationTool.tool(forKey: characters) else { return false }
            model?.tool = model?.tool == tool ? nil : tool
            syncFrameMode()
            return true
        }
    }

    // MARK: - 重绘

    private func refresh() {
        for window in windows {
            guard let view = window.contentView as? SelectionOverlayView else { continue }
            view.selectionRect = (view === activeView) ? selectionRect : .zero
            view.needsDisplay = true
        }
    }

    #if DEBUG
    /// 自检：压暗后的底图必须是不透明位图。
    static func debugDimmedImage(_ shot: NSImage) -> NSImage { OverlayBackdropView.debugDimmed(shot) }

    var debugWindows: [NSWindow] { windows }
    var debugWindowCount: Int { windows.count }
    /// 每秒刷一次的实时状态：区分「窗口被 orderOut」「跑到别的 Space」「被挡住」。
    var debugLiveState: String {
        windows.map {
            "visible=\($0.isVisible) activeSpace=\($0.isOnActiveSpace) key=\($0.isKeyWindow) occlusionVisible=\($0.occlusionState.contains(.visible)) level=\($0.level.rawValue) frame=\(NSStringFromRect($0.frame)) alpha=\($0.alphaValue) num=\($0.windowNumber)"
        }.joined(separator: " | ")
    }

    /// 冻结的整屏原图：用来核对「浮窗有没有被拍进去」。
    var debugFirstShot: NSImage? { shots.first?.image }
    var debugVisibility: String {
        windows.map {
            "visible=\($0.isVisible) alpha=\($0.alphaValue) level=\($0.level.rawValue) screen=\($0.screen != nil) occlusion=\($0.occlusionState.contains(.visible))"
        }.joined(separator: " | ")
    }

    /// WindowServer 视角：窗口是否真的合成到屏幕上。
    /// `isVisible` 只说明 AppKit 认为它 ordered in，看不到时得靠这份数据区分
    /// 「窗口根本没上屏」和「上屏了但用户看不见」。
    var debugWindowServerState: String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let numbers = Set(windows.map(\.windowNumber))
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let ours = all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        let onScreenCount = ours.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }.count
        let detail = ours.map { item in
            let bounds = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let number = item[kCGWindowNumber as String] as? Int ?? -1
            return "#\(number)\(numbers.contains(number) ? "*" : "") layer=\(item[kCGWindowLayer as String] ?? 0) onscreen=\(item[kCGWindowIsOnscreen as String] ?? "?") alpha=\(item[kCGWindowAlpha as String] ?? 0) bounds=\(bounds)"
        }.joined(separator: " || ")
        return "我们的窗口 onScreen=\(onScreenCount)/\(ours.count) ｜ \(detail)"
    }

    /// 无鼠标环境下的版式自查：直接固定一个选区并进入标注态。
    func debugFixSelection(_ rect: NSRect, tool: AnnotationTool? = .rectangle) {
        guard let window = windows.first(where: { $0.screen == NSScreen.main }) ?? windows.first,
              let view = window.contentView as? SelectionOverlayView else { return }
        activeView = view
        selectionRect = rect
        guard let cropped = Self.crop(view.shot, to: rect, in: view.bounds) else { return }

        let model = AnnotationModel(image: cropped)
        model.tool = tool
        model.shapes.append(AnnotationShape(
            kind: .rectangle(CGRect(x: 40, y: 40, width: 160, height: 90)),
            color: .red,
            lineWidth: 3
        ))
        model.shapes.append(AnnotationShape(
            kind: .arrow(start: CGPoint(x: 240, y: 60), end: CGPoint(x: 360, y: 150)),
            color: .yellow,
            lineWidth: 3
        ))
        model.addText(at: CGPoint(x: 120, y: 190))
        model.texts[0].text = "就地标注"
        model.selection = model.shapes[0].id
        if tool == .text {
            model.selection = model.texts[0].id
            model.textTier = .medium
        }

        croppedImage = cropped
        self.model = model
        phase = .annotating
        mountAnnotationUI(in: view, rect: rect, model: model)
        layoutBadge()
        refresh()

        // 命中测试自查：选区中心必须落到画布、工具条中心必须落到工具条。
        if let canvasView {
            let hit = view.hitTest(NSPoint(x: rect.midX, y: rect.midY))
            Log.trace("[annotate] 选区中心命中画布：\(hit === canvasView)")
        }
        if let toolbarHost {
            let center = NSPoint(x: toolbarHost.frame.midX, y: toolbarHost.frame.midY)
            // 边缘留白处也必须命中工具条，否则点空会被覆盖层当成「重新框选」，截图就丢了。
            let padding = NSPoint(x: toolbarHost.frame.minX + 3, y: toolbarHost.frame.midY)
            Log.trace("[annotate] 工具条中心命中工具条：\(view.hitTest(center) === toolbarHost)，留白处：\(view.hitTest(padding) === toolbarHost)，尺寸 \(toolbarHost.frame.size)")
        }
        Log.trace("[annotate] 分辨率角标：\(sizeBadge.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "无")")

        // 回归自查：点在工具条 / 选区内部都不能把截图状态弄丢（旧版本会被当成重新框选）。
        if let toolbarHost {
            let beforeRect = selectionRect
            mouseDown(at: NSPoint(x: toolbarHost.frame.midX, y: toolbarHost.frame.midY), in: view)
            mouseUp()
            mouseDown(at: NSPoint(x: rect.midX, y: rect.midY), in: view)
            mouseUp()
            Log.trace("[annotate] 点工具条/选区不丢截图：\(croppedImage != nil && phase == .annotating && selectionRect == beforeRect)")
        }
    }
    #endif
}

// MARK: - 选区边框手柄

enum FrameAnchor: CaseIterable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    private var isLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    private var isRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    private var isTop: Bool { self == .topLeft || self == .top || self == .topRight }
    private var isBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// 手柄热区（视图坐标，左下原点）。
    func frame(in rect: NSRect) -> NSRect {
        let thickness: CGFloat = 12
        let corner: CGFloat = 16
        let minLength: CGFloat = 8
        let length = max(rect.width - corner * 2, minLength)
        let height = max(rect.height - corner * 2, minLength)

        switch self {
        case .topLeft:
            return NSRect(x: rect.minX - 6, y: rect.maxY - 6, width: corner, height: corner)
        case .topRight:
            return NSRect(x: rect.maxX - corner + 6, y: rect.maxY - 6, width: corner, height: corner)
        case .bottomLeft:
            return NSRect(x: rect.minX - 6, y: rect.minY - 6, width: corner, height: corner)
        case .bottomRight:
            return NSRect(x: rect.maxX - corner + 6, y: rect.minY - 6, width: corner, height: corner)
        case .top:
            return NSRect(x: rect.minX + corner, y: rect.maxY - thickness / 2, width: length, height: thickness)
        case .bottom:
            return NSRect(x: rect.minX + corner, y: rect.minY - thickness / 2, width: length, height: thickness)
        case .left:
            return NSRect(x: rect.minX - thickness / 2, y: rect.minY + corner, width: thickness, height: height)
        case .right:
            return NSRect(x: rect.maxX - thickness / 2, y: rect.minY + corner, width: thickness, height: height)
        }
    }

    /// 手柄光标：边是双箭头，角是斜向双箭头（见 `ResizeCursor`）。
    var cursor: NSCursor {
        switch self {
        case .topLeft: ResizeCursor.topLeft
        case .top: ResizeCursor.top
        case .topRight: ResizeCursor.topRight
        case .left: ResizeCursor.left
        case .right: ResizeCursor.right
        case .bottomLeft: ResizeCursor.bottomLeft
        case .bottom: ResizeCursor.bottom
        case .bottomRight: ResizeCursor.bottomRight
        }
    }

    func applied(to rect: NSRect, dx: CGFloat, dy: CGFloat, minSize: CGFloat) -> NSRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if isLeft { minX += dx }
        if isRight { maxX += dx }
        if isTop { maxY += dy }
        if isBottom { minY += dy }

        if maxX - minX < minSize {
            if isLeft { minX = maxX - minSize } else { maxX = minX + minSize }
        }
        if maxY - minY < minSize {
            if isBottom { minY = maxY - minSize } else { maxY = minY + minSize }
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private final class FrameHandleView: NSView {
    weak var overlay: SelectionOverlay?
    let anchor: FrameAnchor

    init(anchor: FrameAnchor) {
        self.anchor = anchor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: anchor.cursor)
    }

    /// 画一个小圆点：角上手柄点在自己的中心，边上手柄点就是边的中点。
    override func draw(_ dirtyRect: NSRect) {
        let dot: CGFloat = 8
        let rect = NSRect(
            x: bounds.midX - dot / 2,
            y: bounds.midY - dot / 2,
            width: dot,
            height: dot
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = pointInOverlay(event) else { return }
        overlay?.beginFrameDrag(.resize(anchor), at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview as? SelectionOverlayView,
              let point = pointInOverlay(event) else { return }
        overlay?.updateFrameDrag(to: point, in: parent)
    }

    override func mouseUp(with event: NSEvent) {
        overlay?.endFrameDrag()
    }
}

/// 手势层的点必须换算到覆盖层视图的坐标系，判据（选区 / 屏幕边界）才一致。
private extension NSView {
    func pointInOverlay(_ event: NSEvent) -> NSPoint? {
        guard let overlayView = superview as? SelectionOverlayView else { return nil }
        return overlayView.convert(event.locationInWindow, from: nil)
    }
}

// MARK: - 分辨率角标

/// 选区右下角常显的像素分辨率。不吃鼠标事件。
private final class SelectionSizeBadge: NSView {
    var text: String = "" {
        didSet {
            guard oldValue != text else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 属性字典建一次就够（原来每次测量都新建一个字典 + 查一次字体）。
    static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]

    static func size(for text: String) -> NSSize {
        let size = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: size.width + 12, height: size.height + 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: NSPoint(x: 6, y: 3), withAttributes: Self.attributes)
    }
}

// MARK: - 窗口 / 视图

/// 无边框面板：可以成为 key（接收 Esc / ⌘S / 文字输入），但不会成为 main，
/// 也不会出现在窗口菜单里。
private final class SelectionWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionOverlayView: NSView {
    weak var overlay: SelectionOverlay?
    let shot: NSImage
    private let backdrop: OverlayBackdropView

    var selectionRect: NSRect = .zero {
        didSet {
            backdrop.selectionRect = selectionRect
            needsDisplay = true
        }
    }

    init(frame: NSRect, shot: NSImage) {
        self.shot = shot
        self.backdrop = OverlayBackdropView(frame: NSRect(origin: .zero, size: frame.size), shot: shot)
        super.init(frame: frame)
        wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    /// 冻结画面的像素倍率（Retina 下为 2）。
    var pixelScale: CGFloat {
        guard bounds.width > 0,
              let cgImage = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        return max(1, CGFloat(cgImage.width) / bounds.width)
    }

    override var acceptsFirstResponder: Bool { true }

    /// 非激活面板上，第一次点击会被系统当成「激活应用」而丢掉。
    /// 覆盖层必须吃下这一次点击，否则用户看到的就是「第一次拖拽毫无反应」。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }


    override func mouseDown(with event: NSEvent) {
        overlay?.mouseDown(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        overlay?.mouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        overlay?.mouseUp()
    }

    override func keyDown(with event: NSEvent) {
        if overlay?.handleKey(event, editingText: window?.firstResponder is NSTextView) == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 覆盖层底图

/// 冻结整屏画面 + 压暗 + 选区内还原亮度 + 选区边框。
///
/// 为什么必须是**子视图**、不能直接画在 `SelectionOverlayView` 身上：
/// 覆盖层视图自己当绘制宿主时，AppKit 给它的 backing 会**吃掉半透明像素**——
/// `alpha = 1` 的纯色画得出来，而任何 alpha < 1 的填充（35% 压暗层、
/// 2× 位图按 1:1 缩放绘制）都静默丢失。屏幕上看到的就是「什么都没发生」，
/// 但窗口明明已经在屏上、`draw` 也真的执行了（这几条实测过很多次）。
/// 同样一段绘制放进子视图完全正常——标注画布、工具条、八个手柄都是子视图，
/// 所以只有底图消失、标注反而正常，现象非常具有迷惑性。
private final class OverlayBackdropView: NSView {
    private let shot: NSImage
    /// 预先压暗好的整屏底图（**不透明**）。见 `dimmed(_:)` 的说明。
    private let dimmed: NSImage

    var selectionRect: NSRect = .zero {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, shot: NSImage) {
        self.shot = shot
        self.dimmed = Self.dimmed(shot)
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    /// 只负责画：鼠标一律让出去，命中由覆盖层顶层视图统一处理。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 把冻结画面压暗成一张**不透明**位图。
    ///
    /// 不能按常规做法「先画底图、再叠一层 35% 黑」：这个覆盖层窗口上
    /// **alpha < 1 的像素根本不会出现在屏幕上**（纯色 alpha=1 能画，
    /// 35% 压暗层与按 1:1 缩放的 2× 位图都静默消失）。压暗放到离屏位图里
    /// 用 multiply 做掉，落到屏幕上的就永远是不透明像素。
    ///
    /// 同一个坑还解释了「按了截图没反应」：窗口在屏上、`draw` 也真的执行，
    /// 但底图整片是半透明的，屏幕上看就是桌面原样 —— 只有子视图（标注画布、
    /// 工具条、手柄）看得见，于是现象变成「截图没出来，但标注能用」。
    private static func dimmed(_ shot: NSImage) -> NSImage {
        guard let cgImage = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return shot }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return shot }

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return shot }

        let started = CFAbsoluteTimeGetCurrent()
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cgImage, in: rect)
        // multiply 一层 65% 灰 = 亮度压到 65%，结果仍然不透明。
        // 0.36 的灰做 multiply：实测观感约等于「叠一层 35% 黑」。
        context.setBlendMode(.multiply)
        context.setFillColor(CGColor(red: 0.36, green: 0.36, blue: 0.36, alpha: 1))
        context.fill(rect)

        guard let output = context.makeImage() else { return shot }
        Log.trace(String(format: "[overlay] 底图压暗 %.1fms", (CFAbsoluteTimeGetCurrent() - started) * 1000))
        return NSImage(cgImage: output, size: shot.size)
    }

    #if DEBUG
    static func debugDimmed(_ shot: NSImage) -> NSImage { dimmed(shot) }
    #endif

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 冻结的整屏画面（已经压暗）+ 避免选区确定后底下的内容还在动。
        dimmed.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        guard selectionRect.width >= 1, selectionRect.height >= 1 else { return }

        // 选区里按 1:1 贴回原亮度（原图本身不透明）。
        shot.draw(
            in: selectionRect,
            from: selectionRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        border.stroke()
    }
}
