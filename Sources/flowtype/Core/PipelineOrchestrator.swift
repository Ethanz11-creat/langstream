import Foundation
import AppKit

@MainActor
final class PipelineOrchestrator {
    static let shared: PipelineOrchestrator = {
        let instance = PipelineOrchestrator()
        return instance
    }()

    private let appState = AppState()
    private let audioRecorder = AudioRecorder()
    private let speechRouter = SpeechRouter()
    private let llmService = LLMService(configuration: Configuration.shared)
    private lazy var asyncRefiner = AsyncRefiner(speechRouter: speechRouter, llmService: llmService)
    private let appleSpeechProvider = AppleSpeechProvider()

    private var recordingTask: Task<Void, Never>?

    /// End-mode detection: single-tap end (raw ASR) vs double-tap end (LLM polish)
    var pendingEndModeDetection = false
    var useLLMForCurrentSession = false
    private var endModeTimer: Timer?

    // MARK: - Segmented ASR state
    /// Completed segment ASR results, keyed by insertion order.
    private var segmentResults: [Int: String] = [:]
    /// Background ASR tasks for each emitted segment.
    private var segmentTasks: [Task<Void, Never>] = []
    /// Monotonic index for the next segment.
    private var nextSegmentIndex = 0

    /// Derived from appState — single source of truth.
    var isRecording: Bool { appState.state.isRecordingIndicator }

    var state: AppState { appState }

    // MARK: - End-Mode Detection

    func beginEndModeDetection() {
        pendingEndModeDetection = true
        useLLMForCurrentSession = false
        endModeTimer?.invalidate()
        endModeTimer = Timer.scheduledTimer(timeInterval: 0.35, target: self, selector: #selector(endModeTimerFired), userInfo: nil, repeats: false)
    }

    @objc private func endModeTimerFired() {
        if pendingEndModeDetection {
            pendingEndModeDetection = false
            useLLMForCurrentSession = false
            print("[PipelineOrchestrator] End-mode timer expired → single-tap end (raw ASR)")
        }
    }

    func confirmDoubleTapEnd() {
        endModeTimer?.invalidate()
        endModeTimer = nil
        pendingEndModeDetection = false
        useLLMForCurrentSession = true
        print("[PipelineOrchestrator] Double-tap end confirmed → LLM polish enabled")
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        print("[PipelineOrchestrator] startRecording called")
        appState.clearTranscription()
        segmentResults.removeAll()
        segmentTasks.removeAll()
        nextSegmentIndex = 0

        // Show window immediately with correct state so UI never shows stale .idle
        appState.transition(to: .recording(elapsedSeconds: 0))
        WindowManager.shared.showWindow()

        recordingTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // 1. Check microphone permission (fast path if already granted)
                print("[PipelineOrchestrator] Requesting mic permission...")
                WindowManager.fileLog("Pipeline: requesting mic permission...")
                let granted = await self.audioRecorder.requestPermission()
                guard granted else {
                    print("[PipelineOrchestrator] Mic permission denied")
                    WindowManager.fileLog("Pipeline: mic permission DENIED")
                    // Provide actionable guidance for ad-hoc signed builds where the
                    // system may silently deny without showing a dialog.
                    let status = self.audioRecorder.authorizationStatus()
                    if status == 0 {
                        self.appState.showError("麦克风权限未响应。请先退出 Flowtype，重新打开后再试一次。")
                    } else if status == 1 {
                        self.appState.showError("麦克风权限已拒绝。请前往「系统设置 → 隐私与安全性 → 麦克风」，找到 Flowtype 并开启。")
                    } else {
                        self.appState.showError("请在系统设置中允许麦克风访问")
                    }
                    return
                }
                print("[PipelineOrchestrator] Mic permission granted")
                WindowManager.fileLog("Pipeline: mic permission granted")
                try Task.checkCancellation()

                // 2. Start AudioRecorder
                print("[PipelineOrchestrator] Starting AudioRecorder...")
                let output = try await self.audioRecorder.startRecording()
                print("[PipelineOrchestrator] AudioRecorder started")

                // 2.5 Set up real-time AppleSpeech preview (on-device, offline)
                self.audioRecorder.onAudioBuffer = { [weak self] buffer in
                    self?.appleSpeechProvider.appendAudioBuffer(buffer)
                }
                let previewStream = self.appleSpeechProvider.startStreamingRecognition()
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    for await text in previewStream {
                        self.appState.updatePreviewText(text)
                    }
                }

                // 3. Consume segment stream in background — each 60s chunk gets ASR’d immediately
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    for await segmentData in output.segments {
                        let index = self.nextSegmentIndex
                        self.nextSegmentIndex += 1
                        print("[PipelineOrchestrator] Received segment #\(index) (\(segmentData.count) bytes), starting ASR...")
                        let task = Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if let result = await self.asyncRefiner.transcribeWithScoring(audioData: segmentData) {
                                self.segmentResults[index] = result.text
                                print("[PipelineOrchestrator] Segment #\(index) ASR done: '\(result.text)'")
                            } else {
                                print("[PipelineOrchestrator] Segment #\(index) ASR failed")
                            }
                        }
                        self.segmentTasks.append(task)
                    }
                }

                // 4. Consume amplitude stream (blocks until stream finishes or task cancelled)
                print("[PipelineOrchestrator] Waiting for audio stream...")
                for await amplitude in output.amplitude {
                    try Task.checkCancellation()
                    self.appState.updateAmplitude(amplitude)
                }
                print("[PipelineOrchestrator] Audio stream ended")

            } catch is CancellationError {
                print("[PipelineOrchestrator] Recording task cancelled")
            } catch {
                print("[PipelineOrchestrator] Recording failed: \(error)")
                self.appState.showError("录音启动失败: \(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        print("[PipelineOrchestrator] stopRecording called, currentState=\(appState.state)")

        // Defensive: if somehow we're not actually recording, just bail
        guard isRecording else {
            print("[PipelineOrchestrator] stopRecording: not in recording state, bailing")
            return
        }

        // 1. Stop AudioRecorder — returns completed 60s segments + final partial buffer
        print("[PipelineOrchestrator] Stopping AudioRecorder...")
        let (_, finalData) = self.audioRecorder.stopRecording()
        self.audioRecorder.onAudioBuffer = nil

        // Stop AppleSpeech streaming and capture final local result
        let localPreviewText = self.appleSpeechProvider.stopStreamingRecognition()

        recordingTask?.cancel()
        recordingTask = nil

        // All remaining work is async: ASR, polish, injection.
        Task { [weak self] in
            guard let self = self else {
                print("[PipelineOrchestrator] Self deallocated during post-processing")
                return
            }

            // 2. Wait for all in-flight segment ASR tasks to complete
            print("[PipelineOrchestrator] Waiting for \(self.segmentTasks.count) segment ASR tasks...")
            for task in self.segmentTasks {
                await task.value
            }
            print("[PipelineOrchestrator] All segment ASR tasks completed")

            // 3. Build ordered text from completed segments
            let orderedSegmentTexts = (0..<self.nextSegmentIndex).compactMap { self.segmentResults[$0] }
            let combinedSegmentText = SegmentMerger.merge(orderedSegmentTexts)
            if !orderedSegmentTexts.isEmpty {
                print("[PipelineOrchestrator] Combined \(orderedSegmentTexts.count) segments (deduplicated)")
            }

            // 4. ASR the final partial buffer
            var finalASRText = ""
            if let finalData = finalData, !finalData.isEmpty {
                let wavHeaderSize = 44
                let audioPayloadSize = finalData.count - wavHeaderSize
                let estimatedDuration = Double(audioPayloadSize) / 32000.0
                print("[PipelineOrchestrator] Final audio: \(finalData.count) bytes, ~\(String(format: "%.1f", estimatedDuration))s")

                self.appState.transition(to: .processingASR(provider: "云端识别"))
                if let result = await self.asyncRefiner.transcribeWithScoring(audioData: finalData) {
                    finalASRText = result.text
                    print("[PipelineOrchestrator] Final segment ASR: '\(finalASRText)'")
                } else {
                    print("[PipelineOrchestrator] Final segment ASR failed")
                }
            } else {
                print("[PipelineOrchestrator] No final audio data")
            }

            // 5. Combine all ASR results
            var fullASRText = [combinedSegmentText, finalASRText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            // Fallback to AppleSpeech local result if cloud ASR produced nothing
            if fullASRText.isEmpty, !localPreviewText.isEmpty {
                print("[PipelineOrchestrator] Cloud ASR empty, using AppleSpeech local preview")
                fullASRText = localPreviewText
            }

            guard !fullASRText.isEmpty else {
                print("[PipelineOrchestrator] Combined ASR text is empty")
                self.appState.showError("语音识别结果为空")
                WindowManager.shared.hide()
                self.appState.transition(to: .idle)
                // Clean up state
                self.segmentResults.removeAll()
                self.segmentTasks.removeAll()
                self.nextSegmentIndex = 0
                return
            }

            // 6. Post-process combined ASR text
            let processedText = ASRPostProcessor.process(fullASRText)
            let didChange = processedText != fullASRText
            if didChange {
                print("[PipelineOrchestrator] Post-processed: '\(fullASRText)' -> '\(processedText)'")
            }

            let finalText: String
            if processedText.isEmpty {
                print("[PipelineOrchestrator] Post-processed text is empty, falling back to raw ASR text")
                finalText = fullASRText.trimmingCharacters(in: .whitespaces)
            } else {
                finalText = processedText
            }

            // 7. Display recognized text in capsule (local rendering)
            self.appState.recognizedText = finalText
            self.appState.previewText = finalText
            print("[PipelineOrchestrator] Recognized combined text: '\(finalText)'")

            // 8. Wait for end-mode detection to complete (if still pending)
            if self.pendingEndModeDetection {
                print("[PipelineOrchestrator] Waiting for end-mode detection...")
                let startTime = Date()
                while self.pendingEndModeDetection && Date().timeIntervalSince(startTime) < 0.4 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                print("[PipelineOrchestrator] End-mode detection complete, useLLM=\(self.useLLMForCurrentSession)")
            }

            // 9. Determine text to inject based on end mode
            let textToInject: String
            print("[PipelineOrchestrator] useLLMForCurrentSession=\(self.useLLMForCurrentSession)")
            if self.useLLMForCurrentSession {
                // Double-tap end: LLM polish path (polish the *combined* text)
                self.appState.transition(to: .polishing(preview: ""))
                print("[PipelineOrchestrator] *** DOUBLE-TAP END: starting LLM polish ***")
                do {
                    let stream = await self.llmService.polishText(finalText)
                    var polished = ""
                    for try await chunk in stream {
                        polished += chunk
                        self.appState.updatePolishingPreview(polished)
                    }
                    if !polished.isEmpty && polished != finalText {
                        textToInject = polished
                        self.appState.recognizedText = polished
                        self.appState.previewText = polished
                        print("[PipelineOrchestrator] *** LLM polished: '\(polished)' ***")
                    } else {
                        print("[PipelineOrchestrator] LLM polish returned empty/same, using raw text")
                        textToInject = finalText
                    }
                } catch {
                    print("[PipelineOrchestrator] LLM polish failed: \(error)")
                    textToInject = finalText
                }
            } else {
                // Single-tap end: raw ASR text (concatenated from all segments)
                textToInject = finalText
                print("[PipelineOrchestrator] *** SINGLE-TAP END: injecting raw ASR text ***")
            }

            // Reset end-mode flags
            self.pendingEndModeDetection = false
            self.useLLMForCurrentSession = false

            // Clean up segment state
            self.segmentResults.removeAll()
            self.segmentTasks.removeAll()
            self.nextSegmentIndex = 0

            // 10. Hide window before injection so focus returns to previous app
            WindowManager.shared.hide()
            // Give OS time to switch focus back to the target app
            try? await Task.sleep(nanoseconds: 80_000_000)

            // 11. Inject final text
            self.appState.transition(to: .injecting)
            print("[PipelineOrchestrator] Injecting '\(textToInject)'...")
            do {
                try await KeyboardInjector.insertText(textToInject)
                print("[PipelineOrchestrator] Text injected successfully")
            } catch {
                print("[PipelineOrchestrator] Injection failed: \(error)")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(textToInject, forType: .string)
                self.appState.showError("已复制到剪贴板")
            }

            // Hide window after everything completes
            WindowManager.shared.hide()
            self.appState.transition(to: .idle)
        }
    }
}
