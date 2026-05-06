import AppKit
import SwiftUI

@MainActor
class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    convenience init() {
        let settingsView = SettingsView()
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Flowtype 设置"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
