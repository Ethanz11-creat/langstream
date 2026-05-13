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
    private var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = ConfigurationStore.shared
        EnvMigration.migrateIfNeeded()
        StatusBarController.shared.setup()

        AppLogger.log("[AppDelegate] Setting up global hotkey...")
        WindowManager.shared.setupGlobalHotkey()
        AppLogger.log("[AppDelegate] Flowtype launched successfully")

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "flowtype.onboardingCompleted")
        if !hasCompletedOnboarding {
            showOnboarding()
        } else {
            let hasAccessibility = PermissionHelper.checkAccessibility()
            if !hasAccessibility {
                PermissionHelper.showPermissionGuide()
            }
            AppLogger.log("[AppDelegate] Starting WhisperServerManager checkAndStart...")
            Task {
                await WhisperServerManager.shared.checkAndStart()
                AppLogger.log("[AppDelegate] WhisperServerManager checkAndStart completed, stage=\(WhisperServerManager.shared.serverStage)")
            }
        }
    }

    @MainActor
    private func showOnboarding() {
        AppLogger.log("[AppDelegate] Showing first-run onboarding")
        let controller = OnboardingWindowController()
        controller.onClose = { [weak self] in
            self?.onboardingWindowController = nil
            // After onboarding closes, start server if not already running
            let mgr = WhisperServerManager.shared
            if mgr.serverStage == .notStarted || mgr.serverStage == .needsInstall {
                Task { await mgr.checkAndStart() }
            }
        }
        onboardingWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't terminate when settings window is closed
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.log("[AppDelegate] App will terminate — stopping Whisper server...")
        WhisperServerManager.shared.stopServer()
        AppLogger.log("[AppDelegate] Whisper server stopped")
    }
}
