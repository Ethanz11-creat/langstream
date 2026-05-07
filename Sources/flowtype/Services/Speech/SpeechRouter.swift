import Foundation
import AVFoundation

final class SpeechRouter: @unchecked Sendable {
    let primaryProvider: MLXWhisperProvider
    let fallbackProvider: AppleSpeechProvider
    let previewProvider: AppleSpeechProvider

    init() {
        self.primaryProvider = MLXWhisperProvider()
        self.fallbackProvider = AppleSpeechProvider()
        self.previewProvider = AppleSpeechProvider()
    }
}
