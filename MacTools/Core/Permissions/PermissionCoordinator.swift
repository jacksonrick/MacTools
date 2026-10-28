import AppKit
import ApplicationServices
import CoreGraphics
import Security

/// 统一检查与引导。两套权限不要混淆：
/// - 辅助功能：合成 ⌘V、AXSelectedText 取词
/// - 屏幕录制：截图
/// 全局快捷键（Carbon）不需要任何权限。
@MainActor
final class PermissionCoordinator {

    /// 本进程内是否已经弹过系统授权面板。
    /// 屏幕录制的授权**只对新启动的进程生效**，弹过一次后仍拿不到权限就不该继续重复弹系统框，
    /// 而要引导用户重启；这里用该标记区分「第一次申请」与「申请过但没生效」。
    private(set) var didRequestScreenRecording = false

    // MARK: 辅助功能

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        // 直接使用键名的字符串常量，避免引用非并发安全的全局 C 变量。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: 屏幕录制

    var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        didRequestScreenRecording = true
        return CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    // MARK: 诊断

    /// 当前二进制的签名形态。ad-hoc 签名的「指定要求」只有 CDHash，
    /// 每次重新构建都会变，系统因此会把新构建当成另一个 App，已授的权限随即失效。
    var codeSignatureKind: CodeSignatureKind {
        guard let executable = Bundle.main.executableURL else { return .unknown }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code else { return .unknown }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return .unknown }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adHocFlag: UInt32 = 0x2
        if flags & adHocFlag != 0 { return .adHoc }
        if info[kSecCodeInfoTeamIdentifier as String] != nil { return .identity }
        return .unknown
    }

    /// 是否由终端 / IDE 直接启动，而不是经 LaunchServices（Finder、`open`）启动的 .app。
    /// 这种情况系统可能把 TCC 的「责任进程」算到父进程上，授权会记到终端名下。
    var isRunFromTerminal: Bool {
        let parent = getppid()
        // 经 LaunchServices 启动时父进程就是 launchd(1)。
        guard parent > 1 else { return false }
        guard let name = processName(of: parent) else { return false }
        return name != "launchd" && name != "Finder"
    }

    /// 权限不生效的可能原因（按可能性排序，只返回适用于当前情况的）。
    var screenRecordingHints: [String] {
        var hints: [String] = []
        if didRequestScreenRecording || CGPreflightScreenCaptureAccess() == false {
            hints.append("屏幕录制的授权只对新启动的进程生效：授权后需要退出并重新打开 MacTools。")
        }
        if codeSignatureKind == .adHoc {
            hints.append("当前是 ad-hoc 签名，每次重新构建 CDHash 都会变，系统会把新构建当成另一个 App，之前的授权随之失效。")
        }
        if isRunFromTerminal {
            hints.append("当前进程由终端/IDE 直接启动，系统可能把权限记在父进程名下；请用 open 或装到「应用程序」目录启动。")
        }
        return hints
    }

    // MARK: 重启

    /// 用 LaunchServices 重新拉起自身再退出，让新进程拿到刚授的权限。
    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            let alert = NSAlert()
            alert.messageText = "请手动重新打开 MacTools"
            alert.informativeText = "当前不是以 .app 形式运行，无法自动重启。请退出后重新打开应用。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private func processName(of pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum CodeSignatureKind {
    /// ad-hoc（`codesign -s -`，或 Xcode 里 `CODE_SIGN_IDENTITY = "-"`）
    case adHoc
    /// 有证书身份（开发者证书 / 自签名证书）
    case identity
    case unknown
}
