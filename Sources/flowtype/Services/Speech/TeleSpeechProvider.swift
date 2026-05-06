import Foundation

final class TeleSpeechProvider: SiliconFlowSpeechProvider {
    init(config: ServiceConfig = Configuration.shared.effectiveAsrPrimaryConfig) {
        super.init(
            name: "TeleSpeech",
            model: config.model,
            prompt: "请识别标准中文普通话，去除重复字词和语气词，保持语句通顺自然。",
            config: config
        )
    }
}
