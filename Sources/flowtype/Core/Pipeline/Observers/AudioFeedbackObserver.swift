import Foundation

// MARK: - AudioFeedbackObserver

/// Observes session state transitions and plays audio feedback sounds when enabled.
final class AudioFeedbackObserver: SessionObserver {

    func sessionDidTransition(from oldState: SessionState, to newState: SessionState, context: SessionContext) {
        guard ConfigurationStore.shared.current.enableAudioFeedback else { return }

        switch (oldState, newState) {
        case (_, .recording):
            SoundFeedback.playRecordingStart()
        case (.recording, .processing):
            SoundFeedback.playRecordingStop()
        case (.idle, .error),
             (.recording, .error),
             (.processing, .error),
             (.polishing, .error),
             (.injecting, .error):
            SoundFeedback.playError()
        default:
            break
        }
    }
}
