import Foundation

/// Manages asynchronous ASR with local MLX Whisper and AppleSpeech fallback.
@MainActor
final class AsyncRefiner {
    private let speechRouter: SpeechRouter
    private let llmService: LLMService
    private let scorer = ASRResultScorer()

    init(speechRouter: SpeechRouter, llmService: LLMService) {
        self.speechRouter = speechRouter
        self.llmService = llmService
    }

    // MARK: - Public API

    /// Transcribe audio using MLXWhisper, fall back to AppleSpeech if unavailable or failed.
    func transcribeWithScoring(audioData: Data) async -> TranscriptionResult? {
        let serverReady = WhisperServerManager.shared.isServerReady

        // Primary: MLXWhisper (if server is ready)
        if serverReady {
            do {
                let text = try await self.speechRouter.primaryProvider.transcribe(
                    audioData: audioData,
                    timeout: 30
                )
                if !text.isEmpty {
                    print("[AsyncRefiner] MLXWhisper succeeded: '\(text)'")
                    return TranscriptionResult(text: text, provider: "MLXWhisper", isFallback: false, duration: 0)
                }
            } catch {
                print("[AsyncRefiner] MLXWhisper failed: \(error)")
            }
        } else {
            print("[AsyncRefiner] MLXWhisper server not ready, skipping")
        }

        // Fallback: AppleSpeech local (offline)
        do {
            let text = try await self.speechRouter.fallbackProvider.transcribe(audioData: audioData, timeout: 10)
            if !text.isEmpty {
                print("[AsyncRefiner] AppleSpeech fallback succeeded")
                return TranscriptionResult(text: text, provider: "AppleSpeech", isFallback: true, duration: 0)
            }
        } catch {
            print("[AsyncRefiner] AppleSpeech fallback failed: \(error)")
        }

        return nil
    }

    /// Original sequential fallback (kept for compatibility).
    func transcribeWithFallback(audioData: Data) async -> TranscriptionResult? {
        return await transcribeWithScoring(audioData: audioData)
    }

    /// LLM polish — UI only, no delta injection
    func polishIfNeeded(text: String, appState: AppState) async {
        guard LLMService.shouldPolish(text) != nil else {
            print("[AsyncRefiner] Skipping LLM polish for low-value text")
            return
        }

        appState.transition(to: .polishing(preview: ""))
        var polishedText = ""

        do {
            let stream = await llmService.polishText(text)
            for try await chunk in stream {
                polishedText += chunk
                appState.updatePolishingPreview(polishedText)
            }

            if !polishedText.isEmpty && polishedText != text {
                print("[AsyncRefiner] LLM polished: '\(polishedText)'")
                // UI update only — do NOT re-inject
                appState.recognizedText = polishedText
                appState.previewText = polishedText
            }
        } catch LLMError.timeout {
            print("[AsyncRefiner] LLM polish timed out, keeping ASR text")
        } catch {
            print("[AsyncRefiner] LLM polish failed: \(error)")
        }
    }

    /// Text-only segment refinement during recording (Phase 2)
    func refineSegmentText(text: String, appState: AppState) async {
        guard LLMService.shouldPolish(text) != nil else {
            print("[AsyncRefiner] Skipping text-only refinement for: '\(text)'")
            return
        }

        appState.isRefining = true
        defer { appState.isRefining = false }

        do {
            let stream = await self.llmService.polishText(text)
            var polishedText = ""
            for try await chunk in stream {
                polishedText += chunk
            }
            if !polishedText.isEmpty && polishedText != text {
                print("[AsyncRefiner] Segment polished: '\(polishedText)'")
                appState.stableText = appState.stableText.replacingOccurrences(of: text, with: polishedText)
            }
        } catch LLMError.timeout {
            print("[AsyncRefiner] Segment LLM timed out")
        } catch {
            print("[AsyncRefiner] Segment LLM failed: \(error)")
        }
    }
}
