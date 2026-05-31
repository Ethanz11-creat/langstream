import Foundation

// MARK: - StagePayload

/// Strongly-typed data passed between pipeline stages.
enum StagePayload {
    case empty
    case audio(samples: [Float], previewText: String)
    case transcript(String)
    case processed(String, raw: String)
    case polished(String, raw: String)
}

// MARK: - StageResult

/// What a stage returns after execution.
enum StageResult {
    /// Continue to the next stage with the given payload.
    case `continue`(StagePayload)

    /// Skip to a named stage with the given payload.
    case skip(to: String, StagePayload)

    /// Suspend the pipeline for error recovery.
    case suspend(ErrorRecoveryContext)

    /// Pipeline completed successfully.
    case complete
}

// MARK: - ErrorRecoveryContext

/// Context for retryable error cards displayed to the user.
struct ErrorRecoveryContext {
    let failedStage: String
    let error: Error
    let rawText: String?
    let retryable: Bool
}

// MARK: - PipelineStage

/// Protocol defining a single stage in the pipeline.
///
/// Stages are executed sequentially. Errors are communicated via `.suspend()`
/// rather than thrown, keeping the protocol simple and allowing the orchestrator
/// to present retryable error cards.
protocol PipelineStage {
    /// Human-readable name for diagnostics and logging.
    var name: String { get }

    /// Execute this stage.
    ///
    /// - Parameters:
    ///   - payload: Input data from the previous stage.
    ///   - context: Shared session context (MainActor-isolated).
    /// - Returns: A `StageResult` directing the orchestrator how to proceed.
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult
}
