import AppKit
import Foundation

/// 0.25s 轮询剪贴板。actor 隔离后台逻辑，读取 pasteboard 在主线程完成。
actor ClipboardMonitor {

    private var lastChangeCount: Int
    private var timer: DispatchSourceTimer?
    private let store: ClipboardStore
    private var skipHandler: (@MainActor (String) -> Void)?

    init(store: ClipboardStore, initialChangeCount: Int) {
        self.store = store
        self.lastChangeCount = initialChangeCount
    }

    func start(onSkipTooLong: @escaping @MainActor (String) -> Void) {
        skipHandler = onSkipTooLong
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(60))
        timer.setEventHandler { [weak self] in
            // 计时器本来就在主队列上：先比 changeCount（同进程属性，实测 0.0004ms/次），
            // 只有变了才进 actor 去取整段文本。
            let count = NSPasteboard.general.changeCount
            guard let self else { return }
            Task { await self.poll(changeCount: count) }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 重置基线，避免把本应用刚写入的内容当成新复制（粘贴后）。
    func resyncBaseline() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// 只有 `changeCount` 变化时才读整段文本。
    ///
    /// 原来每 250ms 无条件 `pasteboard.string(forType: .string)`：这个调用要跨进程向
    /// pboard 服务取数据并把整段文本复制过来，244KB 的剪贴板实测 **7.9ms/次**，
    /// 也就是每秒白烧 31ms 主线程、顺带搬 1MB 内存——剪贴板里放张大图或长日志时更糟。
    /// `changeCount` 是纯内存属性，比它便宜三个数量级。
    private func poll(changeCount: Int) async {
        guard changeCount != lastChangeCount else { return }

        let snapshot: (count: Int, text: String?) = await MainActor.run {
            let pasteboard = NSPasteboard.general
            return (pasteboard.changeCount, pasteboard.string(forType: .string))
        }
        lastChangeCount = snapshot.count
        guard let text = snapshot.text, !text.isEmpty else { return }

        do {
            let outcome = try await store.upsert(text: text)
            if case .skippedTooLong = outcome {
                let handler = skipHandler
                await MainActor.run { handler?("超长已跳过") }
            }
        } catch {
            // 写入失败不打断主流程
        }
    }
}
