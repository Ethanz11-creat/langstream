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
    private var streamingTask: Task<Void, Never>?
    private var previewStreamTask: Task<Void, Never>?

    // MARK: - Audio Slicing

    private var collectedSlices: [AudioSlice] = []
    private var streamingResults: [Int: String] = [:]

    // MARK: - Recording Timer

    private var recordingTimer = CancellableTimer()
    private var elapsedSeconds: Int = 0

    // MARK: - Preview Debounce

    private var previewDebounceTask: Task<Void, Never>?
    private var pendingPreviewText: String = ""

    // MARK: - Injection Guard

    private var hasInjected: Bool = false

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
        collectedSlices.removeAll()
        streamingResults.removeAll()
        streamingTask = nil
        recordingStartTime = Date()

        previewText = ""
        amplitude = 0.0
        pendingPreviewText = ""
        previewDebounceTask?.cancel()
        previewDebounceTask = nil

        sessionState = .recording(elapsedSeconds: 0)
        startRecordingTimer()
        WindowManager.shared.showWindow()

        recordingTask = Task { [weak self] in
            guard let self else { return }
            await self.runRecordingSession(id: newID)
        }
    }

    func endRecording(withPolish: Bool) {
        AppLogger.log("[SessionController#\(activeSessionID)] endRecording called, withPolish=\(withPolish)")

        guard isRecording else {
            AppLogger.log("[SessionController#\(activeSessionID)] endRecording: not recording, ignoring")
            return
        }

        useLLMPolish = withPolish
        stopRecordingTimer()

        recordingTask?.cancel()
        recordingTask = nil

        sessionState = .processing(provider: WhisperServerManager.shared.isServerReady ? "本地识别" : "本地识别(兜底)")

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
        streamingTask?.cancel()
        streamingTask = nil
        previewStreamTask?.cancel()
        previewStreamTask = nil

        audioRecorder.onAudioBuffer = nil
        audioRecorder.onRecordingFrozen = nil
        _ = audioRecorder.stopRecording()
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

            let output = try await audioRecorder.startRecording()
            AppLogger.log("[SessionController#\(id)] AudioRecorder started")

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

            self.streamingTask = Task { [weak self] in
                guard let self else { return }
                await self.runStreamingTranscription(id: id, sliceStream: output.slices)
            }

            AppLogger.log("[SessionController#\(id)] Waiting for audio stream...")
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

    // MARK: - Streaming Transcription Phase

    private func runStreamingTranscription(id: UInt64, sliceStream: AsyncStream<AudioSlice>) async {
        AppLogger.log("[SessionController#\(id)] Streaming transcription started")
        let startTime = Date()
        defer {
            let elapsed = Date().timeIntervalSince(startTime)
            AppLogger.log("[SessionController#\(id)] Streaming transcription ended in \(String(format: "%.1f", elapsed))s")
        }

        let provider = speechRouter.primaryProvider
        let maxWorkers = 2

        await withTaskGroup(of: (index: Int, text: String?).self) { group in
            var iterator = sliceStream.makeAsyncIterator()
            var activeCount = 0
            var streamEnded = false

            repeat {
                while activeCount < maxWorkers && !streamEnded {
                    if let slice = await iterator.next() {
                        guard self.activeSessionID == id else { break }

                        self.collectedSlices.append(slice)

                        group.addTask { [provider] in
                            do {
                                let text = try await provider.transcribe(audioData: slice.audioData, timeout: 300)
                                return (slice.index, text)
                            } catch {
                                AppLogger.log("[SessionController#\(id)] Slice #\(slice.index) failed: \(error)")
                                return (slice.index, nil)
                            }
                        }
                        activeCount += 1
                    } else {
                        streamEnded = true
                        break
                    }
                }

                if activeCount > 0 {
                    if let completed = await group.next() {
                        activeCount -= 1
                        if let text = completed.text {
                            self.streamingResults[completed.index] = text
                        }
                    }
                }
            } while activeCount > 0 || !streamEnded
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
        _ = audioRecorder.stopRecording()
        audioRecorder.onAudioBuffer = nil
        audioRecorder.onRecordingFrozen = nil
        AppLogger.log("[SessionController#\(id)] AudioRecorder stopped in \(String(format: "%.2f", Date().timeIntervalSince(stopAudioStart)))s")

        let localPreviewText = appleSpeechProvider.stopStreamingRecognition()
        AppLogger.log("[SessionController#\(id)] AppleSpeech final preview: '\(localPreviewText.prefix(80))'")

        let waitStreamStart = Date()
        let streamCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.streamingTask?.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        if !streamCompleted {
            AppLogger.log("[SessionController#\(id)] Streaming transcription timed out after 30s")
            streamingTask?.cancel()
        }
        streamingTask = nil
        AppLogger.log("[SessionController#\(id)] Waited for streaming in \(String(format: "%.2f", Date().timeIntervalSince(waitStreamStart)))s, results: \(streamingResults.count)/\(collectedSlices.count) slices")

        let mergeStart = Date()
        let maxIndex = collectedSlices.map(\.index).max() ?? 0
        var allTexts = orderedTexts(from: streamingResults, maxIndex: maxIndex)

        var finalASRText = allTexts.joined(separator: " ")
        AppLogger.log("[SessionController#\(id)] Merged ASR text (streaming): '\(finalASRText.prefix(80))' (merge took \(String(format: "%.2f", Date().timeIntervalSince(mergeStart)))s)")

        if finalASRText.isEmpty, !collectedSlices.isEmpty {
            AppLogger.log("[SessionController#\(id)] Streaming produced nothing, falling back to batch transcription")
            let fallbackStart = Date()
            let transcriber = ParallelTranscriber(provider: speechRouter.primaryProvider, maxWorkers: 2)
            let results = await transcriber.transcribe(slices: collectedSlices, timeout: 300)
            allTexts += orderedTexts(from: results, maxIndex: maxIndex)
            finalASRText = allTexts.joined(separator: " ")
            AppLogger.log("[SessionController#\(id)] Fallback ASR result: '\(finalASRText.prefix(80))' (took \(String(format: "%.1f", Date().timeIntervalSince(fallbackStart)))s)")
        }

        if finalASRText.isEmpty, !localPreviewText.isEmpty {
            AppLogger.log("[SessionController#\(id)] Using AppleSpeech preview as fallback")
            finalASRText = localPreviewText
        }

        let postProcessStart = Date()
        let processedText = ASRPostProcessor.process(finalASRText)
        let textToUse = processedText.isEmpty ? finalASRText.trimmingCharacters(in: .whitespaces) : processedText
        AppLogger.log("[SessionController#\(id)] Post-processed in \(String(format: "%.2f", Date().timeIntervalSince(postProcessStart)))s: '\(textToUse.prefix(80))'")

        guard !textToUse.isEmpty else {
            AppLogger.log("[SessionController#\(id)] Empty text, aborting")
            showError("语音识别结果为空")
            return
        }

        if useLLMPolish {
            let polishStart = Date()
            sessionState = .polishing(preview: "")

            var polishedText: String? = nil
            do {
                let stream = await llmService.polishText(textToUse)
                var accumulated = ""
                for try await chunk in stream {
                    guard activeSessionID == id else { throw CancellationError() }
                    accumulated += chunk
                    sessionState = .polishing(preview: accumulated)
                }
                if !accumulated.isEmpty && accumulated != textToUse {
                    polishedText = accumulated
                    AppLogger.log("[SessionController#\(id)] LLM polished in \(String(format: "%.1f", Date().timeIntervalSince(polishStart)))s: '\(accumulated.prefix(100))'")
                } else {
                    AppLogger.log("[SessionController#\(id)] LLM returned empty/same, using raw")
                }
            } catch is CancellationError {
                AppLogger.log("[SessionController#\(id)] LLM polish cancelled")
                resetToIdle()
                return
            } catch {
                AppLogger.log("[SessionController#\(id)] LLM polish failed: \(error)")
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
            return
        }
        hasInjected = true
        AppLogger.log("[SessionController#\(sessionID)] Injection phase started")
        let injectStart = Date()

        sessionState = .injecting
        WindowManager.shared.hide()

        try? await Task.sleep(nanoseconds: 100_000_000)

        guard activeSessionID == sessionID else {
            AppLogger.log("[SessionController#\(sessionID)] Session changed before injection, aborting")
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
            return
        }

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
        recordingTimer.schedule(withTimeInterval: 1.0, repeats: true) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.elapsedSeconds += 1
                self.sessionState = .recording(elapsedSeconds: self.elapsedSeconds)
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

    private func showError(_ message: String) {
        let errorSessionID = activeSessionID
        sessionState = .error(message)
        WindowManager.shared.showWindow()
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch { return }
            guard let self else { return }
            if case .error = self.sessionState, self.activeSessionID == errorSessionID {
                self.resetToIdle()
            }
        }
    }

    // MARK: - Reset

    private func resetToIdle() {
        sessionState = .idle
        activeSessionID = 0
        useLLMPolish = false
        hasInjected = false
        collectedSlices.removeAll()
        streamingResults.removeAll()
        recordingStartTime = nil
        previewText = ""
        amplitude = 0.0
        pendingPreviewText = ""
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

    private func orderedTexts(from dict: [Int: String], maxIndex: Int) -> [String] {
        guard maxIndex >= 1 else { return [] }
        return (1...maxIndex).compactMap { i in
            guard let text = dict[i], !text.isEmpty else { return nil }
            return text
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
