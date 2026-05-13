import AppKit
import SwiftUI

/// A non-activating floating panel that serves purely as a visual indicator.
/// It never becomes the key window, so it never steals focus from the user's
/// active text input field. The user can continue typing, pressing Return,
/// and switching apps while the panel remains visible.
class FloatingPanel: NSPanel {
    private var isDragging = false
    private var initialLocation: NSPoint = .zero
    private nonisolated(unsafe) var monitors: [Any] = []

    init(view: AnyView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden

        let hostingView = NSHostingView(rootView: view)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // Apply capsule mask so the window itself is capsule-shaped
        let cornerRadius: CGFloat = 35
        let capsulePath = CGPath(
            roundedRect: NSRect(x: 0, y: 0, width: 320, height: 70),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        let maskLayer = CAShapeLayer()
        maskLayer.path = capsulePath
        hostingView.layer?.mask = maskLayer

        self.contentView = hostingView

        setupDragMonitors()
    }

    deinit {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Drag via event monitors (avoids intercepting SwiftUI gestures)

    private func setupDragMonitors() {
        let down = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, event.window === self else { return event }
            self.isDragging = false
            self.initialLocation = event.locationInWindow
            return event
        }

        let dragged = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self, event.window === self else { return event }

            if !self.isDragging {
                let moveDistance = hypot(
                    event.locationInWindow.x - self.initialLocation.x,
                    event.locationInWindow.y - self.initialLocation.y
                )
                if moveDistance > 3 {
                    self.isDragging = true
                }
            }

            guard self.isDragging else { return event }

            let screenLocation = NSEvent.mouseLocation
            let newOrigin = NSPoint(
                x: screenLocation.x - self.initialLocation.x,
                y: screenLocation.y - self.initialLocation.y
            )
            self.setFrameOrigin(newOrigin)
            return event
        }

        let up = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self = self, event.window === self else { return event }
            self.isDragging = false
            return event
        }

        monitors = [down, dragged, up].compactMap { $0 }
    }
}
