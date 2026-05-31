import Foundation

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the onboarding demo receives final text from the pipeline.
    /// The `object` is the text string.
    static let onboardingDemoTextReceived = Notification.Name("onboardingDemoTextReceived")
}

// MARK: - OnboardingPipeline

/// Provides a pipeline configuration for the onboarding demo step.
///
/// The demo replaces the standard `InjectionStage` with `DemoInjectionStage`,
/// which delivers the final text via `NotificationCenter` instead of injecting
/// it into the active application.
enum OnboardingPipeline {
    static func makeStages() -> [PipelineStage] {
        var stages = PipelineRegistry.defaultPipeline()
        if let idx = stages.firstIndex(where: { $0 is InjectionStage }) {
            stages[idx] = DemoInjectionStage()
        }
        return stages
    }
}

// MARK: - DemoInjectionStage

/// Pipeline stage that delivers text via NotificationCenter instead of injecting into the active app.
///
/// Input: `.polished(String, raw: String)`
/// Output: `.complete`
struct DemoInjectionStage: PipelineStage {
    var name: String { "DemoInjectionStage" }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .polished(let text, _) = payload else { return .continue(payload) }
        await MainActor.run {
            NotificationCenter.default.post(name: .onboardingDemoTextReceived, object: text)
        }
        return .complete
    }
}
