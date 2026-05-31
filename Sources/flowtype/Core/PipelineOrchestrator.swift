import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - Session State

enum SessionState: Equatable {
    case idle
    case recording(elapsedSeconds: Int)
    case processing(provider: String)
    case polishing(preview: String)
    case injecting
    case error(String)
}

// MARK: - Session Controller

@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    private let pipeline: [PipelineStage]
    private let observers: [SessionObserver]
    private let speechRouter = SpeechRouter.shared

    var qwenProvider: QwenASRProvider { speechRouter.qwenProvider }

    // MARK: - Published State

    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var amplitude: Float = 0.0
    @Published private(set) var previewText: String = ""
    @Published private(set) var lastErrorRawText: String?
    @Published private(set) var errorActions: [ErrorAction] = []

    // MARK: - Session Identity

    private var sessionID: UInt64 = 0
    private var activeSessionID: UInt64 = 0
    private var currentContext: SessionContext?

    // MARK: - Error Recovery

    private var suspendedContext: ErrorRecoveryContext?
    private var suspendedPayload: StagePayload?
    private var suspendedStageIndex: Int?

    // MARK: - Timer

    private var recordingTimer = CancellableTimer()
    private var elapsedSeconds: Int = 0

    // MARK: - Tasks

    private var currentTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?

    // MARK: - Combine

    private var stateCancellable: AnyCancellable?

    // MARK: - Computed

    var isRecording: Bool {
        if case .recording = sessionState { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = sessionState { return true }
        return false
    }

    // MARK: - Initialization

    init(
        pipeline: [PipelineStage] = PipelineRegistry.defaultPipeline(),
        observers: [SessionObserver] = PipelineRegistry.defaultObservers()
    ) {
        self.pipeline = pipeline
        self.observers = observers
    }

    // MARK: - Public API

    func startRecording() {
        let newID = nextSessionID()
        AppLogger.log("[SessionController#\(newID)] startRecording requested")

        switch sessionState {
        case .idle, .error:
            break
        default:
            AppLogger.log("[SessionController#\(newID)] REJECTED: state=\(sessionState)")
            return
        }

        errorDismissTask?.cancel()
        errorDismissTask = nil

        activeSessionID = newID

        // Create session context
        let statePublisher = PassthroughSubject<SessionState, Never>()
        let context = SessionContext(sessionID: newID, statePublisher: statePublisher)
        context.recordingStartTime = Date()
        currentContext = context

        // Reset state
        previewText = ""
        amplitude = 0.0

        // Subscribe to state publisher for intermediate updates from stages
        stateCancellable = statePublisher
            .filter { state in
                // Timer handles recording state; orchestrator handles injecting
                if case .recording = state { return false }
                if case .injecting = state { return false }
                return true
            }
            .sink { [weak self] state in
                guard let self else { return }
                guard let ctx = self.currentContext, ctx.sessionID == newID else { return }
                self.transition(to: state, context: ctx)
            }

        transition(to: .recording(elapsedSeconds: 0), context: context)
        startRecordingTimer()
        WindowManager.shared.showWindow()

        executeStage(at: 0, payload: .empty, context: context)
    }

    func endRecording(withPolish: Bool) {
        AppLogger.log("[SessionController#\(activeSessionID)] endRecording called, withPolish=\(withPolish)")

        guard isRecording else {
            AppLogger.log("[SessionController#\(activeSessionID)] endRecording: not recording, ignoring")
            return
        }

        guard let context = currentContext else { return }

        context.usePolish = withPolish
        stopRecordingTimer()

        currentTask?.cancel()
        currentTask = nil

        // Flush any pending preview text
        if !previewText.isEmpty {
            AppLogger.log("[SessionController#\(activeSessionID)] Final preview: \(previewText.count) chars")
        }

        let providerName = speechRouter.qwenProvider.isLoaded ? "Qwen3-ASR" : "AppleSpeech"
        transition(to: .processing(provider: providerName), context: context)
    }

    func cancel() {
        AppLogger.log("[SessionController#\(activeSessionID)] cancel called, state=\(sessionState)")

        currentTask?.cancel()
        currentTask = nil

        resetToIdle()
        AppLogger.log("[SessionController] Cancelled — session reset to idle")
    }

    func retryPolish() {
        guard case .error = sessionState else {
            AppLogger.log("[SessionController] retryPolish: not in error state")
            return
        }
        guard suspendedContext != nil else {
            AppLogger.log("[SessionController] retryPolish: no recovery context")
            return
        }
        guard let payload = suspendedPayload else {
            AppLogger.log("[SessionController] retryPolish: no suspended payload")
            return
        }
        guard let stageIndex = suspendedStageIndex else {
            AppLogger.log("[SessionController] retryPolish: no suspended stage index")
            return
        }
        guard let context = currentContext else {
            AppLogger.log("[SessionController] retryPolish: no current context")
            return
        }

        AppLogger.log("[SessionController#\(activeSessionID)] Retrying polish...")

        errorDismissTask?.cancel()
        errorDismissTask = nil

        clearSuspension()

        // Force polish on retry
        context.usePolish = true
        context.hasInjected = false

        executeStage(at: stageIndex, payload: payload, context: context)
    }

    private func clearSuspension() {
        lastErrorRawText = nil
        errorActions = []
        suspendedContext = nil
        suspendedPayload = nil
        suspendedStageIndex = nil
    }

    func dismissError() {
        guard case .error = sessionState else { return }
        errorDismissTask?.cancel()
        errorDismissTask = nil
        clearSuspension()
        resetToIdle()
    }

    func copyRawText() {
        guard let rawText = suspendedContext?.rawText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawText, forType: .string)
    }

    // MARK: - Orchestration

    private func executeStage(at index: Int, payload: StagePayload, context: SessionContext) {
        guard activeSessionID == context.sessionID else {
            AppLogger.log("[SessionController] Session \(context.sessionID) no longer active, aborting pipeline")
            return
        }
        guard index < pipeline.count else {
            return transition(to: .idle, context: context)
        }

        let stage = pipeline[index]

        // Pre-stage state transitions
        if stage is InjectionStage {
            transition(to: .injecting, context: context)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            let result = await stage.execute(payload: payload, context: context)

            guard self.activeSessionID == context.sessionID else {
                AppLogger.log("[SessionController] Session \(context.sessionID) no longer active, ignoring stage result")
                return
            }

            switch result {
            case .continue(let nextPayload):
                // Extract text for history tracking
                switch nextPayload {
                case .processed(_, let raw):
                    context.rawTranscript = raw
                case .polished(let final, let raw):
                    context.rawTranscript = raw
                    context.finalText = final
                default:
                    break
                }
                self.executeStage(at: index + 1, payload: nextPayload, context: context)

            case .skip(let targetName, let nextPayload):
                if let targetIndex = self.pipeline.firstIndex(where: { $0.name == targetName }) {
                    self.executeStage(at: targetIndex, payload: nextPayload, context: context)
                }

            case .suspend(let recovery):
                self.suspendedContext = recovery
                self.suspendedPayload = payload
                self.suspendedStageIndex = index
                self.lastErrorRawText = recovery.rawText
                self.errorActions = self.buildErrorActions(from: recovery)
                self.transition(to: .error(recovery.error.localizedDescription), context: context)

            case .complete:
                self.transition(to: .idle, context: context)
            }
        }

        currentTask = task
    }

    // MARK: - State Transition

    private func transition(to newState: SessionState, context: SessionContext) {
        let oldState = sessionState

        // Save history on successful completion
        if case .idle = newState, case .injecting = oldState, !context.finalText.isEmpty {
            saveHistory(context: context)
        }

        sessionState = newState
        observers.forEach { $0.sessionDidTransition(from: oldState, to: newState, context: context) }

        // Auto-dismiss error after 5 seconds
        if case .error = newState {
            WindowManager.shared.showWindow()
            errorDismissTask?.cancel()
            let errorSessionID = activeSessionID
            errorDismissTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch { return }
                guard let self else { return }
                if case .error = self.sessionState, self.activeSessionID == errorSessionID {
                    self.dismissError()
                }
            }
        }
    }

    // MARK: - Error Actions

    private func buildErrorActions(from recovery: ErrorRecoveryContext) -> [ErrorAction] {
        var actions: [ErrorAction] = []
        if recovery.retryable { actions.append(.retry) }
        if recovery.rawText != nil { actions.append(.copyRaw) }
        actions.append(.dismiss)
        return actions
    }

    // MARK: - Timer

    private func startRecordingTimer() {
        elapsedSeconds = 0
        let maxDuration = ConfigurationStore.shared.current.maxRecordingDuration
        recordingTimer.schedule(withTimeInterval: 1.0, repeats: true) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.elapsedSeconds += 1
                self.sessionState = .recording(elapsedSeconds: self.elapsedSeconds)

                // Update amplitude and preview text from RecordingStage
                if let ctx = self.currentContext {
                    if abs(self.amplitude - ctx.currentAmplitude) > 0.005 {
                        self.amplitude = ctx.currentAmplitude
                    }
                    if ctx.currentPreviewText != self.previewText {
                        self.previewText = ctx.currentPreviewText
                    }
                }

                // Auto-stop at max duration
                if self.elapsedSeconds >= maxDuration {
                    AppLogger.log("[SessionController] Recording reached max duration (\(maxDuration)s), auto-stopping")
                    self.endRecording(withPolish: false)
                }
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer.cancel()
        elapsedSeconds = 0
    }

    // MARK: - History

    private func saveHistory(context: SessionContext) {
        let durationMs: UInt64?
        if let recStart = context.recordingStartTime {
            durationMs = UInt64(Date().timeIntervalSince(recStart) * 1000)
        } else {
            durationMs = nil
        }
        let mode: PolishMode = context.usePolish ? (StylePackStore.shared.activePack?.baseMode ?? .structured) : .raw
        let session = DictationSession(
            rawTranscript: context.rawTranscript,
            finalText: context.finalText,
            polishMode: mode,
            durationMs: durationMs
        )
        HistoryStore.shared.append(session)

        // Auto-detect corrections for dictionary
        if context.rawTranscript != context.finalText {
            let raw = context.rawTranscript
            let polished = context.finalText
            detectAndAddCorrections(raw: raw, final: polished)
        }

        let hitIds = DictionaryStore.shared.detectHits(in: context.finalText)
        DictionaryStore.shared.incrementHits(ids: hitIds)

        AppLogger.log("[SessionController] History saved, dict hits: \(hitIds.count)")
    }

    private func detectAndAddCorrections(raw: String, final: String) {
        // Simple word-level diff: find words in final that are not in raw
        let rawWords = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let finalWords = final.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        let rawSet = Set(rawWords.map { $0.lowercased() })
        for word in finalWords where word.count >= 2 {
            let lower = word.lowercased()
            if !rawSet.contains(lower) {
                DictionaryStore.shared.addAutoDetected(phrase: word)
            }
        }
    }

    // MARK: - Reset

    private func resetToIdle() {
        sessionState = .idle
        activeSessionID = 0
        currentContext = nil
        stateCancellable?.cancel()
        stateCancellable = nil
        lastErrorRawText = nil
        errorActions = []
        suspendedContext = nil
        suspendedPayload = nil
        suspendedStageIndex = nil
        currentTask?.cancel()
        currentTask = nil
        errorDismissTask?.cancel()
        errorDismissTask = nil
        stopRecordingTimer()
        previewText = ""
        amplitude = 0.0
        WindowManager.shared.hide()
    }

    // MARK: - Helpers

    private func nextSessionID() -> UInt64 {
        sessionID += 1
        return sessionID
    }
}

// MARK: - ErrorAction

extension SessionController {
    enum ErrorAction: Equatable, Hashable {
        case retry
        case copyRaw
        case dismiss

        var displayName: String {
            switch self {
            case .retry: return "重试润色"
            case .copyRaw: return "复制原文"
            case .dismiss: return "忽略"
            }
        }
    }
}

// MARK: - SessionState UI Properties

extension SessionState {

    var iconName: String {
        switch self {
        case .idle:       return "mic"
        case .recording:  return "waveform"
        case .processing: return "brain.head.profile"
        case .polishing:  return "sparkles"
        case .injecting:  return "keyboard"
        case .error:      return "exclamationmark.triangle"
        }
    }

    var statusColor: Color {
        switch self {
        case .idle:       return Color.white.opacity(0.5)
        case .recording:  return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .processing: return .blue
        case .polishing:  return Color(red: 0.8, green: 0.4, blue: 0.9)
        case .injecting:  return .green
        case .error:      return .red
        }
    }

    var statusTitle: String {
        switch self {
        case .idle:                      return "准备就绪"
        case .recording:                 return "Listening..."
        case .processing(let provider):  return "\(provider)..."
        case .polishing:                 return "润色中..."
        case .injecting:                 return "输入中..."
        case .error:                     return "出错了"
        }
    }

    var isRecordingIndicator: Bool {
        if case .recording = self { return true }
        return false
    }

    var showSpinner: Bool {
        switch self {
        case .processing, .polishing: return true
        default: return false
        }
    }

    var showPanel: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}
