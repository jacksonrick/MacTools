import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case rectangle
    case arrow
    case pen
    case mosaic
    case text

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .mosaic: "grid"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .mosaic: "马赛克"
        case .text: "文字"
        }
    }

    /// 单键快捷键
    var key: String {
        switch self {
        case .rectangle: "r"
        case .arrow: "a"
        case .pen: "p"
        case .mosaic: "m"
        case .text: "t"
        }
    }

    static func tool(forKey key: String) -> AnnotationTool? {
        allCases.first { $0.key == key }
    }
}

/// 文字大小的三档（工具条「小 / 中 / 大」）。
enum TextSizeTier: Int, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .small: 14
        case .medium: 21
        case .large: 30
        }
    }

    static func nearest(to pointSize: CGFloat) -> TextSizeTier {
        allCases.min { abs($0.pointSize - pointSize) < abs($1.pointSize - pointSize) } ?? .medium
    }
}

enum AnnotationShapeKind: Sendable {
    case rectangle(CGRect)
    case arrow(start: CGPoint, end: CGPoint)
    case pen(points: [CGPoint])
    case mosaic(points: [CGPoint])

    var tool: AnnotationTool {
        switch self {
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .pen: .pen
        case .mosaic: .mosaic
        }
    }
}

struct AnnotationShape: Identifiable, Sendable {
    let id = UUID()
    var kind: AnnotationShapeKind
    var color: Color
    var lineWidth: CGFloat
}

struct AnnotationTextItem: Identifiable, Sendable {
    let id = UUID()
    var text: String
    /// 文字中心点（图片坐标）
    var position: CGPoint
    var fontSize: CGFloat
    var color: Color
}

/// 元素拖拽缩放的基准快照：一次拖拽期间不变，避免逐帧累积误差。
struct ElementSnapshot {
    let id: UUID
    let bounds: CGRect
    let kind: AnnotationShapeKind?
    let text: AnnotationTextItem?
}

// MARK: - 选中框手柄

enum ResizeHandle: CaseIterable, Identifiable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    var id: String { String(describing: self) }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
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

    /// 按手柄拖动量重算矩形（左上原点坐标系）。
    func applied(to rect: CGRect, dx: CGFloat, dy: CGFloat, minSize: CGFloat) -> CGRect {        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch self {
        case .topLeft, .left, .bottomLeft: minX += dx
        case .topRight, .right, .bottomRight: maxX += dx
        default: break
        }
        switch self {
        case .topLeft, .top, .topRight: minY += dy
        case .bottomLeft, .bottom, .bottomRight: maxY += dy
        default: break
        }

        if maxX - minX < minSize {
            if self == .left || self == .topLeft || self == .bottomLeft {
                minX = maxX - minSize
            } else {
                maxX = minX + minSize
            }
        }
        if maxY - minY < minSize {
            if self == .top || self == .topLeft || self == .topRight {
                minY = maxY - minSize
            } else {
                maxY = minY + minSize
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - 模型

@Observable
@MainActor
final class AnnotationModel {
    /// 底图（= 当前选区裁剪，size 为点、像素为 Retina 满分辨率）
    var image: NSImage
    /// 马赛克底图，拖拽调整选区时先置空，松手再算
    var pixelated: NSImage?

    /// nil = 未激活任何工具：不能新增标注，此时拖动选区可移动 / 改大小。
    /// 截图完成后默认就是这一档（和微信 / 钉钉一致）。
    var tool: AnnotationTool?
    var colorIndex: Int = 0
    /// 文字大小档位（新增文字与选中文字共用）
    var textTier: TextSizeTier = .medium
    var shapes: [AnnotationShape] = []
    var texts: [AnnotationTextItem] = []

    /// 当前选中的元素（图形与文字共用一套 id，二者不会重复）
    var selection: UUID?
    /// 正在输入文字的元素
    var editingText: UUID?

    let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]

    init(image: NSImage = NSImage(size: NSSize(width: 1, height: 1)), pixelated: NSImage? = nil) {
        self.image = image
        self.pixelated = pixelated
    }

    var imageSize: CGSize { image.size }

    var color: Color { colors[min(max(colorIndex, 0), colors.count - 1)] }

    var lineWidth: CGFloat { tool == .mosaic ? 18 : 3 }

    var isEmpty: Bool { shapes.isEmpty && texts.isEmpty }

    var hasSelection: Bool { selection != nil }

    /// 当前选中项是不是文字（文字不走缩放手柄，只改字号）
    var isTextSelection: Bool {
        guard let selection else { return false }
        return isText(selection)
    }

    /// 文字相关的上下文：文字工具激活，或选中的是文字。工具条据此点亮字号档位。
    var isTextContext: Bool { tool == .text || isTextSelection }

    var textPointSize: CGFloat { textTier.pointSize }

    // MARK: 元素访问

    func shape(_ id: UUID) -> AnnotationShape? {
        shapes.first { $0.id == id }
    }

    func text(_ id: UUID) -> AnnotationTextItem? {
        texts.first { $0.id == id }
    }

    func isText(_ id: UUID) -> Bool {
        texts.contains { $0.id == id }
    }

    func tool(of id: UUID) -> AnnotationTool? {
        if let shape = shape(id) { return shape.kind.tool }
        if isText(id) { return .text }
        return nil
    }

    func color(of id: UUID) -> Color? {
        if let shape = shape(id) { return shape.color }
        if let text = text(id) { return text.color }
        return nil
    }

    // MARK: 选中

    func select(_ id: UUID?) {
        if let editingText, editingText != id {
            finishTextEditing()
        }
        selection = id
        guard let id, let tool = tool(of: id) else { return }
        self.tool = tool
        if let color = color(of: id),
           let index = colors.firstIndex(where: { $0 == color }) {
            colorIndex = index
        }
        if let text = text(id) {
            textTier = .nearest(to: text.fontSize)
        }
    }

    func clearSelection() {
        finishTextEditing()
        selection = nil
    }

    /// 调色板：有选中元素时同时改它的颜色。
    func applyColor(_ index: Int) {
        colorIndex = index
        guard let selection else { return }
        if let i = shapes.firstIndex(where: { $0.id == selection }) {
            shapes[i].color = color
        } else if let i = texts.firstIndex(where: { $0.id == selection }) {
            texts[i].color = color
        }
    }

    /// 字号档位：有选中文字时同时改它的字号（光标在文字里也能改）。
    func applyTextSize(_ tier: TextSizeTier) {
        textTier = tier
        guard let selection,
              let index = texts.firstIndex(where: { $0.id == selection }) else { return }
        texts[index].fontSize = tier.pointSize
    }

    // MARK: 增删

    func beginText(at point: CGPoint) {
        let item = AnnotationTextItem(text: "", position: point, fontSize: textPointSize, color: color)
        texts.append(item)
        selection = item.id
        editingText = item.id
        tool = .text
    }

    /// 留空的文字项在退出编辑时丢掉，避免留下看不见的空元素。
    func finishTextEditing() {
        guard let editingText else { return }
        self.editingText = nil
        if let index = texts.firstIndex(where: { $0.id == editingText }),
           texts[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.remove(at: index)
            if selection == editingText { selection = nil }
        }
    }

    @discardableResult
    func addText(at point: CGPoint) -> AnnotationTextItem {
        let item = AnnotationTextItem(text: "文字", position: point, fontSize: textPointSize, color: color)
        texts.append(item)
        selection = item.id
        return item
    }

    func deleteSelection() {
        guard let selection else { return }
        shapes.removeAll { $0.id == selection }
        texts.removeAll { $0.id == selection }
        if editingText == selection { editingText = nil }
        self.selection = nil
    }

    func undo() {
        if !shapes.isEmpty {
            let removed = shapes.removeLast()
            if selection == removed.id { selection = nil }
        } else if !texts.isEmpty {
            let removed = texts.removeLast()
            if selection == removed.id { selection = nil }
        }
    }

    // MARK: 几何

    /// 元素的真实几何边界（不含命中判定用的外扩）。
    /// 缩放手柄必须以它为基准，否则按下瞬间把「外扩后的框」写回图形，元素会凭空胖一圈。
    static func naturalBounds(of kind: AnnotationShapeKind) -> CGRect {
        switch kind {
        case .rectangle(let rect):
            return rect.standardized
        case .arrow(let start, let end):
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        case .pen(let points), .mosaic(let points):
            guard let first = points.first else { return .zero }
            var rect = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                rect = rect.union(CGRect(origin: point, size: .zero))
            }
            return rect
        }
    }

    /// 命中 / 选中框用的边界：在真实边界外扩一点，细线也好点中。
    static func bounds(of kind: AnnotationShapeKind, lineWidth: CGFloat) -> CGRect {
        let pad = max(5, lineWidth / 2 + 3)
        return naturalBounds(of: kind).insetBy(dx: -pad, dy: -pad)
    }

    static func textSize(_ item: AnnotationTextItem) -> CGSize {
        let font = NSFont.systemFont(ofSize: max(item.fontSize, 1), weight: .semibold)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for line in item.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let size = (String(line) as NSString).size(withAttributes: [.font: font])
            width = max(width, size.width)
            height += size.height
        }
        if item.text.isEmpty { height = font.pointSize * 1.3 }
        return CGSize(width: max(width, 6) + 6, height: max(height, font.pointSize * 1.2) + 6)
    }

    func bounds(of id: UUID) -> CGRect? {
        if let shape = shape(id) {
            return Self.bounds(of: shape.kind, lineWidth: shape.lineWidth)
        }
        if let text = text(id) {
            let size = Self.textSize(text)
            return CGRect(
                x: text.position.x - size.width / 2,
                y: text.position.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        return nil
    }

    /// 命中测试：文字在上、图形在后，从后往前找。
    func hitTest(_ point: CGPoint) -> UUID? {
        for item in texts.reversed() where bounds(of: item.id)?.contains(point) == true {
            return item.id
        }
        for shape in shapes.reversed() where bounds(of: shape.id)?.contains(point) == true {
            return shape.id
        }
        return nil
    }

    func snapshot(_ id: UUID) -> ElementSnapshot? {
        if let shape = shape(id) {
            return ElementSnapshot(
                id: id,
                bounds: Self.naturalBounds(of: shape.kind),
                kind: shape.kind,
                text: nil
            )
        }
        if let text = text(id) {
            let size = Self.textSize(text)
            let bounds = CGRect(
                x: text.position.x - size.width / 2,
                y: text.position.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            return ElementSnapshot(id: id, bounds: bounds, kind: nil, text: text)
        }
        return nil
    }

    // MARK: 移动 / 缩放

    static func translated(_ kind: AnnotationShapeKind, by delta: CGSize) -> AnnotationShapeKind {
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.width, y: point.y + delta.height)
        }
        switch kind {
        case .rectangle(let rect):
            return .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height))
        case .arrow(let start, let end):
            return .arrow(start: move(start), end: move(end))
        case .pen(let points):
            return .pen(points: points.map(move))
        case .mosaic(let points):
            return .mosaic(points: points.map(move))
        }
    }

    static func remapped(_ kind: AnnotationShapeKind, from old: CGRect, to new: CGRect) -> AnnotationShapeKind {
        guard old.width > 0, old.height > 0 else { return kind }
        func map(_ point: CGPoint) -> CGPoint {
            let nx = (point.x - old.minX) / old.width
            let ny = (point.y - old.minY) / old.height
            return CGPoint(x: new.minX + nx * new.width, y: new.minY + ny * new.height)
        }
        switch kind {
        case .rectangle:
            return .rectangle(new)
        case .arrow(let start, let end):
            return .arrow(start: map(start), end: map(end))
        case .pen(let points):
            return .pen(points: points.map(map))
        case .mosaic(let points):
            return .mosaic(points: points.map(map))
        }
    }

    func move(_ id: UUID, from base: AnnotationShapeKind, by delta: CGSize) {
        guard let index = shapes.firstIndex(where: { $0.id == id }) else { return }
        shapes[index].kind = Self.translated(base, by: delta)
    }

    func moveText(_ id: UUID, from base: CGPoint, by delta: CGSize) {
        guard let index = texts.firstIndex(where: { $0.id == id }) else { return }
        texts[index].position = CGPoint(
            x: min(max(base.x + delta.width, 0), imageSize.width),
            y: min(max(base.y + delta.height, 0), imageSize.height)
        )
    }

    func resize(_ snapshot: ElementSnapshot, to bounds: CGRect) {
        if let index = shapes.firstIndex(where: { $0.id == snapshot.id }),
           let kind = snapshot.kind {
            shapes[index].kind = Self.remapped(kind, from: snapshot.bounds, to: bounds)
        } else if let index = texts.firstIndex(where: { $0.id == snapshot.id }),
                  let base = snapshot.text {
            let ratio = snapshot.bounds.height > 0 ? bounds.height / snapshot.bounds.height : 1
            texts[index].fontSize = min(max(base.fontSize * ratio, 8), 200)
            texts[index].position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}

/// 图片在可用区域内的等比布局（含 letterbox 偏移）。
struct CanvasLayout {
    let scale: CGFloat
    let size: CGSize
    let origin: CGPoint

    init(imageSize: CGSize, available: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0,
              available.width > 0, available.height > 0 else {
            scale = 1
            size = imageSize
            origin = .zero
            return
        }
        let factor = min(available.width / imageSize.width, available.height / imageSize.height)
        scale = factor
        size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        origin = CGPoint(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2
        )
    }

    /// 手势坐标属于「铺满可用区域」的容器，而图片居中摆放，
    /// 必须先减掉 letterbox 偏移再除以缩放，否则落点会整体偏下 / 偏右。
    func imagePoint(from viewPoint: CGPoint, imageSize: CGSize) -> CGPoint {
        let x = (viewPoint.x - origin.x) / scale
        let y = (viewPoint.y - origin.y) / scale
        return CGPoint(
            x: min(max(x, 0), imageSize.width),
            y: min(max(y, 0), imageSize.height)
        )
    }

    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: origin.x + rect.minX * scale,
            y: origin.y + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

// MARK: - 导出（ImageRenderer 合成底图 + 标注层）

struct AnnotationExportView: View {
    let image: NSImage
    let pixelated: NSImage?
    let shapes: [AnnotationShape]
    let texts: [AnnotationTextItem]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .frame(width: image.size.width, height: image.size.height)

            Canvas { context, _ in
                for shape in shapes {
                    draw(shape, in: &context)
                }
            }
            .frame(width: image.size.width, height: image.size.height)

            ForEach(texts) { item in
                Text(item.text)
                    .font(.system(size: item.fontSize, weight: .semibold))
                    .foregroundStyle(item.color)
                    .position(item.position)
            }
        }
        .frame(width: image.size.width, height: image.size.height)
    }

    static func path(from points: [CGPoint]) -> Path {
        var path = Path()
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

    private func draw(_ shape: AnnotationShape, in context: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round, lineJoin: .round)
        switch shape.kind {
        case .rectangle(let rect):
            let path = Path(roundedRect: rect, cornerRadius: 2)
            context.stroke(path, with: .color(shape.color), style: style)
        case .arrow(let start, let end):
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(shape.color), style: style)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length: CGFloat = max(10, shape.lineWidth * 4)
            let spread: CGFloat = .pi / 7
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
            context.stroke(head, with: .color(shape.color), style: style)
        case .pen(let points):
            context.stroke(Self.path(from: points), with: .color(shape.color), style: style)
        case .mosaic(let points):
            guard let pixelated else { return }
            let mask = Self.path(from: points)
                .strokedPath(StrokeStyle(lineWidth: max(shape.lineWidth, 14), lineCap: .round, lineJoin: .round))
            context.clip(to: mask)
            context.draw(Image(nsImage: pixelated), in: CGRect(origin: .zero, size: image.size))
        }
    }
}

enum AnnotationRenderer {
    /// 按底图自身的像素倍率导出，避免 Retina 截屏被压成 1x。
    @MainActor
    static func render(image: NSImage, model: AnnotationModel) -> NSImage? {
        // 只有真的画了马赛克才需要那张「整幅马赛克底图」。
        // 原来写成 `model.pixelated ?? MosaicProcessor.pixelate(image)`：`??` 的右边**总会被求值**，
        // 于是没用过马赛克也要跑一遍 CIPixellate（整幅输入 + 一次同尺寸 CGImage 分配），
        // 而它正好压在「回车复制」这条路上——几毫秒到几十毫秒白等。
        let needsMosaic = model.shapes.contains { shape in
            if case .mosaic = shape.kind { return true }
            return false
        }
        let view = AnnotationExportView(
            image: image,
            pixelated: needsMosaic ? (model.pixelated ?? MosaicProcessor.pixelate(image)) : nil,
            shapes: model.shapes,
            texts: model.texts
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = pixelScale(of: image)
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: image.size)
    }

    @MainActor
    static func pixelScale(of image: NSImage) -> CGFloat {
        guard image.size.width > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        return max(1, CGFloat(cgImage.width) / image.size.width)
    }
}

enum MosaicProcessor {
    /// 共享的渲染上下文。
    ///
    /// 建 `CIContext` 是**重活**：它要准备 Metal/CPU 渲染管线，实测 ~12ms/次，
    /// 比真正跑一遍 pixellate 还贵。原来每次笔刷首次落笔都新建一个，
    /// 于是「第一次画马赛克」会平白卡十几毫秒。上下文可以反复用，也存在线程安全。
    @MainActor private static let context = CIContext()

    /// CIPixellate 生成整张马赛克底图，绘制时按笔刷路径裁剪。
    /// 缩放系数跟着像素倍率走，Retina 上马赛克块大小才和其它标注线宽协调。
    @MainActor
    static func pixelate(_ image: NSImage, scale: CGFloat = 14) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter.pixellate()
        filter.inputImage = input
        let pixelScale = max(1, CGFloat(cgImage.width) / max(image.size.width, 1))
        filter.scale = Float(max(8, scale * pixelScale))
        filter.center = CGPoint(x: input.extent.midX, y: input.extent.midY)

        guard let output = filter.outputImage,
              let cgOutput = context.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cgOutput, size: image.size)
    }
}
