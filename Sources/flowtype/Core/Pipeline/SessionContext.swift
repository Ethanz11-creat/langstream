import Foundation
import Combine
import AppKit

// MARK: - AppProfile

/// Placeholder for per-application styling configuration.
/// Will be expanded in Phase 2 of the pipeline refactor.
struct AppProfile {
    let bundleID: String
    let stylePackID: String?
}

// MARK: - SessionContext

/// Shared mutable state for a single dictation session.
///
/// `SessionContext` is `@MainActor` because it is accessed from both the UI
/// (SwiftUI views observing state changes) and the async pipeline stages.
///
/// ## Data Flow Architecture
///
/// There are two separate data paths from the pipeline to the UI:
///
/// 1. **Discrete state transitions** — `statePublisher` emits `SessionState` values
///    (`.idle → .recording → .processing → ...`). These are coarse-grained,
///    stage-driven transitions observed by both `SessionController` and `SessionObserver`s.
///
/// 2. **Continuous real-time data** — `amplitudePublisher` and `previewTextPublisher`
///    stream high-frequency updates directly from `RecordingStage` to `SessionController`.
///    This bypasses the 1-second timer polling that was used in the initial refactor,
///    providing responsive amplitude visualization and preview text updates at the
///    native frequency of the audio buffer callbacks.
///
/// Stages write real-time data to both the stored property (`currentAmplitude`)
/// and the corresponding publisher, so the values remain inspectable for debugging
/// while the publisher drives immediate UI updates.
@MainActor
final class SessionContext {
    /// Unique identifier for this session (monotonically increasing).
    let sessionID: UInt64

    /// Whether the user requested LLM polish (double-tap to end recording).
    var usePolish: Bool = false

    /// When the recording phase started (for diagnostics).
    var recordingStartTime: Date?

    /// Detected target application profile (placeholder for Phase 2).
    var appProfile: AppProfile?

    /// Clipboard content saved before injection (for restore).
    var clipboardContent: String?

    /// Text selected in the target app before recording (for context-aware polish).
    var selectedText: String?

    /// Publisher for state transitions (observed by UI and observers).
    let statePublisher: PassthroughSubject<SessionState, Never>

    /// Raw transcript from ASR before any post-processing.
    var rawTranscript: String = ""

    /// Final text after all processing / polish, ready for injection.
    var finalText: String = ""

    /// Guard to prevent double-injection.
    var hasInjected: Bool = false

    /// The target application that was frontmost when recording started.
    var targetApp: NSRunningApplication?

    // MARK: - Real-time Recording State

    /// Current audio amplitude (updated by RecordingStage during recording).
    var currentAmplitude: Float = 0.0

    /// Current AppleSpeech preview text (updated by RecordingStage during recording).
    var currentPreviewText: String = ""

    /// Publishers for real-time amplitude updates (bypasses 1s timer polling).
    let amplitudePublisher = PassthroughSubject<Float, Never>()

    /// Publisher for real-time preview text updates (bypasses 1s timer polling).
    let previewTextPublisher = PassthroughSubject<String, Never>()

    // MARK: - Initialization

    init(sessionID: UInt64, statePublisher: PassthroughSubject<SessionState, Never>) {
        self.sessionID = sessionID
        self.statePublisher = statePublisher
    }
}
