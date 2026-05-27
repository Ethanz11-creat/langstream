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
    private var tapTimer = CancellableTimer()

    var onDoubleTap: (@Sendable () -> Void)?
    var onSingleTap: (@Sendable () -> Void)?

    private init() {}

    func recordTap(at now: Date = Date()) {
        tapTimes.append(now)
        tapTimes.removeAll { now.timeIntervalSince($0) > tapWindow }

        if tapTimes.count >= 2 {
            tapTimer.cancel()
            tapTimes.removeAll()
            AppLogger.log("[TapDetector] DOUBLE-TAP detected")
            onDoubleTap?()
        } else {
            tapTimer.schedule(
                timeInterval: tapWindow,
                target: self,
                selector: #selector(timerFired)
            )
            AppLogger.log("[TapDetector] Single tap, timer started (window: \(tapWindow)s)")
        }
    }

    @objc private func timerFired() {
        AppLogger.log("[TapDetector] Timer fired, tapTimes.count=\(tapTimes.count)")
        if tapTimes.count == 1 {
            tapTimes.removeAll()
            onSingleTap?()
        } else {
            tapTimes.removeAll()
        }
    }
}

// MARK: - Window Manager

@MainActor
class WindowManager: ObservableObject {
    static let shared = WindowManager()
    var panel: FloatingPanel?

    private var eventTapPort: CFMachPort?
    private var sessionStateCancellable: AnyCancellable?
    private var reloadWorkItem: DispatchWorkItem?

    /// Periodic timer to ensure the CGEvent tap stays enabled after system events.
    private var eventTapHealthTimer = CancellableTimer()
    private let eventTapHealthInterval: TimeInterval = 5.0

    /// Current trigger key from configuration
    private var triggerKey: TriggerKey { ConfigurationStore.shared.current.triggerKey }

    /// Cached trigger key for safe access from C callback (avoids actor isolation issues)
    private static var cachedTriggerKey = UnsafeCell<TriggerKey>(.command)

    /// Cached flag: true when a session is active (non-idle). Updated by SessionController
    /// observer so the C callback can check without crossing actor isolation.
    private static var cachedSessionActive = UnsafeCell<Bool>(false)

    /// Cached interaction mode for safe access from C callback.
    private static var cachedInteractionMode = UnsafeCell<InteractionMode>(.tapToStart)

    init() {
        let view = AnyView(
            CapsuleView()
                .environmentObject(SessionController.shared)
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

        sessionStateCancellable = SessionController.shared.$sessionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                let active: Bool
                if case .idle = state { active = false } else { active = true }
                Self.cachedSessionActive.value = active
            }
    }

    // MARK: - Hotkey Setup

    func setupGlobalHotkey() {
        AppLogger.log("[WindowManager] setupGlobalHotkey called")
        let accessibilityEnabled = PermissionHelper.checkAccessibility()
        if !accessibilityEnabled {
            AppLogger.log("[WindowManager] WARNING: Accessibility permission not granted")
        }

        Self.cachedTriggerKey.value = triggerKey
        Self.cachedInteractionMode.value = ConfigurationStore.shared.current.interactionMode
        AppLogger.log("[WindowManager] Cached triggerKey: \(triggerKey.displayName), interactionMode: \(Self.cachedInteractionMode.value.displayName)")

        setupCGEventTap()
        AppLogger.log("[WindowManager] Global hotkey registered (double-tap \(triggerKey.displayName) to start, single-tap to stop)")
    }

    func reloadHotkey() {
        AppLogger.log("[WindowManager] Queuing debounced hotkey reload...")
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            AppLogger.log("[WindowManager] Executing debounced reload...")
            Self.cachedTriggerKey.value = self.triggerKey
            Self.cachedInteractionMode.value = ConfigurationStore.shared.current.interactionMode
            self.eventTapHealthTimer.cancel()
            if let tap = self.eventTapPort {
                CGEvent.tapEnable(tap: tap, enable: false)
                if let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                }
                CFMachPortInvalidate(tap)
                self.eventTapPort = nil
            }
            self.setupCGEventTap()
            AppLogger.log("[WindowManager] Hotkey reloaded with trigger key: \(self.triggerKey.displayName)")
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func startEventTapHealthCheck() {
        eventTapHealthTimer.schedule(
            withTimeInterval: eventTapHealthInterval,
            repeats: true
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let tap = self.eventTapPort {
                    if !CGEvent.tapIsEnabled(tap: tap) {
                        AppLogger.log("[WindowManager] Event tap was disabled by system, re-enabling...")
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                } else {
                    AppLogger.log("[WindowManager] Event tap health check: tap is nil, re-creating...")
                    self.setupCGEventTap()
                }
            }
        }
    }

    private func setupCGEventTap() {
        AppLogger.log("[WindowManager] setupCGEventTap called")
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                      | CGEventMask(1 << CGEventType.keyDown.rawValue)
                      | CGEventMask(1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLogger.log("[WindowManager] FAILED to create CGEvent tap")
            return
        }

        self.eventTapPort = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        startEventTapHealthCheck()
        AppLogger.log("[EventTap] CGEvent tap created and enabled successfully")
    }

    /// CGEventTap callback — runs on the main thread since source is added to main RunLoop.
    /// Uses cachedTriggerKey / cachedSessionActive to avoid actor isolation issues from C callback context.
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let refcon = refcon {
                let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
                assert(WindowManager.shared === manager, "eventTapCallback refcon must point to the WindowManager singleton")
                if let tap = manager.eventTapPort {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53, cachedSessionActive.value {
                AppLogger.log("[EventTap] Esc pressed during active session — cancelling")
                DispatchQueue.main.async {
                    SessionController.shared.cancel()
                }
                return nil
            }

            // Handle non-modifier trigger keys (F13, F14, F15, Caps Lock, Right Command)
            if !cachedTriggerKey.value.isModifier,
               let triggerKeyCode = cachedTriggerKey.value.keyCode,
               keyCode == Int64(triggerKeyCode) {
                let mode = cachedInteractionMode.value
                if mode == .toggle {
                    AppLogger.log("[EventTap] Non-modifier trigger key pressed (toggle mode)")
                    DispatchQueue.main.async {
                        let controller = SessionController.shared
                        if controller.isRecording {
                            controller.endRecording(withPolish: false)
                        } else {
                            controller.startRecording()
                        }
                    }
                } else {
                    AppLogger.log("[EventTap] Non-modifier trigger key pressed (tapToStart mode)")
                    OptionTapDetector.shared.recordTap()
                }
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if !cachedTriggerKey.value.isModifier,
               let triggerKeyCode = cachedTriggerKey.value.keyCode,
               keyCode == Int64(triggerKeyCode) {
                // Non-modifier trigger key released — nothing to do here.
                // State is managed on keyDown.
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        guard !KeyboardInjector.isInjecting.withLock({ $0 }) else {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let triggerFlag = cachedTriggerKey.value.cgEventFlag
        let isTriggerKeyNow: Bool
        if let triggerFlag {
            isTriggerKeyNow = (flags.rawValue & triggerFlag.rawValue) != 0
        } else {
            isTriggerKeyNow = false
        }

        if isTriggerKeyNow {
            AppLogger.log("[EventTap] Trigger key pressed (flags=0x\(String(flags.rawValue, radix: 16)), trigger=\(cachedTriggerKey.value.displayName))")
            OptionTapDetector.shared.recordTap()
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Tap Handlers

    @MainActor
    private func handleDoubleTap() {
        let controller = SessionController.shared
        let wasRecording = controller.isRecording
        let mode = ConfigurationStore.shared.current.interactionMode
        AppLogger.log("[WindowManager] handleDoubleTap — wasRecording=\(wasRecording), mode=\(mode)")

        if mode == .toggle {
            // In toggle mode, double-tap is same as single-tap
            handleSingleTap()
            return
        }

        if wasRecording {
            AppLogger.log("[WindowManager] → DOUBLE-TAP END (with LLM polish)")
            controller.endRecording(withPolish: true)
        } else {
            AppLogger.log("[WindowManager] → DOUBLE-TAP START recording")
            controller.startRecording()
        }
    }

    @MainActor
    private func handleSingleTap() {
        let controller = SessionController.shared
        let mode = ConfigurationStore.shared.current.interactionMode
        AppLogger.log("[WindowManager] handleSingleTap — isRecording=\(controller.isRecording), mode=\(mode)")

        if mode == .toggle {
            if controller.isRecording {
                AppLogger.log("[WindowManager] → SINGLE-TAP END (raw ASR)")
                controller.endRecording(withPolish: false)
            } else {
                AppLogger.log("[WindowManager] → SINGLE-TAP START recording")
                controller.startRecording()
            }
            return
        }

        if controller.isRecording {
            AppLogger.log("[WindowManager] → SINGLE-TAP END (raw ASR)")
            controller.endRecording(withPolish: false)
        } else {
            AppLogger.log("[WindowManager] Single tap while idle, ignoring")
        }
    }

    // MARK: - Window Management

    func showWindow() {
        guard let panel = panel else { return }
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 160
            let y = screen.visibleFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggleWindow() {
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func hideMainWindow() {
        for window in NSApp.windows {
            if window.title.isEmpty && !(window is FloatingPanel) {
                window.close()
            }
        }
    }
}
