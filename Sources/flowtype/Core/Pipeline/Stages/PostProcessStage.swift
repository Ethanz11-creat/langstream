import Foundation

// MARK: - PostProcessStage

/// Pipeline stage that applies ASR post-processing: filler stripping,
/// repetition detection, tech term correction, and Chinese punctuation.
///
/// Input: `.transcript(String)`
/// Output: `.processed(String, raw: String)`
final class PostProcessStage: PipelineStage, @unchecked Sendable {

    var name: String { "PostProcess" }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[PostProcessStage#\(sessionID)] Started")
        let startTime = Date()

        // Extract input payload
        let text: String
        switch payload {
        case .transcript(let transcript):
            text = transcript
        default:
            AppLogger.log("[PostProcessStage#\(sessionID)] Unexpected payload: \(payload), expected .transcript")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: PostProcessStageError.invalidPayload,
                rawText: nil,
                retryable: false
            ))
        }

        // Apply post-processing
        let processed = ASRPostProcessor.process(text)
        let result = processed.isEmpty ? text.trimmingCharacters(in: .whitespaces) : processed

        AppLogger.log("[PostProcessStage#\(sessionID)] Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s: \(result.count) chars")

        guard !result.isEmpty else {
            AppLogger.log("[PostProcessStage#\(sessionID)] Empty text after post-processing")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: PostProcessStageError.emptyResult,
                rawText: text,
                retryable: false
            ))
        }

        return .continue(.processed(result, raw: text))
    }
}

// MARK: - PostProcessStage Errors

enum PostProcessStageError: Error {
    case invalidPayload
    case emptyResult
}
