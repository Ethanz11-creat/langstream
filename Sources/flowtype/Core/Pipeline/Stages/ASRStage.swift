import Foundation

// MARK: - ASRStage

/// Pipeline stage that performs batch ASR transcription using Qwen3-ASR
/// with AppleSpeech fallback.
///
/// Input: `.audio(samples: [Float], previewText: String)`
/// Output: `.transcript(String)`
final class ASRStage: PipelineStage, @unchecked Sendable {

    var name: String { "ASR" }

    private let speechRouter = SpeechRouter.shared

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[ASRStage#\(sessionID)] Processing phase started")
        let processingStartTime = Date()

        defer {
            let totalProcessingTime = Date().timeIntervalSince(processingStartTime)
            AppLogger.log("[ASRStage#\(sessionID)] Processing phase ended (total: \(String(format: "%.1f", totalProcessingTime))s)")
        }

        // Extract input payload
        let rawSamples: [Float]
        let localPreviewText: String
        switch payload {
        case .audio(let samples, let previewText):
            rawSamples = samples
            localPreviewText = previewText
        default:
            AppLogger.log("[ASRStage#\(sessionID)] Unexpected payload: \(payload), expected .audio")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: ASRStageError.invalidPayload,
                rawText: nil,
                retryable: false
            ))
        }

        let audioDuration = Double(rawSamples.count) / 16000.0
        AppLogger.log("[ASRStage#\(sessionID)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")

        var finalASRText = ""

        // 1. Try Qwen3-ASR batch transcription if loaded and samples exist
        if speechRouter.qwenProvider.isLoaded && !rawSamples.isEmpty {
            AppLogger.log("[ASRStage#\(sessionID)] Using Qwen3-ASR batch transcription")
            await MainActor.run {
                context.statePublisher.send(.processing(provider: "Qwen3-ASR"))
            }

            let asrStart = Date()
            do {
                finalASRText = try await speechRouter.qwenProvider.transcribe(
                    samples: rawSamples,
                    language: nil,
                    context: nil
                )
                AppLogger.log("[ASRStage#\(sessionID)] Qwen3-ASR completed in \(String(format: "%.2f", Date().timeIntervalSince(asrStart)))s: \(finalASRText.count) chars")
            } catch is CancellationError {
                AppLogger.log("[ASRStage#\(sessionID)] Qwen3-ASR cancelled")
                return .suspend(ErrorRecoveryContext(
                    failedStage: name,
                    error: CancellationError(),
                    rawText: nil,
                    retryable: false
                ))
            } catch {
                AppLogger.log("[ASRStage#\(sessionID)] Qwen3-ASR failed: \(error)")
                finalASRText = ""
            }
        }

        // 2. Fallback to AppleSpeech preview text if Qwen failed or returned empty
        if finalASRText.isEmpty, !localPreviewText.isEmpty {
            AppLogger.log("[ASRStage#\(sessionID)] Using AppleSpeech preview as fallback")
            finalASRText = localPreviewText
        }

        // 3. Validate result
        guard !finalASRText.isEmpty else {
            AppLogger.log("[ASRStage#\(sessionID)] Empty text after ASR and fallback")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: ASRStageError.emptyResult,
                rawText: nil,
                retryable: false
            ))
        }

        return .continue(.transcript(finalASRText))
    }
}

// MARK: - ASRStage Errors

enum ASRStageError: Error {
    case invalidPayload
    case emptyResult
}
