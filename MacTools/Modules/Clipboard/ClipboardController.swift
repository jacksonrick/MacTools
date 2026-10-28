import Foundation
import Observation

@Observable
@MainActor
final class ClipboardController: ModuleControlling {

    let moduleID: ModuleID = .clipboard

    private(set) var clips: [Clip] = []
    private(set) var selectedID: Int64?
    private(set) var isLoading = false
    private(set) var query = ""
    /// 选中项来源：键盘操作时列表要跟随滚动，鼠标悬停时不能滚（否则条目会在指针下跳走）。
    private(set) var selectionSource: SelectionSource = .keyboard

    enum SelectionSource {
        case keyboard
        case hover
    }

    private let store: ClipboardStore
    private let settings: SettingsStore
    private var searchTask: Task<Void, Never>?

    init(store: ClipboardStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    var selectedIndex: Int {
        guard let selectedID, let index = clips.firstIndex(where: { $0.id == selectedID }) else { return 0 }
        return index
    }

    var selectedClip: Clip? {
        guard let selectedID else { return nil }
        return clips.first { $0.id == selectedID }
    }

    // MARK: - ModuleControlling

    func didEnter(router: HUDRouter) {
        selectedID = nil
        query = ""
        selectionSource = .keyboard
        Task { await reload() }
    }

    func didChangeText(_ text: String, router: HUDRouter) {
        query = text
        scheduleSearch()
    }

    func handle(_ key: HUDKey, router: HUDRouter) -> Bool {
        switch key {
        case .arrowUp:
            moveSelection(-1)
            return true
        case .arrowDown:
            moveSelection(1)
            return true
        case .enter:
            pasteSelected(router: router)
            return true
        case .command(let character):
            if let number = Int(character), (1...9).contains(number) {
                let index = number - 1
                guard clips.indices.contains(index) else { return true }
                selectedID = clips[index].id
                pasteSelected(router: router)
                return true
            }
            if character == "p" {
                togglePin()
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: - 列表

    private func scheduleSearch() {
        searchTask?.cancel()
        // 中文输入法组词期间 characters 会连续到达，额外留 80ms 稳定窗口（PRD 5.1）
        let delay = query.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } ? 80 : 30
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let limit = settings.displayCount
        let currentQuery = query
        do {
            let results = try await store.search(currentQuery, limit: limit)
            guard currentQuery == query else { return }
            apply(results)
        } catch {
            apply([])
        }
    }

    /// 主线程只应用结果：数组不变则不触发重绘，选中项按 id 重新锚定。
    private func apply(_ results: [Clip]) {
        if clips != results {
            clips = results
        }
        if let selectedID, results.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = results.first?.id
    }

    private func moveSelection(_ delta: Int) {
        guard !clips.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), clips.count - 1)
        selectionSource = .keyboard
        selectedID = clips[next].id
    }

    /// 鼠标移入某行：只换右侧预览，不滚动列表。
    func hoverSelect(_ id: Int64) {
        guard selectedID != id else { return }
        selectionSource = .hover
        selectedID = id
    }

    // MARK: - 操作

    /// 单击列表项：复制到剪贴板并收起浮窗（面板不激活前台应用，用户回去按 ⌘V 即可）。
    func copyFromList(_ clip: Clip, router: HUDRouter) {
        selectionSource = .keyboard
        selectedID = clip.id
        PasteService.copy(clip.content)
        router.flashStatus("已复制，回到应用按 ⌘V")
        Task { [store] in
            if let id = clip.id {
                try? await store.markUsed(id)
            }
        }
        router.closeForAction(duration: 0.30) {}
    }

    func pasteSelected(router: HUDRouter) {
        guard let clip = selectedClip else { return }
        PasteService.paste(clip.content, router: router)
        Task { [store] in
            if let id = clip.id {
                try? await store.markUsed(id)
            }
        }
    }

    func togglePin() {
        guard let clip = selectedClip, let id = clip.id else { return }
        let newValue = !clip.isPinned
        Task {
            try? await store.setPinned(id, pinned: newValue)
            await reload()
        }
    }

    func clearHistory() async {
        try? await store.clearAll()
        await reload()
    }
}
