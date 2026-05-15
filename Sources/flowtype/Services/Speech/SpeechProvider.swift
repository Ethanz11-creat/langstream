import Foundation

// MARK: - Speech Provider Protocol

protocol SpeechProvider: Sendable {
    var name: String { get }
    func transcribe(audioData: Data, timeout: TimeInterval) async throws -> String
}

// MARK: - Provider Types

enum SpeechProviderError: Error {
    case transcriptionFailed(String)
    case networkError(Error)
    case notAvailable
    case permissionDenied
}
