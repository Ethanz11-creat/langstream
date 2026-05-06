import SwiftUI
import AppKit

@main
struct FlowTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
                .hidden()
                .onAppear {
                    WindowManager.shared.hideMainWindow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 0, height: 0)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = ConfigurationStore.shared
        EnvMigration.migrateIfNeeded()
        StatusBarController.shared.setup()

        let hasAccessibility = PermissionHelper.checkAccessibility()
        if !hasAccessibility {
            PermissionHelper.showPermissionGuide()
        }

        WindowManager.fileLog("[AppDelegate] Setting up global hotkey...")
        WindowManager.shared.setupGlobalHotkey()
        WindowManager.fileLog("[AppDelegate] Flowtype launched successfully")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't terminate when settings window is closed
        return false
    }
}
