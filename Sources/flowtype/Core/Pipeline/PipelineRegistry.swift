import Foundation

// MARK: - PipelineRegistry

/// Registry for the default pipeline configuration.
enum PipelineRegistry {
    /// Returns the default ordered list of pipeline stages.
    static func defaultPipeline() -> [PipelineStage] {
        [
            RecordingStage(),
            ASRStage(),
            PostProcessStage(),
            PolishStage(),
            InjectionStage(),
        ]
    }

    /// Returns the default list of session observers.
    static func defaultObservers() -> [SessionObserver] {
        [AudioFeedbackObserver()]
    }
}
