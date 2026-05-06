import AppKit
import SwiftUI

@MainActor
class StatusBarController {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?

    private init() {}

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
    }

    private func buildMenu() {
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "显示 Flowtype", action: #selector(showFlowtype), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

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
