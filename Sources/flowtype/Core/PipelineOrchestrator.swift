import Foundation
import AppKit
import SwiftUI

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

    private let audioRecorder = AudioRecorder()
    private let speechRouter = SpeechRouter()
    private let llmService = LLMService()
    private let appleSpeechProvider = AppleSpeechProvider()

    var qwenProvider: QwenASRProvider { speechRouter.qwenProvider }

    // MARK: - Published State

    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var amplitude: Float = 0.0
    @Published private(set) var previewText: String = ""

    // MARK: - Session Identity

    private var sessionID: UInt64 = 0
    private var activeSessionID: UInt64 = 0
    private var useLLMPolish: Bool = false

    // MARK: - Tasks

    private var recordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var previewStreamTask: Task<Void, Never>?

    // MARK: - Recording Timer

    private var recordingTimer = CancellableTimer()
    private var elapsedSeconds: Int = 0

    // MARK: - Preview Debounce

    private var previewDebounceTask: Task<Void, Never>?
    private var pendingPreviewText: String = ""

    // MARK: - Injection Guard

    private var hasInjected: Bool = false

    // MARK: - History Tracking

    private var sessionRawTranscript: String = ""
    private var sessionFinalText: String = ""

    // MARK: - Error Retry Context

    @Published private(set) var lastErrorRawText: String? = nil
    @Published private(set) var errorActions: [ErrorAction] = []

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

    // MARK: - Error Dismiss

    private var errorDismissTask: Task<Void, Never>?

    // MARK: - Diagnostics

    private var recordingStartTime: Date?

    // MARK: - Computed

    var isRecording: Bool {
        if case .recording = sessionState { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = sessionState { return true }
        return false
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
        useLLMPolish = false
        hasInjected = false
        recordingStartTime = Date()
        sessionRawTranscript = ""
        sessionFinalText = ""

        previewText = ""
        amplitude = 0.0
        pendingPreviewText = ""
        previewDebounceTask?.cancel()
        previewDebounceTask = nil

        sessionState = .recording(elapsedSeconds: 0)
        SoundFeedback.playRecordingStart()
        startRecordingTimer()
        WindowManager.shared.showWindow()

        recordingTask = Task { [weak self] in
            guard let self else { return }
            await self.runRecordingSession(id: newID)
        }
    }

    func endRecording(withPolish: Bool) {
        SoundFeedback.playRecordingStop()
        AppLogger.log("[SessionController#\(activeSessionID)] endRecording called, withPolish=\(withPolish)")

        guard isRecording else {
            AppLogger.log("[SessionController#\(activeSessionID)] endRecording: not recording, ignoring")
            return
        }

        useLLMPolish = withPolish
        stopRecordingTimer()

        recordingTask?.cancel()
        recordingTask = nil

        // Flush any pending preview debounce so the final preview text is complete
        previewDebounceTask?.cancel()
        previewDebounceTask = nil
        if !pendingPreviewText.isEmpty {
            previewText = pendingPreviewText
        }

        let providerName = speechRouter.qwenProvider.isLoaded ? "Qwen3-ASR" : "AppleSpeech"
        sessionState = .processing(provider: providerName)

        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runProcessingSession(id: self.activeSessionID)
        }
    }

    func cancel() {
        AppLogger.log("[SessionController#\(activeSessionID)] cancel called, state=\(sessionState)")

        recordingTask?.cancel()
        recordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        previewStreamTask?.cancel()
        previewStreamTask = nil

        audioRecorder.onAudioBuffer = nil
        audioRecorder.onRecordingFrozen = nil
        audioRecorder.stopRecording()
        _ = appleSpeechProvider.stopStreamingRecognition()

        resetToIdle()
        AppLogger.log("[SessionController] Cancelled — session reset to idle")
    }

    // MARK: - Recording Phase

    private func runRecordingSession(id: UInt64) async {
        AppLogger.log("[SessionController#\(id)] Recording phase started")
        let recordingStart = Date()

        defer {
            let elapsed = Date().timeIntervalSince(recordingStart)
            AppLogger.log("[SessionController#\(id)] Recording phase ended (duration: \(String(format: "%.1f", elapsed))s)")
        }

        do {
            let granted = await audioRecorder.requestPermission()
            guard granted else {
                let status = audioRecorder.authorizationStatus()
                let msg = micPermissionMessage(status: status)
                showError(msg)
                AppLogger.log("[SessionController#\(id)] Mic permission denied (status=\(status))")
                return
            }
            try checkCancellation(id: id)

            let deviceID = ConfigurationStore.shared.current.microphoneDeviceID
            let output = try await audioRecorder.startRecording(deviceID: deviceID)
            AppLogger.log("[SessionController#\(id)] AudioRecorder started")

            // AppleSpeech real-time preview
            audioRecorder.onAudioBuffer = { [weak self] buffer in
                self?.appleSpeechProvider.appendAudioBuffer(buffer)
            }
            let previewStream = await appleSpeechProvider.startStreamingRecognition()
            AppLogger.log("[SessionController#\(id)] AppleSpeech preview started")

            self.previewStreamTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await text in previewStream {
                    guard self.activeSessionID == id else { break }
                    self.updatePreviewText(text)
                }
            }

            AppLogger.log("[SessionController#\(id)] Recording in progress")
            for await amp in output.amplitude {
                try checkCancellation(id: id)
                if abs(self.amplitude - amp) > 0.005 {
                    self.amplitude = amp
                }
            }
            AppLogger.log("[SessionController#\(id)] Audio amplitude stream ended")

        } catch is CancellationError {
            AppLogger.log("[SessionController#\(id)] Recording cancelled")
        } catch {
            AppLogger.log("[SessionController#\(id)] Recording failed: \(error)")
            showError("录音启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Processing Phase

    private func runProcessingSession(id: UInt64) async {
        AppLogger.log("[SessionController#\(id)] Processing phase started")
        let processingStartTime = Date()

        defer {
            let totalProcessingTime = Date().timeIntervalSince(processingStartTime)
            if let recStart = recordingStartTime {
                let totalSessionTime = Date().timeIntervalSince(recStart)
                AppLogger.log("[SessionController#\(id)] ===== TIMING SUMMARY =====")
                AppLogger.log("[SessionController#\(id)] Total session time: \(String(format: "%.1f", totalSessionTime))s")
                AppLogger.log("[SessionController#\(id)] Processing time: \(String(format: "%.1f", totalProcessingTime))s")
            }
            AppLogger.log("[SessionController#\(id)] Processing phase ended (total: \(String(format: "%.1f", totalProcessingTime))s)")
        }

        let stopAudioStart = Date()
        audioRecorder.stopRecording()
        audioRecorder.onAudioBuffer = nil
        audioRecorder.onRecordingFrozen = nil
        AppLogger.log("[SessionController#\(id)] AudioRecorder stopped in \(String(format: "%.2f", Date().timeIntervalSince(stopAudioStart)))s")

        let localPreviewText = appleSpeechProvider.stopStreamingRecognition()
        AppLogger.log("[SessionController#\(id)] AppleSpeech final preview: \(localPreviewText.count) chars")

        let rawSamples = audioRecorder.takeAccumulatedSamples()
        let audioDuration = Double(rawSamples.count) / 16000.0
        AppLogger.log("[SessionController#\(id)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")

        var finalASRText = ""

        if speechRouter.qwenProvider.isLoaded && !rawSamples.isEmpty {
            AppLogger.log("[SessionController#\(id)] Using Qwen3-ASR batch transcription")
            sessionState = .processing(provider: "Qwen3-ASR")

            let asrStart = Date()
            do {
                finalASRText = try await speechRouter.qwenProvider.transcribe(
                    samples: rawSamples,
                    language: nil,
                    context: nil
                )
                AppLogger.log("[SessionController#\(id)] Qwen3-ASR completed in \(String(format: "%.2f", Date().timeIntervalSince(asrStart)))s: \(finalASRText.count) chars")
                guard activeSessionID == id else {
                    AppLogger.log("[SessionController#\(id)] Session changed after transcription, discarding result")
                    throw CancellationError()
                }
            } catch is CancellationError {
                AppLogger.log("[SessionController#\(id)] Qwen3-ASR cancelled")
                resetToIdle()
                return
            } catch {
                AppLogger.log("[SessionController#\(id)] Qwen3-ASR failed: \(error)")
                finalASRText = ""
            }
        }

        if finalASRText.isEmpty, !localPreviewText.isEmpty {
            AppLogger.log("[SessionController#\(id)] Using AppleSpeech preview as fallback")
            finalASRText = localPreviewText
        }

        let postProcessStart = Date()
        let processedText = ASRPostProcessor.process(finalASRText)
        let textToUse = processedText.isEmpty ? finalASRText.trimmingCharacters(in: .whitespaces) : processedText
        AppLogger.log("[SessionController#\(id)] Post-processed in \(String(format: "%.2f", Date().timeIntervalSince(postProcessStart)))s: \(textToUse.count) chars")

        guard !textToUse.isEmpty else {
            AppLogger.log("[SessionController#\(id)] Empty text, aborting")
            showError("语音识别结果为空")
            resetToIdle()
            return
        }

        sessionRawTranscript = textToUse

        if useLLMPolish {
            let polishStart = Date()
            sessionState = .polishing(preview: "")

            let composedPrompt = LLMService.composeSystemPrompt(
                fallback: ConfigurationStore.shared.current.systemPrompt
            )

            var polishedText: String? = nil
            do {
                let stream = await llmService.polishText(textToUse, systemPrompt: composedPrompt)
                var accumulated = ""
                for try await chunk in stream {
                    guard activeSessionID == id else { throw CancellationError() }
                    accumulated += chunk
                    sessionState = .polishing(preview: accumulated)
                }
                if !accumulated.isEmpty && accumulated != textToUse {
                    polishedText = accumulated
                    AppLogger.log("[SessionController#\(id)] LLM polished in \(String(format: "%.1f", Date().timeIntervalSince(polishStart)))s: \(accumulated.count) chars")
                } else {
                    AppLogger.log("[SessionController#\(id)] LLM returned empty/same, using raw")
                }
            } catch is CancellationError {
                AppLogger.log("[SessionController#\(id)] LLM polish cancelled")
                resetToIdle()
                return
            } catch {
                AppLogger.log("[SessionController#\(id)] LLM polish failed: \(error)")
                lastErrorRawText = textToUse
                showError("润色失败", detail: error.localizedDescription, actions: [.retry, .copyRaw, .dismiss])
                return
            }

            let finalText = polishedText ?? textToUse
            await injectText(finalText, sessionID: id)
        } else {
            AppLogger.log("[SessionController#\(id)] Using raw ASR text (single-tap end)")
            await injectText(textToUse, sessionID: id)
        }
    }

    // MARK: - Injection Phase

    private func injectText(_ text: String, sessionID: UInt64) async {
        guard !hasInjected else {
            AppLogger.log("[SessionController#\(sessionID)] Duplicate injection blocked")
            resetToIdle()
            return
        }
        hasInjected = true
        AppLogger.log("[SessionController#\(sessionID)] Injection phase started")
        let injectStart = Date()

        // Security: capture target application before injection
        let targetApp = NSWorkspace.shared.frontmostApplication
        let targetBundleID = targetApp?.bundleIdentifier ?? "unknown"
        AppLogger.log("[SessionController#\(sessionID)] Target app: \(targetBundleID)")

        sessionState = .injecting
        WindowManager.shared.hide()

        try? await Task.sleep(nanoseconds: 100_000_000)

        guard activeSessionID == sessionID else {
            AppLogger.log("[SessionController#\(sessionID)] Session changed before injection, aborting")
            resetToIdle()
            return
        }

        // Security: verify target app hasn't changed before injecting
        let currentApp = NSWorkspace.shared.frontmostApplication
        if currentApp?.bundleIdentifier != targetBundleID {
            AppLogger.log("[SessionController#\(sessionID)] Target app changed from \(targetBundleID) to \(currentApp?.bundleIdentifier ?? "nil"), aborting injection")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showError("目标应用已切换，文本已复制到剪贴板")
            resetToIdle()
            return
        }

        do {
            try await KeyboardInjector.insertText(text)
            AppLogger.log("[SessionController#\(sessionID)] Text injected successfully in \(String(format: "%.2f", Date().timeIntervalSince(injectStart)))s")
        } catch {
            AppLogger.log("[SessionController#\(sessionID)] Injection failed: \(error)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showError("已复制到剪贴板")
            resetToIdle()
            return
        }

        saveHistory(finalText: text)

        resetToIdle()
        if let recStart = recordingStartTime {
            let totalSessionTime = Date().timeIntervalSince(recStart)
            AppLogger.log("[SessionController#\(sessionID)] ===== SESSION COMPLETE =====")
            AppLogger.log("[SessionController#\(sessionID)] Total session time: \(String(format: "%.1f", totalSessionTime))s")
        }
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

    // MARK: - Preview Debounce

    private func updatePreviewText(_ text: String) {
        if case .recording = sessionState, text.isEmpty, !previewText.isEmpty {
            return
        }
        guard text != pendingPreviewText else { return }
        pendingPreviewText = text

        if previewText.isEmpty, !text.isEmpty {
            previewText = text
            return
        }

        previewDebounceTask?.cancel()
        previewDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch { return }
            guard let self else { return }
            self.previewText = self.pendingPreviewText
            self.previewDebounceTask = nil
        }
    }

    // MARK: - Error

    private func showError(_ message: String, detail: String? = nil, actions: [ErrorAction] = [.dismiss]) {
        SoundFeedback.playError()
        let errorSessionID = activeSessionID
        sessionState = .error(message)
        self.errorActions = actions
        WindowManager.shared.showWindow()
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch { return }
            guard let self else { return }
            if case .error = self.sessionState, self.activeSessionID == errorSessionID {
                self.resetToIdle()
            }
        }
    }

    // MARK: - Error Actions

    func retryPolish() {
        guard let rawText = lastErrorRawText, !rawText.isEmpty else {
            AppLogger.log("[SessionController] retryPolish: no raw text available")
            return
        }
        guard case .error = sessionState else {
            AppLogger.log("[SessionController] retryPolish: not in error state")
            return
        }
        AppLogger.log("[SessionController#\(activeSessionID)] Retrying polish...")
        errorDismissTask?.cancel()
        errorDismissTask = nil
        useLLMPolish = true
        hasInjected = false
        sessionState = .polishing(preview: "")
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runPolishOnly(rawText: rawText, id: self.activeSessionID)
        }
    }

    private func runPolishOnly(rawText: String, id: UInt64) async {
        let composedPrompt = LLMService.composeSystemPrompt(
            fallback: ConfigurationStore.shared.current.systemPrompt
        )
        do {
            let stream = await llmService.polishText(rawText, systemPrompt: composedPrompt)
            var accumulated = ""
            for try await chunk in stream {
                guard activeSessionID == id else { throw CancellationError() }
                accumulated += chunk
                sessionState = .polishing(preview: accumulated)
            }
            let finalText = accumulated.isEmpty || accumulated == rawText ? rawText : accumulated
            await injectText(finalText, sessionID: id)
        } catch is CancellationError {
            resetToIdle()
        } catch {
            AppLogger.log("[SessionController#\(id)] Retry polish failed: \(error)")
            showError("重试失败", detail: error.localizedDescription, actions: [.copyRaw, .dismiss])
        }
    }

    func dismissError() {
        guard case .error = sessionState else { return }
        errorDismissTask?.cancel()
        errorDismissTask = nil
        resetToIdle()
    }

    // MARK: - History

    private func saveHistory(finalText: String) {
        let durationMs: UInt64?
        if let recStart = recordingStartTime {
            durationMs = UInt64(Date().timeIntervalSince(recStart) * 1000)
        } else {
            durationMs = nil
        }
        let mode: PolishMode = useLLMPolish ? (StylePackStore.shared.activePack?.baseMode ?? .structured) : .raw
        let session = DictationSession(
            rawTranscript: sessionRawTranscript,
            finalText: finalText,
            polishMode: mode,
            durationMs: durationMs
        )
        HistoryStore.shared.append(session)

        // Auto-detect corrections for dictionary (off main thread)
        if sessionRawTranscript != finalText {
            let raw = sessionRawTranscript
            let polished = finalText
            Task { @MainActor in
                detectAndAddCorrections(raw: raw, final: polished)
            }
        }

        let hitIds = DictionaryStore.shared.detectHits(in: finalText)
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
        useLLMPolish = false
        hasInjected = false
        recordingStartTime = nil
        previewText = ""
        amplitude = 0.0
        pendingPreviewText = ""
        lastErrorRawText = nil
        errorActions = []
        recordingTask?.cancel()
        recordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        previewDebounceTask?.cancel()
        previewDebounceTask = nil
        previewStreamTask?.cancel()
        previewStreamTask = nil
        errorDismissTask?.cancel()
        errorDismissTask = nil
        stopRecordingTimer()
        WindowManager.shared.hide()
    }

    // MARK: - Helpers

    private func nextSessionID() -> UInt64 {
        sessionID += 1
        return sessionID
    }

    private func checkCancellation(id: UInt64) throws {
        guard activeSessionID == id else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func micPermissionMessage(status: Int) -> String {
        if status == 0 {
            return "麦克风权限未响应。请先退出 Flowtype，重新打开后再试一次。"
        } else if status == 1 {
            return "麦克风权限已拒绝。请前往「系统设置 → 隐私与安全性 → 麦克风」，找到 Flowtype 并开启。"
        } else {
            return "请在系统设置中允许麦克风访问"
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
