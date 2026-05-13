import AppKit
import SwiftUI
import Combine

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var statusMenuItem: NSMenuItem?
    private var cancellable: AnyCancellable?
    private var sessionCancellable: AnyCancellable?

    private override init() {
        super.init()
    }

    func setup() {
        let statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        // Load status bar icon from SPM bundle resources
        if let image = Bundle.module.image(forResource: "status_bar_icon") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
        } else {
            // Fallback to system icon if custom icon not found
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Flowtype")
        }

        button.action = #selector(showMenu)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildMenu()

        cancellable = WhisperServerManager.shared.$serverStage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                guard let self else { return }
                if case .idle = SessionController.shared.sessionState {
                    self.statusItem?.button?.toolTip = "FlowType — \(stage.rawValue)"
                }
            }

        sessionCancellable = SessionController.shared.$sessionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle:
                    let stage = WhisperServerManager.shared.serverStage
                    self.statusItem?.button?.toolTip = "FlowType — \(stage.rawValue)"
                case .recording:
                    self.statusItem?.button?.toolTip = "FlowType — 录音中..."
                case .processing:
                    self.statusItem?.button?.toolTip = "FlowType — 识别中..."
                case .polishing:
                    self.statusItem?.button?.toolTip = "FlowType — 润色中..."
                case .injecting:
                    self.statusItem?.button?.toolTip = "FlowType — 输入中..."
                case .error(let msg):
                    self.statusItem?.button?.toolTip = "FlowType — 错误: \(msg)"
                }
            }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let asrStatusItem = NSMenuItem(title: "ASR 状态: 检查中...", action: nil, keyEquivalent: "")
        asrStatusItem.isEnabled = false
        self.statusMenuItem = asrStatusItem
        menu.addItem(asrStatusItem)
        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(title: "显示 Flowtype", action: #selector(showFlowtype), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let restartServerItem = NSMenuItem(title: "重启 ASR 服务", action: #selector(restartWhisperServer), keyEquivalent: "")
        restartServerItem.target = self
        menu.addItem(restartServerItem)

        let viewLogsItem = NSMenuItem(title: "查看日志...", action: #selector(openLogs), keyEquivalent: "")
        viewLogsItem.target = self
        menu.addItem(viewLogsItem)

        let reloadItem = NSMenuItem(title: "重新加载配置", action: #selector(reloadConfiguration), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        let permissionItem = NSMenuItem(title: "检查权限", action: #selector(checkPermissions), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 Flowtype", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func showMenu() {
        guard let button = statusItem?.button else { return }
        statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }

    @objc private func showFlowtype() {
        WindowManager.shared.showWindow()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController()
            controller.onClose = { [weak self] in
                self?.settingsWindowController = nil
            }
            settingsWindowController = controller
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func restartWhisperServer() {
        Task {
            await WhisperServerManager.shared.restartServer()
        }
    }

    @objc private func openLogs() {
        AppLogger.openLogInFinder()
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            let stage = WhisperServerManager.shared.serverStage
            let statusText: String
            switch stage {
            case .ready:
                statusText = "ASR 服务运行中"
            case .modelLoading, .starting, .processStarted, .checking:
                statusText = "ASR \(stage.rawValue)"
            case .restarting:
                statusText = "ASR 正在重启..."
            case .installingVenv, .installingDeps, .downloadingModel:
                statusText = "ASR \(stage.rawValue)"
            case .needsInstall:
                statusText = "ASR 未安装"
            case .error:
                statusText = "ASR 启动失败"
            case .notStarted:
                statusText = "ASR 未启动"
            }
            self.statusMenuItem?.title = statusText
        }
    }

    @objc private func reloadConfiguration() {
        let defaultsKey = "flowtype.config"
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let config = try? JSONDecoder().decode(Configuration.self, from: data) {
            ConfigurationStore.shared.current = config
        }
        WindowManager.shared.reloadHotkey()

        // Show a brief notification via status bar tooltip or temporary title
        if let button = statusItem?.button {
            let originalTitle = button.title
            button.title = "已重新加载"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                button.title = originalTitle
            }
        }
    }

    @objc private func checkPermissions() {
        let hasPermission = PermissionHelper.checkAccessibility()
        if hasPermission {
            let alert = NSAlert()
            alert.messageText = "权限已开启"
            alert.informativeText = "Flowtype 已拥有辅助功能权限。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "确定")
            alert.runModal()
        } else {
            PermissionHelper.showPermissionGuide()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
