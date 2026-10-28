import AppKit

/// 就地标注画布（AppKit 直绘）。
///
/// 为什么不用 SwiftUI `Canvas` + `NSHostingView`：
/// 拖拽 / 缩放时每一帧都要重画整张 Retina 底图，SwiftUI 的视图 diff 与宿主视图重排
/// 会慢半拍，手感上就是「不跟鼠标 + 抖动 + 拖影」。这里底图是一次 1:1 位图拷贝，
/// 标注用 `NSBezierPath` 同步描边，鼠标事件也在这个视图里处理，落点与画面同帧。
///
/// 约定：视图 `isFlipped`，坐标系与模型（图片坐标，左上原点）一致，
/// 且画布尺寸 = 选区尺寸、底图按 1:1 摆放，所以 `layout.scale` 通常就是 1。
final class AnnotationCanvasView: NSView {

    let model: AnnotationModel
    var onToolChange: (() -> Void)?
    weak var overlay: SelectionOverlay?

    private enum DragMode {
        case none
        case movingShape(UUID, base: AnnotationShapeKind, start: CGPoint)
        case movingText(UUID, base: CGPoint, start: CGPoint)
        case resizing(ElementSnapshot, ResizeHandle, start: CGPoint)
        case drawing(AnnotationTool, start: CGPoint)
        /// 未激活任何工具时空白处按下 = 拖动整个选区（交给覆盖层处理）
        case frameMove
    }

    private var drag: DragMode = .none
    private var draftKind: AnnotationShapeKind?
    private var penPoints: [CGPoint] = []

    private var editor: NSTextField?
    private var editingID: UUID?
    private var isSyncingEditor = false
    private var editorSyncTask: Task<Void, Never>?

    init(model: AnnotationModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override var isFlipped: Bool { true }
    /// 键盘始终留给覆盖层视图：Esc / ⌘S / ⌘Z 由它统一处理。
    override var acceptsFirstResponder: Bool { false }

    /// 覆盖层是非激活面板：不吃下「第一次点击」的话，用户第一次拖元素/画框会毫无反应。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 模型观察

    /// AppKit 没有 SwiftUI 的自动重绘：靠 Observation 跟踪模型，任何改动标记重绘。
    /// 注意 `onChange` 在 willSet 阶段回调（此时读被改的属性还是旧值）：
    /// 所以重绘标记当场做，而「建 / 拆文字输入框」这种要读新值的动作推迟一个回合。
    private func observeModel() {
        withObservationTracking {
            _ = model.image
            _ = model.pixelated
            _ = model.shapes
            _ = model.texts
            _ = model.selection
            _ = model.editingText
            _ = model.tool
            _ = model.colorIndex
            _ = model.textTier
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.observeModel()
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
                self.scheduleEditorSync()
            }
        }
    }

    /// 只有「输入框在」或「模型要求输入」时才需要同步，拖拽热路径不做多余调度。
    private func scheduleEditorSync() {
        guard editor != nil || model.editingText != nil else { return }
        editorSyncTask?.cancel()
        editorSyncTask = Task { @MainActor [weak self] in
            await Task.yield()
            self?.syncEditor()
        }
    }

    private var currentLayout: CanvasLayout {
        CanvasLayout(imageSize: model.imageSize, available: bounds.size)
    }

    private func overlayView() -> SelectionOverlayView? {
        superview as? SelectionOverlayView
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let layout = currentLayout
        let imageRect = CGRect(origin: layout.origin, size: layout.size)

        model.image.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        // 标注坐标是图片坐标：把 CTM 挪到图片原点并按 scale 缩放，之后一律用原值绘制。
        NSGraphicsContext.saveGraphicsState()
        let cg = context.cgContext
        cg.translateBy(x: imageRect.minX, y: imageRect.minY)
        cg.scaleBy(x: layout.scale, y: layout.scale)
        for shape in model.shapes {
            draw(shape)
        }
        if let draftKind {
            draw(AnnotationShape(kind: draftKind, color: model.color, lineWidth: model.lineWidth))
        }
        NSGraphicsContext.restoreGraphicsState()

        for item in model.texts where item.id != editingID {
            drawText(item, layout: layout)
        }

        drawBorder()
        drawSelection(layout: layout)
    }

    private func draw(_ shape: AnnotationShape) {
        NSColor(shape.color).setStroke()
        switch shape.kind {
        case .rectangle(let rect):
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.lineWidth = shape.lineWidth
            path.stroke()

        case .arrow(let start, let end):
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = shape.lineWidth
            path.lineCapStyle = .round
            path.stroke()

            let angle = atan2(end.y - start.y, end.x - start.x)
            let length: CGFloat = max(10, shape.lineWidth * 4)
            let spread: CGFloat = .pi / 7
            let head = NSBezierPath()
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
            head.lineWidth = shape.lineWidth
            head.lineCapStyle = .round
            head.stroke()

        case .pen(let points):
            let path = Self.bezierPath(points)
            path.lineWidth = shape.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .mosaic(let points):
            guard let pixelated = model.pixelated,
                  let cg = NSGraphicsContext.current?.cgContext else { return }
            let mask = Self.cgPath(points).copy(
                strokingWithWidth: max(shape.lineWidth, 14),
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
            cg.saveGState()
            cg.addPath(mask)
            cg.clip()
            pixelated.draw(
                in: CGRect(origin: .zero, size: model.imageSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.low]
            )
            cg.restoreGState()
        }
    }

    private func drawText(_ item: AnnotationTextItem, layout: CanvasLayout) {
        let box = textBox(item, layout: layout)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(item.fontSize * layout.scale, 1), weight: .semibold),
            .foregroundColor: NSColor(item.color),
        ]
        let text = item.text.isEmpty ? "文字" : item.text
        (text as NSString).draw(at: CGPoint(x: box.minX + 3, y: box.minY + 3), withAttributes: attributes)
    }

    private func textBox(_ item: AnnotationTextItem, layout: CanvasLayout) -> CGRect {
        let size = AnnotationModel.textSize(item)
        let rect = CGRect(
            x: item.position.x - size.width / 2,
            y: item.position.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        return layout.viewRect(rect)
    }

    private func drawBorder() {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawSelection(layout: CanvasLayout) {
        guard let id = model.selection, let box = model.bounds(of: id) else { return }
        let rect = layout.viewRect(box)

        let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        if model.editingText != id {
            frame.setLineDash([4, 3], count: 2, phase: 0)
        }
        NSColor.controlAccentColor.setStroke()
        frame.stroke()

        // 文字只改字号，不给缩放手柄
        guard !model.isText(id), model.editingText != id else { return }
        for handle in ResizeHandle.allCases {
            drawHandle(at: handle.point(in: rect))
        }
    }

    private func drawHandle(at point: CGPoint) {
        let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        border.stroke()
    }

    static func bezierPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        if points.count == 1 {
            path.line(to: CGPoint(x: first.x + 0.5, y: first.y + 0.5))
        }
        return path
    }

    static func cgPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y + 0.5))
        }
        return path
    }

    // MARK: - 光标

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == nil ? .openHand : .crosshair)
        guard let id = model.selection, !model.isText(id), let box = model.bounds(of: id) else { return }
        let rect = currentLayout.viewRect(box)
        for handle in ResizeHandle.allCases {
            let point = handle.point(in: rect)
            addCursorRect(CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18), cursor: handle.cursor)
        }
    }

    // MARK: - 鼠标

    private func hitHandle(at point: CGPoint, in box: CGRect) -> ResizeHandle? {
        for handle in ResizeHandle.allCases {
            let center = handle.point(in: box)
            if abs(point.x - center.x) <= 9, abs(point.y - center.y) <= 9 {
                return handle
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        beginDrag(at: convert(event.locationInWindow, from: nil), doubleClick: event.clickCount >= 2)
    }

    override func mouseDragged(with event: NSEvent) {
        continueDrag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    // MARK: - 拖拽状态机（视图坐标入参，便于自检直接驱动）

    /// 视图坐标 → 覆盖层坐标（画布翻转，覆盖层不翻转，必须转换）。
    private func overlayPoint(fromViewPoint point: CGPoint) -> CGPoint {
        guard let parent = superview else { return .zero }
        return parent.convert(point, from: self)
    }

    func beginDrag(at viewPoint: CGPoint, doubleClick: Bool = false) {
        // 点画布不该抢走键盘：Esc / ⌘S / ⌘Z 都靠覆盖层视图的 keyDown。
        if let parent = overlayView(), window?.firstResponder !== parent {
            window?.makeFirstResponder(parent)
        }

        let point = currentLayout.imagePoint(from: viewPoint, imageSize: model.imageSize)

        // 双击文字 → 进入输入
        if doubleClick, let hit = model.hitTest(point), model.isText(hit) {
            model.select(hit)
            model.editingText = hit
            onToolChange?()
            beginEditing(hit)
            return
        }

        // 1. 已选中元素的缩放手柄优先（否则贴边的元素会抢走手柄）
        if let id = model.selection, !model.isText(id), let box = model.bounds(of: id),
           let handle = hitHandle(at: point, in: box), let snapshot = model.snapshot(id) {
            drag = .resizing(snapshot, handle, start: point)
            return
        }

        // 2. 按在已有元素上：选中并拖动
        if let hit = model.hitTest(point) {
            model.select(hit)
            onToolChange?()
            if let kind = model.shape(hit)?.kind {
                drag = .movingShape(hit, base: kind, start: point)
                NSCursor.closedHand.set()
            } else if let item = model.text(hit) {
                drag = .movingText(hit, base: item.position, start: point)
                NSCursor.closedHand.set()
            }
            return
        }

        // 3. 空白处
        if let editing = editingID {
            finishEditing(editing)
        }
        model.clearSelection()

        guard let tool = model.tool else {
            // 未激活工具：拖动整个选区（移动 / 靠边上的手柄改大小）
            drag = .frameMove
            overlay?.beginFrameDrag(.move, at: overlayPoint(fromViewPoint: viewPoint))
            NSCursor.closedHand.set()
            return
        }

        if tool == .text {
            model.beginText(at: point)
            onToolChange?()
            drag = .none
            if let id = model.editingText {
                beginEditing(id)
            }
            return
        }

        drag = .drawing(tool, start: point)
        penPoints = [point]
        draftKind = nil
        if tool == .mosaic {
            ensurePixelated()
        }
    }

    /// 马赛克底图按需生成：调整选区时会被清空（每帧重算太贵），
    /// 真正要画马赛克的那一刻补一次即可。
    private func ensurePixelated() {
        guard model.pixelated == nil else { return }
        model.pixelated = MosaicProcessor.pixelate(model.image)
    }

    func continueDrag(to viewPoint: CGPoint) {
        let point = currentLayout.imagePoint(from: viewPoint, imageSize: model.imageSize)
        switch drag {
        case .none:
            break

        case .frameMove:
            if let parent = overlayView() {
                overlay?.updateFrameDrag(to: overlayPoint(fromViewPoint: viewPoint), in: parent)
            }

        case .movingShape(let id, let base, let start):
            model.move(id, from: base, by: CGSize(width: point.x - start.x, height: point.y - start.y))

        case .movingText(let id, let base, let start):
            model.moveText(id, from: base, by: CGSize(width: point.x - start.x, height: point.y - start.y))

        case .resizing(let snapshot, let handle, let start):
            let dx = point.x - start.x
            let dy = point.y - start.y
            // 只是点一下（还没拖）不改几何：按下瞬间不动任何尺寸
            guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return }
            model.resize(snapshot, to: handle.applied(to: snapshot.bounds, dx: dx, dy: dy, minSize: 12))

        case .drawing(let tool, let start):
            switch tool {
            case .rectangle:
                draftKind = .rectangle(CGRect(
                    x: min(start.x, point.x),
                    y: min(start.y, point.y),
                    width: abs(point.x - start.x),
                    height: abs(point.y - start.y)
                ))
            case .arrow:
                draftKind = .arrow(start: start, end: point)
            case .pen, .mosaic:
                penPoints.append(point)
                draftKind = tool == .pen ? .pen(points: penPoints) : .mosaic(points: penPoints)
            case .text:
                break
            }
            needsDisplay = true
        }
    }

    /// 结束一次拖拽；返回是否真的改动了选区（供自检断言）。
    @discardableResult
    func endDrag() -> Bool {
        var movedFrame = false
        switch drag {
        case .frameMove:
            movedFrame = true
            overlay?.endFrameDrag()
            NSCursor.openHand.set()
        case .drawing:
            commitDraft()
        default:
            break
        }
        drag = .none
        draftKind = nil
        penPoints = []
        return movedFrame
    }

    private func commitDraft() {
        guard let kind = draftKind else { return }
        switch kind {
        case .rectangle(let rect):
            guard rect.width >= 3, rect.height >= 3 else { return }
        case .arrow(let start, let end):
            guard abs(end.x - start.x) >= 3 || abs(end.y - start.y) >= 3 else { return }
        case .pen(let points), .mosaic(let points):
            guard points.count >= 2 else { return }
        }
        model.shapes.append(AnnotationShape(kind: kind, color: model.color, lineWidth: model.lineWidth))
        model.selection = nil
    }

    // MARK: - 文字输入

    private func syncEditor() {
        guard let id = model.editingText else {
            if editingID != nil {
                removeEditor()
                needsDisplay = true
            }
            return
        }
        if editingID != id {
            beginEditing(id)
        } else {
            layoutEditor()
        }
    }

    private func beginEditing(_ id: UUID) {
        guard let item = model.text(id) else { return }
        removeEditor()

        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.usesSingleLineMode = true
        field.font = NSFont.systemFont(ofSize: max(item.fontSize * currentLayout.scale, 1), weight: .semibold)
        field.textColor = NSColor(item.color)
        field.stringValue = item.text
        field.delegate = self
        addSubview(field)
        editor = field
        editingID = id
        layoutEditor()
        window?.makeFirstResponder(field)
        if let fieldEditor = field.currentEditor() {
            fieldEditor.selectedRange = NSRange(location: (item.text as NSString).length, length: 0)
        }
    }

    private func layoutEditor() {
        guard let field = editor, let id = editingID, let item = model.text(id) else { return }
        let layout = currentLayout
        let box = textBox(item, layout: layout)
        let width = max(box.width, 60)
        let height = max(box.height, item.fontSize * layout.scale * 1.4)
        field.font = NSFont.systemFont(ofSize: max(item.fontSize * layout.scale, 1), weight: .semibold)
        field.frame = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    /// 收尾一次文字输入：写回内容、丢掉空项、把键盘还给覆盖层。
    private func finishEditing(_ id: UUID) {
        guard editingID == id else { return }
        let text = editor?.stringValue ?? ""
        removeEditor()
        if let index = model.texts.firstIndex(where: { $0.id == id }) {
            model.texts[index].text = text.replacingOccurrences(of: "\n", with: " ")
        }
        model.finishTextEditing()
        if let parent = overlayView() {
            window?.makeFirstResponder(parent)
        }
        needsDisplay = true
    }

    private func removeEditor() {
        editingID = nil
        editor?.delegate = nil
        editor?.removeFromSuperview()
        editor = nil
    }

    #if DEBUG
    var debugIsEditing: Bool { editor != nil }
    #endif
}

// MARK: - NSTextFieldDelegate

extension AnnotationCanvasView: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        guard !isSyncingEditor,
              let id = editingID,
              let field = editor,
              let index = model.texts.firstIndex(where: { $0.id == id }) else { return }
        isSyncingEditor = true
        model.texts[index].text = field.stringValue.replacingOccurrences(of: "\n", with: " ")
        isSyncingEditor = false
        layoutEditor()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.cancelOperation(_:)),
             #selector(NSResponder.insertTab(_:)):
            if let id = editingID {
                finishEditing(id)
            }
            return true
        default:
            return false
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        if let id = editingID {
            finishEditing(id)
        }
    }
}
