import Foundation

// MARK: - AudioFeedbackObserver

/// Observes session state transitions and plays audio feedback sounds when enabled.
final class AudioFeedbackObserver: SessionObserver {
    let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
    }

    func sessionDidTransition(from oldState: SessionState, to newState: SessionState, context: SessionContext) {
        guard isEnabled() else { return }

        switch (oldState, newState) {
        case (_, .recording):
            SoundFeedback.playRecordingStart()
        case (.recording, .processing):
            SoundFeedback.playRecordingStop()
        case (_, .error):
            SoundFeedback.playError()
        default:
            break
        }
    }
}
