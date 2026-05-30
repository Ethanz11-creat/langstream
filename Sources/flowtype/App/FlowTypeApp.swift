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

        if !ConfigurationStore.shared.current.hasCompletedOnboarding {
            showOnboarding()
        } else {
            let hasAccessibility = PermissionHelper.checkAccessibility()
            if !hasAccessibility {
                PermissionHelper.showPermissionGuide()
            }
            Task {
                await loadQwenASRModel()
            }
        }
    }

    @MainActor
    private func showOnboarding() {
        AppLogger.log("[AppDelegate] Showing first-run onboarding")
        let controller = OnboardingWindowController()
        controller.onClose = { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.log("[AppDelegate] App will terminate")
    }

    private func loadQwenASRModel() async {
        let provider = await SessionController.shared.qwenProvider
        AppLogger.log("[AppDelegate] Loading Qwen3-ASR model...")
        await QwenModelState.shared.loadModel(provider: provider)
        if case .ready = await QwenModelState.shared.status {
            AppLogger.log("[AppDelegate] Qwen3-ASR model loaded successfully")
        } else {
            AppLogger.log("[AppDelegate] Qwen3-ASR model loading failed")
        }
    }
}
