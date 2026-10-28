import SwiftUI

@main
struct MacToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 常驻菜单栏应用：无主窗口、无 Dock 图标（LSUIElement）。
        // 设置窗口由 SettingsWindowController 以独立 NSWindow 呈现。
        Settings {
            SettingsPlaceholderView()
        }
    }
}

private struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("MacTools 设置")
                .font(.headline)
            Text("设置窗口由菜单栏「设置…」打开")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 420, height: 220)
    }
}
