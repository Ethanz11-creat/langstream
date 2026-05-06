import AppKit
import CoreGraphics

enum PermissionHelper {
    /// Check accessibility permission using both API query and functional test
    static func checkAccessibility() -> Bool {
        // API check - may return false for unsigned apps even if permission is granted
        if AXIsProcessTrusted() {
            return true
        }

        // Functional test: try to create a temporary event tap
        // This is more reliable for unsigned apps
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }

        // Clean up the test tap properly
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        return true
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func showPermissionGuide() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "Flowtype 需要监听全局按键来触发语音输入。请前往「系统设置 → 隐私与安全性 → 辅助功能」，将 Flowtype 添加到列表中并勾选。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "我已开启")
        alert.addButton(withTitle: "稍后再说")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        } else if response == .alertSecondButtonReturn {
            // User claims they already enabled it - mark as handled
            UserDefaults.standard.set(true, forKey: "flowtype.hasShownPermissionGuide")
        }
    }

    /// Check accessibility permission on every launch and show guide if missing.
    /// Unlike showFirstLaunchGuideIfNeeded, this does NOT skip based on previous dismissal.
    @MainActor
    static func checkAndPromptAccessibilityIfNeeded() {
        let hasPermission = checkAccessibility()
        guard !hasPermission else { return }
        showPermissionGuide()
    }
}
