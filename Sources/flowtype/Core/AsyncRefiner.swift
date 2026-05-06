import Foundation

/// Manages asynchronous refinement:
/// 1. Concurrent cloud ASR (TeleSpeech + SenseVoice race with scoring)
/// 2. Non-blocking LLM polish (UI only)
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

    /// Transcribe audio using parallel TeleSpeech + SenseVoice with result scoring.
    /// Falls back to sequential if ASR_STRATEGY=fallback.
    func transcribeWithScoring(audioData: Data) async -> TranscriptionResult? {
        let strategy = Configuration.shared.asrStrategy

        if strategy == .fallback {
            return await transcribeWithFallback(audioData: audioData)
        }

        // Parallel strategy — async let ensures both start immediately
        async let teleResult: String? = try? self.speechRouter.primaryProvider.transcribe(
            audioData: audioData,
            timeout: 8
        )
        async let senseResult: String? = try? self.speechRouter.fallbackProvider.transcribe(
            audioData: audioData,
            timeout: 5
        )

        let teleText = await teleResult
        let senseText = await senseResult

        var results: [ASRScoredResult] = []

        if let text = teleText, !text.isEmpty {
            let scored = scorer.score(text, provider: "TeleSpeech")
            results.append(scored)
            print("[AsyncRefiner] TeleSpeech raw: '\(text)' score: \(String(format: "%.2f", scored.score))")
        } else {
            print("[AsyncRefiner] TeleSpeech failed or empty")
        }

        if let text = senseText, !text.isEmpty {
            let scored = scorer.score(text, provider: "SenseVoice")
            results.append(scored)
            print("[AsyncRefiner] SenseVoice raw: '\(text)' score: \(String(format: "%.2f", scored.score))")
        } else {
            print("[AsyncRefiner] SenseVoice failed or empty")
        }

        // Try local AppleSpeech as last resort if both cloud providers failed
        if results.isEmpty {
            do {
                let text = try await self.speechRouter.localProvider.transcribe(audioData: audioData, timeout: 10)
                if !text.isEmpty {
                    print("[AsyncRefiner] AppleSpeech local fallback succeeded")
                    return TranscriptionResult(text: text, provider: "AppleSpeech", isFallback: true, duration: 0)
                }
            } catch {
                print("[AsyncRefiner] AppleSpeech local fallback failed: \(error)")
            }
        }

        guard let best = results.max(by: { $0.score < $1.score }) else {
            return nil
        }

        let isFallback = best.provider != "TeleSpeech"
        print("[AsyncRefiner] Selected: \(best.provider) with score \(String(format: "%.2f", best.score))")
        return TranscriptionResult(text: best.text, provider: best.provider, isFallback: isFallback, duration: 0)
    }

    /// Original sequential fallback (kept for compatibility and env override).
    func transcribeWithFallback(audioData: Data) async -> TranscriptionResult? {
        // TeleSpeech first — usually better quality for Chinese
        do {
            let text = try await self.speechRouter.primaryProvider.transcribe(
                audioData: audioData,
                timeout: 8
            )
            if !text.isEmpty {
                print("[AsyncRefiner] TeleSpeech succeeded")
                return TranscriptionResult(text: text, provider: "TeleSpeech", isFallback: false, duration: 0)
            }
        } catch {
            print("[AsyncRefiner] TeleSpeech failed: \(error)")
        }

        // Fallback to SenseVoice
        do {
            let text = try await self.speechRouter.fallbackProvider.transcribe(
                audioData: audioData,
                timeout: 5
            )
            if !text.isEmpty {
                print("[AsyncRefiner] SenseVoice fallback succeeded")
                return TranscriptionResult(text: text, provider: "SenseVoice", isFallback: true, duration: 0)
            }
        } catch {
            print("[AsyncRefiner] SenseVoice fallback failed: \(error)")
        }

        // Final fallback: local AppleSpeech (offline)
        do {
            let text = try await self.speechRouter.localProvider.transcribe(audioData: audioData, timeout: 10)
            if !text.isEmpty {
                print("[AsyncRefiner] AppleSpeech local fallback succeeded")
                return TranscriptionResult(text: text, provider: "AppleSpeech", isFallback: true, duration: 0)
            }
        } catch {
            print("[AsyncRefiner] AppleSpeech local fallback failed: \(error)")
        }

        return nil
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

private extension Character {
    var isChinese: Bool {
        return "\u{4E00}" <= self && self <= "\u{9FFF}"
    }
}
