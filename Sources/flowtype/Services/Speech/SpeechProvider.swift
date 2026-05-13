import Foundation

protocol SpeechProvider: Sendable {
    var name: String { get }
    func transcribe(audioData: Data, timeout: TimeInterval) async throws -> String
}

enum SpeechProviderError: Error {
    case transcriptionFailed(String)
    case networkError(Error)
    case notAvailable
    case permissionDenied
}

struct TranscriptionResult {
    let text: String
    let provider: String
    let isFallback: Bool
    let duration: TimeInterval
}
