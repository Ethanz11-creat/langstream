import Foundation

// MARK: - Speech Provider Protocol

protocol SpeechProvider: Sendable {
    var name: String { get }
    func transcribe(audioData: Data, timeout: TimeInterval) async throws -> String
    func transcribeWithDetails(
        audioData: Data,
        initialPrompt: String?,
        conditionOnPrevious: Bool,
        timeout: TimeInterval
    ) async throws -> TranscriptionDetail
}

extension SpeechProvider {
    func transcribeWithDetails(
        audioData: Data,
        initialPrompt: String?,
        conditionOnPrevious: Bool,
        timeout: TimeInterval
    ) async throws -> TranscriptionDetail {
        let text = try await transcribe(audioData: audioData, timeout: timeout)
        return TranscriptionDetail(text: text, segments: nil, language: nil)
    }
}

// MARK: - Provider Types

enum SpeechProviderError: Error {
    case transcriptionFailed(String)
    case networkError(Error)
    case notAvailable
    case permissionDenied
}

struct TranscriptionDetail: Sendable {
    let text: String
    let segments: [WhisperSegment]?
    let language: String?
}

struct WhisperSegment: Sendable, Codable {
    let text: String
    let start: Double
    let end: Double
    let noSpeechProb: Double
    let compressionRatio: Double
    let filtered: Bool
    let filterReason: String?

    enum CodingKeys: String, CodingKey {
        case text, start, end, filtered
        case noSpeechProb = "no_speech_prob"
        case compressionRatio = "compression_ratio"
        case filterReason = "filter_reason"
    }
}

// MARK: - Segment Pipeline Types

struct AudioSegment: Sendable {
    let index: Int
    let audioData: Data
    let duration: Double
    let overlapDuration: Double
    let cutReason: CutReason
}

enum CutReason: Sendable {
    case vadSpeechEnd
    case maxDurationReached
    case sessionEnded
}

struct SegmentResult: Sendable {
    let index: Int
    let text: String
    let quality: SegmentQuality
    let whisperSegments: [WhisperSegment]?
    let cutReason: CutReason
    let overlapDuration: Double
}

enum SegmentQuality: Sendable {
    case normal
    case empty
    case hallucination
    case fallback
}

struct TextSnapshot: Sendable {
    let stable: String
    let pending: String
    let fullText: String
}
