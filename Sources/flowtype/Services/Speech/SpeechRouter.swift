import Foundation

final class SpeechRouter: @unchecked Sendable {
    let qwenProvider: QwenASRProvider
    let fallbackProvider: AppleSpeechProvider

    init() {
        self.qwenProvider = QwenASRProvider()
        self.fallbackProvider = AppleSpeechProvider()
    }
}
