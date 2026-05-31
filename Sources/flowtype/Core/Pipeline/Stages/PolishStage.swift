import Foundation

// MARK: - PolishStage

/// Pipeline stage that optionally polishes text via LLM streaming API.
///
/// Input: `.processed(String, raw: String)`
/// Output: `.polished(String, raw: String)`
final class PolishStage: PipelineStage, @unchecked Sendable {

    var name: String { "Polish" }

    private let llmService = LLMService()

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[PolishStage#\(sessionID)] Started")
        let startTime = Date()

        // Extract input payload
        let text: String
        let rawText: String
        switch payload {
        case .processed(let processedText, let raw):
            text = processedText
            rawText = raw
        default:
            AppLogger.log("[PolishStage#\(sessionID)] Unexpected payload: \(payload), expected .processed")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: PolishStageError.invalidPayload,
                rawText: nil,
                retryable: false
            ))
        }

        // Check if polish is enabled
        let usePolish = await MainActor.run { context.usePolish }
        guard usePolish else {
            AppLogger.log("[PolishStage#\(sessionID)] Polish disabled, passing through")
            return .continue(.polished(text, raw: rawText))
        }

        // Compose system prompt (must be done on MainActor)
        let composedPrompt = await MainActor.run {
            LLMService.composeSystemPrompt(fallback: ConfigurationStore.shared.current.systemPrompt)
        }

        AppLogger.log("[PolishStage#\(sessionID)] Starting LLM polish")

        // Start polishing state
        await MainActor.run {
            context.statePublisher.send(.polishing(preview: ""))
        }

        var polishedText: String? = nil
        do {
            let stream = await llmService.polishText(text, systemPrompt: composedPrompt)
            var accumulated = ""
            for try await chunk in stream {
                accumulated += chunk
                await MainActor.run {
                    context.statePublisher.send(.polishing(preview: accumulated))
                }
            }
            if !accumulated.isEmpty && accumulated != text {
                polishedText = accumulated
                AppLogger.log("[PolishStage#\(sessionID)] LLM polished in \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s: \(accumulated.count) chars")
            } else {
                AppLogger.log("[PolishStage#\(sessionID)] LLM returned empty/same, using raw")
            }
        } catch is CancellationError {
            AppLogger.log("[PolishStage#\(sessionID)] LLM polish cancelled")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: CancellationError(),
                rawText: rawText,
                retryable: false
            ))
        } catch {
            AppLogger.log("[PolishStage#\(sessionID)] LLM polish failed: \(error)")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: error,
                rawText: rawText,
                retryable: true
            ))
        }

        let finalText = polishedText ?? text
        return .continue(.polished(finalText, raw: rawText))
    }
}

// MARK: - PolishStage Errors

enum PolishStageError: Error {
    case invalidPayload
}
