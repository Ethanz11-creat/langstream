import Foundation

final class SpeechRouter: @unchecked Sendable {
    let primaryProvider: MLXWhisperProvider
    let fallbackProvider: AppleSpeechProvider

    init() {
        self.primaryProvider = MLXWhisperProvider()
        self.fallbackProvider = AppleSpeechProvider()
    }
}
