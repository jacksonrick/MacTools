import SwiftUI

/// 右侧预览：完整内容，内部滚动。禁止玻璃。
struct ClipboardPreviewView: View {
    let clip: Clip?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let clip {
                header(clip)
                Divider().opacity(0.5)
                ScrollView {
                    Text(clip.content)
                        .font(Typography.previewBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                VStack(spacing: 6) {
                    Spacer()
                    Text("选中条目查看完整内容")
                        .font(Typography.hint)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .solidSurface(cornerRadius: 12)
    }

    private func header(_ clip: Clip) -> some View {
        HStack(spacing: 8) {
            Text(metaLine(clip))
                .font(Typography.listMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(clip.content.count) 字符 · \(byteText(clip.content))")
                .font(Typography.listMeta)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    /// 时间戳格式化器：`DateFormatter` 每次新建都要解析格式串 + 查 locale，
    /// 实测 0.5~2ms。而这个 header 在每次 body 求值（敲一个键、挪一下选中）都会重算，
    /// 白白吃掉主线程。建一次复用。
    private static let metaFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private func metaLine(_ clip: Clip) -> String {
        var parts = [Self.metaFormatter.string(from: clip.lastSeenAt)]
        if clip.isPinned { parts.append("已置顶") }
        if clip.pasteCount > 0 { parts.append("粘贴 \(clip.pasteCount) 次") }
        return parts.joined(separator: " · ")
    }

    private func byteText(_ text: String) -> String {
        let bytes = text.utf8.count
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}
