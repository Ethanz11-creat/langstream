import Foundation

// MARK: - SessionObserver

/// Protocol for types that observe session state transitions.
///
/// Observers are notified on the MainActor after every state change.
/// Typical implementations include analytics, history logging, and UI updates.
protocol SessionObserver: AnyObject {
    /// Called when the session transitions from one state to another.
    ///
    /// - Parameters:
    ///   - oldState: The previous session state.
    ///   - newState: The new session state.
    ///   - context: The shared session context.
    func sessionDidTransition(
        from oldState: SessionState,
        to newState: SessionState,
        context: SessionContext
    )
}
