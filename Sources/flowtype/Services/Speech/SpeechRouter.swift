import Foundation
import AVFoundation

final class SpeechRouter: @unchecked Sendable {
    let primaryProvider: TeleSpeechProvider
    let fallbackProvider: SenseVoiceProvider
    let localProvider: AppleSpeechProvider

    init() {
        let config = Configuration.shared
        self.primaryProvider = TeleSpeechProvider(config: config.effectiveAsrPrimaryConfig)
        self.fallbackProvider = SenseVoiceProvider(config: config.effectiveAsrFallbackConfig)
        self.localProvider = AppleSpeechProvider()
    }
}
