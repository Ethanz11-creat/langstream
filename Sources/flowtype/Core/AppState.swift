import Foundation
import Combine

enum RecordingState: Equatable {
    case idle
    case requestingPermission
    case recording(elapsedSeconds: Int)
    case processingASR(provider: String)
    case polishing(preview: String)
    case injecting
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "准备就绪"
        case .requestingPermission: return "请求权限..."
        case .recording: return "正在倾听..."
        case .processingASR(let provider): return "\(provider)..."
        case .polishing: return "润色中..."
        case .injecting: return "输入中..."
        case .error: return "出错了"
        }
    }

    var isRecordingIndicator: Bool {
        if case .recording = self { return true }
        return false
    }

    var showSpinner: Bool {
        switch self {
        case .processingASR, .polishing: return true
        default: return false
        }
    }

    var previewText: String? {
        switch self {
        case .polishing(let preview): return preview
        default: return nil
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var statusDetail: String = ""
    @Published var amplitude: Float = 0.0

    // Phase 2: Draft/Stable split
    @Published var stableText: String = ""
    @Published var draftText: String = ""

    // Real-time preview text (AppleSpeech or placeholder)
    @Published var previewText: String = ""

    // Debounced preview text for UI (with hysteresis)
    @Published var displayedPreviewText: String = ""

    // Cloud ASR final result
    @Published var recognizedText: String = ""

    // Latest refined text (from LLM)
    @Published var refinedText: String = ""

    // Whether async refinement is in progress
    @Published var isRefining: Bool = false

    // Stable segment callback
    var onStableSegment: ((String, Int) -> Void)?

    private var recordingTimer: Timer?
    private var elapsedSeconds = 0

    // Phase 2: Stability detection
    private var stabilityCheckTask: Task<Void, Never>?
    private let stabilityInterval: UInt64 = 800_000_000 // 800ms in nanoseconds
    private(set) var segmentIndex: Int = 0

    // MARK: - Hysteresis / debounce for preview text display
    private var lastPreviewUpdateTime: Date = .distantPast
    private var lastDisplayedPreviewUpdateTime: Date = .distantPast
    private var previewHoldTimer: Timer?
    private var previewThrottleTask: Task<Void, Never>?
    private let previewThrottleInterval: TimeInterval = 0.15   // 150ms throttle
    private let previewHoldDuration: TimeInterval = 1.2        // 1.0-1.5s hold

    func transition(to newState: RecordingState) {
        state = newState

        if case .recording = newState {
            if recordingTimer == nil {
                startRecordingTimer()
            }
        } else {
            stopRecordingTimer()
        }
    }

    func updatePreviewText(_ text: String) {
        draftText = text
        previewText = text
        lastPreviewUpdateTime = Date()

        // Cancel any pending clear timer (new text arrived)
        previewHoldTimer?.invalidate()
        previewHoldTimer = nil

        // Cancel any pending throttle task
        previewThrottleTask?.cancel()

        let now = Date()
        let timeSinceLastDisplay = now.timeIntervalSince(lastDisplayedPreviewUpdateTime)

        if timeSinceLastDisplay >= previewThrottleInterval {
            // Enough time has passed since last UI update — update immediately
            displayedPreviewText = text
            lastDisplayedPreviewUpdateTime = now
            schedulePreviewClear()
        } else {
            // Too soon — schedule a delayed update
            let delay = previewThrottleInterval - timeSinceLastDisplay
            previewThrottleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.displayedPreviewText = text
                    self.lastDisplayedPreviewUpdateTime = Date()
                    self.schedulePreviewClear()
                }
            }
        }

        // Phase 2: Cancel previous stability check
        stabilityCheckTask?.cancel()

        // Only check if text has grown beyond stableText
        guard text.count > stableText.count else { return }

        // Start new stability check
        stabilityCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.stabilityInterval ?? 800_000_000)
            guard let self = self, !Task.isCancelled else { return }

            let delta = String(text.dropFirst(self.stableText.count))
            guard delta.count >= 4,
                  LLMService.shouldPolish(delta) != nil else {
                self.stableText = text
                return
            }

            self.stableText = text
            self.segmentIndex += 1
            self.onStableSegment?(delta, self.segmentIndex)
        }
    }

    private func schedulePreviewClear() {
        previewHoldTimer?.invalidate()
        previewHoldTimer = Timer.scheduledTimer(withTimeInterval: previewHoldDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Only clear if no new updates arrived since timer started
                if Date().timeIntervalSince(self.lastPreviewUpdateTime) >= self.previewHoldDuration {
                    self.displayedPreviewText = ""
                }
            }
        }
    }

    func updateAmplitude(_ value: Float) {
        amplitude = value
    }

    func updatePolishingPreview(_ text: String) {
        state = .polishing(preview: text)
    }

    func showError(_ message: String) {
        state = .error(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.transition(to: .idle)
        }
    }

    func clearTranscription() {
        stableText = ""
        draftText = ""
        previewText = ""
        displayedPreviewText = ""
        recognizedText = ""
        refinedText = ""
        isRefining = false
        segmentIndex = 0
        stabilityCheckTask?.cancel()
        stabilityCheckTask = nil
        previewHoldTimer?.invalidate()
        previewHoldTimer = nil
        previewThrottleTask?.cancel()
        previewThrottleTask = nil
    }

    private func startRecordingTimer() {
        elapsedSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.elapsedSeconds += 1
                self.transition(to: .recording(elapsedSeconds: self.elapsedSeconds))
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        elapsedSeconds = 0
    }
}
