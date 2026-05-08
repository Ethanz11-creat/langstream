import Foundation
import Combine

enum RecordingState: Equatable {
    case idle
    case requestingPermission
    case recording(elapsedSeconds: Int)
    case previewing(text: String)   // Real-time AppleSpeech preview
    case processingASR(provider: String)
    case polishing(preview: String)
    case injecting
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "准备就绪"
        case .requestingPermission: return "请求权限..."
        case .recording: return "正在倾听..."
        case .previewing: return "实时预览..."
        case .processingASR(let provider): return "\(provider)..."
        case .polishing: return "润色中..."
        case .injecting: return "输入中..."
        case .error: return "出错了"
        }
    }

    var isRecordingIndicator: Bool {
        if case .recording = self { return true }
        if case .previewing = self { return true }
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
        case .previewing(let text): return text
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
        // Keep the recording state while previewing; the UI shows
        // "Listening..." with the live transcript in the subtitle.

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
        recognizedText = ""
        refinedText = ""
        isRefining = false
        segmentIndex = 0
        stabilityCheckTask?.cancel()
        stabilityCheckTask = nil
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
