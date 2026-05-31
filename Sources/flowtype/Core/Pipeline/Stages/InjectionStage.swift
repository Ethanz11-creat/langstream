import Foundation
import AppKit

// MARK: - InjectionStage

/// Pipeline stage that injects text into the active application.
///
/// Input: `.polished(String, raw: String)`
/// Output: `.complete`
final class InjectionStage: PipelineStage, @unchecked Sendable {

    var name: String { "Injection" }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[InjectionStage#\(sessionID)] Started")
        let startTime = Date()

        // Extract input payload
        let text: String
        switch payload {
        case .polished(let polishedText, _):
            text = polishedText
        default:
            AppLogger.log("[InjectionStage#\(sessionID)] Unexpected payload: \(payload), expected .polished")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: InjectionStageError.invalidPayload,
                rawText: nil,
                retryable: false
            ))
        }

        // Guard against double injection
        let hasInjected = await MainActor.run { context.hasInjected }
        guard !hasInjected else {
            AppLogger.log("[InjectionStage#\(sessionID)] Duplicate injection blocked")
            return .complete
        }
        await MainActor.run {
            context.hasInjected = true
        }

        // Security: capture target application before injection
        let targetApp = NSWorkspace.shared.frontmostApplication
        let targetBundleID = targetApp?.bundleIdentifier ?? "unknown"
        AppLogger.log("[InjectionStage#\(sessionID)] Target app: \(targetBundleID)")

        // Update state to injecting
        await MainActor.run {
            context.statePublisher.send(.injecting)
        }

        // Brief delay to allow UI to settle
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Security: verify target app hasn't changed before injecting
        let currentApp = NSWorkspace.shared.frontmostApplication
        if currentApp?.bundleIdentifier != targetBundleID {
            AppLogger.log("[InjectionStage#\(sessionID)] Target app changed from \(targetBundleID) to \(currentApp?.bundleIdentifier ?? "nil"), aborting injection")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: InjectionStageError.targetAppChanged,
                rawText: text,
                retryable: false
            ))
        }

        // Perform injection
        do {
            try await KeyboardInjector.insertText(text)
            AppLogger.log("[InjectionStage#\(sessionID)] Text injected successfully in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
        } catch {
            AppLogger.log("[InjectionStage#\(sessionID)] Injection failed: \(error)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: error,
                rawText: text,
                retryable: false
            ))
        }

        return .complete
    }
}

// MARK: - InjectionStage Errors

enum InjectionStageError: Error {
    case invalidPayload
    case targetAppChanged
}
