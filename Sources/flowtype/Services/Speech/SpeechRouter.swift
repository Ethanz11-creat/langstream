import Foundation

final class SpeechRouter: @unchecked Sendable {
    static let shared = SpeechRouter()

    let qwenProvider: QwenASRProvider
    let fallbackProvider: AppleSpeechProvider

    private init() {
        self.qwenProvider = QwenASRProvider()
        self.fallbackProvider = AppleSpeechProvider()
    }
}
