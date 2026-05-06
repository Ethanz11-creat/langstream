import SwiftUI
import Combine
import ApplicationServices
import CoreGraphics

@preconcurrency import CoreFoundation

// MARK: - Option Tap Detector
/// Standalone tap detector that lives outside @MainActor isolation.
/// All access is serialized on the main thread (CGEventTap dispatches via
/// DispatchQueue.main.async, Timer fires on the runloop that created it).
final class OptionTapDetector: @unchecked Sendable {
    static let shared = OptionTapDetector()

    private let tapWindow: TimeInterval = 0.35
    private var tapTimes: [Date] = []
    private var tapTimer: Timer?

    var onDoubleTap: (@Sendable () -> Void)?
    var onSingleTap: (@Sendable () -> Void)?

    private init() {}

    func recordTap(at now: Date = Date()) {
        tapTimes.append(now)
        tapTimes.removeAll { now.timeIntervalSince($0) > tapWindow }

        if tapTimes.count >= 2 {
            tapTimer?.invalidate()
            tapTimer = nil
            tapTimes.removeAll()
            print("[TapDetector] DOUBLE-TAP detected")
            onDoubleTap?()
        } else {
            tapTimer?.invalidate()
            tapTimer = Timer.scheduledTimer(timeInterval: tapWindow,
                                            target: self,
                                            selector: #selector(timerFired),
                                            userInfo: nil,
                                            repeats: false)
            print("[TapDetector] Single tap, timer started (window: \(tapWindow)s)")
        }
    }

    @objc private func timerFired() {
        print("[TapDetector] Timer fired, tapTimes.count=\(tapTimes.count)")
        if tapTimes.count == 1 {
            tapTimes.removeAll()
            onSingleTap?()
        } else {
            tapTimes.removeAll()
        }
    }
}

// MARK: - Log Formatter

private nonisolated(unsafe) let logDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
    return f
}()

// MARK: - WindowManager

@MainActor
class WindowManager: ObservableObject {
    static let shared = WindowManager()
    var panel: FloatingPanel?
    private let orchestrator = PipelineOrchestrator.shared

    private var eventTapPort: CFMachPort?

    /// Current trigger key from configuration
    private var triggerKey: TriggerKey { ConfigurationStore.shared.current.triggerKey }

    /// Cached trigger key for safe access from C callback (avoids actor isolation issues)
    private nonisolated(unsafe) static var cachedTriggerKey: TriggerKey = .command

    init() {
        let view = AnyView(
            CapsuleView()
                .environmentObject(orchestrator.state)
        )
        panel = FloatingPanel(view: view)

        // Wire up tap detector callbacks
        let detector = OptionTapDetector.shared
        detector.onDoubleTap = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleDoubleTap()
            }
        }
        detector.onSingleTap = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleSingleTap()
            }
        }
    }

    // MARK: - Hotkey Setup

    func setupGlobalHotkey() {
        Self.fileLog("[WindowManager] setupGlobalHotkey called")
        let accessibilityEnabled = PermissionHelper.checkAccessibility()
        if !accessibilityEnabled {
            Self.fileLog("[WindowManager] WARNING: Accessibility permission not granted")
        }

        Self.cachedTriggerKey = triggerKey
        Self.fileLog("[WindowManager] Cached triggerKey: \(triggerKey.displayName)")

        setupCGEventTap()
        Self.fileLog("[WindowManager] Global hotkey registered (double-tap \(triggerKey.displayName) to start, single-tap to stop)")
    }

    func reloadHotkey() {
        Self.fileLog("[WindowManager] Reloading hotkey configuration...")
        Self.cachedTriggerKey = triggerKey
        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(tap)
            eventTapPort = nil
        }
        setupCGEventTap()
        Self.fileLog("[WindowManager] Hotkey reloaded with trigger key: \(triggerKey.displayName)")
    }

    private func setupCGEventTap() {
        Self.fileLog("[WindowManager] setupCGEventTap called")
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.fileLog("[WindowManager] FAILED to create CGEvent tap")
            return
        }

        self.eventTapPort = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.fileLog("[EventTap] CGEvent tap created and enabled successfully")
    }

    /// Reliable file-based logger that works inside .app bundles where stdout is lost.
    /// Logs are written to ~/Library/Logs/flowtype/diagnostic.log for consistency.
    nonisolated static func fileLog(_ message: String) {
        let logDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/flowtype")
        let path = (logDir as NSString).appendingPathComponent("diagnostic.log")
        let line = "[\(logDateFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            try FileManager.default.createDirectory(
                atPath: logDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            if FileManager.default.fileExists(atPath: path) {
                let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
            }
        } catch {
            // Silent fail — logging should never crash the app
        }
    }

    /// CGEventTap callback — runs on the main thread since source is added to main RunLoop.
    /// Uses cachedTriggerKey to avoid actor isolation issues from C callback context.
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let triggerFlag = cachedTriggerKey.cgEventFlag
        let isTriggerKeyNow = (flags.rawValue & triggerFlag.rawValue) != 0

        if isTriggerKeyNow {
            fileLog("[EventTap] Trigger key pressed (flags=0x\(String(flags.rawValue, radix: 16)), trigger=\(cachedTriggerKey.displayName))")
            OptionTapDetector.shared.recordTap()
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Tap Handlers

    @MainActor
    private func handleDoubleTap() {
        let wasRecording = orchestrator.isRecording
        print("[WindowManager] handleDoubleTap — wasRecording=\(wasRecording)")

        if wasRecording {
            print("[WindowManager] → DOUBLE-TAP END (LLM polish)")
            orchestrator.beginEndModeDetection()
            orchestrator.confirmDoubleTapEnd()
            orchestrator.toggleRecording()
        } else {
            print("[WindowManager] → DOUBLE-TAP START recording")
            orchestrator.toggleRecording()
        }
    }

    @MainActor
    private func handleSingleTap() {
        print("[WindowManager] handleSingleTap — isRecording=\(orchestrator.isRecording)")
        if orchestrator.isRecording {
            print("[WindowManager] → SINGLE-TAP END (raw ASR)")
            orchestrator.toggleRecording()
        } else {
            print("[WindowManager] Single tap while idle, ignoring")
        }
    }

    // MARK: - Window Management

    func toggleWindow() {
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func showWindow() {
        guard let panel = panel else { return }
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 160
            let y = screen.visibleFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func hideMainWindow() {
        for window in NSApp.windows {
            if window.title.isEmpty && !(window is FloatingPanel) {
                window.close()
            }
        }
    }

}
