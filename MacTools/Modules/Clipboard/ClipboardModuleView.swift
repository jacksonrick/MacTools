import SwiftUI

struct ClipboardModuleView: View {
    let controller: ClipboardController
    let router: HUDRouter

    var body: some View {
        ModuleCard(
            height: CardMetrics.listHeight,
            status: cardStatus,
            hint: cardHint,
            alert: router.statusMessage != nil
        ) {
            HStack(alignment: .top, spacing: 12) {
                list
                    .frame(width: 300)
                ClipboardPreviewView(clip: controller.selectedClip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var cardStatus: String {
        if let message = router.statusMessage { return message }
        if !controller.query.isEmpty {
            return "搜索 “\(controller.query)” · \(controller.clips.count) 条"
        }
        return "最近 \(controller.clips.count) 条"
    }

    private var cardHint: String {
        "↩ 粘贴 · 单击复制 · ⌘P 置顶 · ⌘1–9 直取"
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    if controller.clips.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(controller.clips.enumerated()), id: \.element.id) { index, clip in
                            ClipRow(
                                clip: clip,
                                index: index,
                                selected: clip.id == controller.selectedID
                            )
                            .contentShape(Rectangle())
                            // 鼠标移入：右侧预览跟随；不给 ScrollView 回滚，否则条目会在指针下跳走。
                            .onHover { inside in
                                guard inside, let id = clip.id else { return }
                                controller.hoverSelect(id)
                            }
                            // 单击：复制并收起浮窗。
                            .onTapGesture {
                                controller.copyFromList(clip, router: router)
                            }
                            .id(clip.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: controller.selectedID) { _, newValue in
                guard let newValue, controller.selectionSource == .keyboard else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 60)
            Image(systemName: controller.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(controller.query.isEmpty ? "还没有复制记录" : "没有匹配的条目")
                .font(Typography.hint)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ClipRow: View {
    let clip: Clip
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if index < 9 {
                Text("\(index + 1)")
                    .font(Typography.listMeta)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, alignment: .trailing)
            } else {
                Spacer().frame(width: 12)
            }

            Text(previewText)
                .font(Typography.listRow)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
            }
            if clip.pasteCount > 0 {
                Text("×\(clip.pasteCount + 1)")
                    .font(Typography.listMeta)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
                }
        }
    }

    /// 预览文本：只取开头一小段再拍平成单行。
    ///
    /// 原来对每一行都把**整段内容**做两次 `replacingOccurrences` + `trim`：
    /// 单条上限 100KB，列表默认 50 行，body 一重算（每敲一个键）就是 84ms 的字符串扫描
    /// （实测 113KB 内容 1.68ms/行 × 50 行），而结果只显示一行。截到 600 个字符再处理，
    /// 观感完全一致（行宽就几十个字符），代价与内容长度无关。
    private var previewText: String {
        let flattened = String(clip.content.prefix(600))
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "(空白内容)" : flattened
    }
}
