import Foundation

final class SenseVoiceProvider: SiliconFlowSpeechProvider {
    init(config: ServiceConfig = Configuration.shared.effectiveAsrFallbackConfig) {
        super.init(
            name: "SenseVoice",
            model: config.model,
            config: config
        )
    }
}
