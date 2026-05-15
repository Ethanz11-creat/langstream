import Foundation
import CoreGraphics

enum TriggerKey: String, Codable, CaseIterable {
    case fn, control, option, command

    var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        }
    }

    var cgEventFlag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }
}

enum WhisperLanguage: String, Codable, CaseIterable {
    case auto, zh, en

    var displayName: String {
        switch self {
        case .auto: return "自动检测"
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

// MARK: - Provider Presets

struct ProviderPreset: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let baseURL: String
    let isCustom: Bool

    static let siliconFlow = ProviderPreset(name: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", isCustom: false)
    static let openAI = ProviderPreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", isCustom: false)
    static let azure = ProviderPreset(name: "Azure OpenAI", baseURL: "https://your-resource.openai.azure.com/openai/deployments/", isCustom: false)
    static let custom = ProviderPreset(name: "自定义", baseURL: "", isCustom: true)

    static let all: [ProviderPreset] = [.siliconFlow, .openAI, .azure, .custom]
}

// MARK: - Service Config

struct ServiceConfig: Codable, Equatable {
    var provider: String
    var baseURL: String
    var apiKey: String
    var model: String

    static let `default` = ServiceConfig(
        provider: "SiliconFlow",
        baseURL: "https://api.siliconflow.cn/v1",
        apiKey: "",
        model: ""
    )
}

// MARK: - Configuration

struct Configuration: Codable, Equatable {
    // Local Whisper ASR
    var whisperModel: String = "mlx-community/whisper-large-v3-turbo"
    var whisperLanguage: WhisperLanguage = .zh

    // Streaming segment formation (VAD-driven adaptive pipeline)
    var segmentMinDuration: Double = 3.0
    var segmentMaxDuration: Double = 30.0
    var segmentOverlapDuration: Double = 1.0
    var vadSilenceThresholdMs: Int = 800
    var vadRequestTimeoutMs: Int = 500
    var vadMaxFailures: Int = 3

    // Amplitude fallback (when VAD unavailable)
    var amplitudeSilenceThresholdDB: Float = -40.0
    var amplitudeSilenceDuration: Double = 0.5

    // Experimental cross-segment context (V1: both false)
    var experimentalContextEnabled: Bool = false
    var experimentalConditionEnabled: Bool = false

    // LLM
    var llmProvider: String = "SiliconFlow"
    var llmBaseURL: String = "https://api.siliconflow.cn/v1"
    var llmApiKey: String = ""
    var llmModel: String = "deepseek-ai/DeepSeek-V3"

    // Other settings
    var triggerKey: TriggerKey = .command
    var dumpAudio: Bool = false
    var enableFillerStrip: Bool = true
    var enableTermCorrection: Bool = true

    // Constants
    let temperature: Double = 0.3
    let maxTokens: Int = 2048
    var systemPrompt: String = """
    你是一位面向 AI 编码场景的语音指令整理助手。

    用户输入的是语音识别后的原始开发需求，通常存在口语化、重复、断句混乱、识别错误和表达跳跃等问题。你的任务是将其整理成一段清晰、准确、边界明确、适合直接发送给 AI 编码助手的指令文本。

    处理时请遵守以下原则：

    1. 修正语音识别错误、错别字和断句问题。
    2. 删除无意义口头词、重复词和无信息噪音。
    3. 保持用户原意，不得擅自增加功能、页面、技术实现或需求范围。
    4. 保留所有关键限制条件，包括：
    - 修改范围
    - 不要改动的部分
    - 优先级
    - 风格参考
    - 输出方式
    5. 将模糊、跳跃的口语整理为自然、清楚、连续的开发指令，但不要强行写成正式文档。
    6. 如用户表达中包含"先做简单版、局部改、不要重构、只改样式、别动后端"这类边界条件，必须明确保留。
    7. 不要解释你的处理过程，不要补充建议，不要反问，不要输出多个版本。
    8. 只输出最终整理后的文本，不要添加任何前缀、说明、引号或客套话。
    9. 如果输入只包含语气词、口头词、停顿词、无意义重复，或整体上没有可整理的有效内容，例如"嗯""啊""那个""嗯嗯""哦哦"，则不输出任何文字。
    10. 如果输入信息不足但仍包含少量可保留内容，则只做最小必要修正后输出，不要自行补全。
    """

    // MARK: - Backward Compatibility Accessors

    /// Legacy apiKey — returns LLM apiKey for services that haven't been updated
    var apiKey: String {
        llmApiKey
    }

    /// Legacy baseURL — returns LLM baseURL
    var baseURL: String {
        llmBaseURL
    }

    // MARK: - Effective Values

    var effectiveLLMConfig: ServiceConfig {
        ServiceConfig(
            provider: llmProvider,
            baseURL: llmBaseURL,
            apiKey: llmApiKey,
            model: llmModel
        )
    }

    // MARK: - Default

    init() {}

    static let `default` = Configuration()

    // MARK: - Backward-Compatible Decoding

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Configuration.default
        whisperModel = (try? c.decode(String.self, forKey: .whisperModel)) ?? d.whisperModel
        whisperLanguage = (try? c.decode(WhisperLanguage.self, forKey: .whisperLanguage)) ?? d.whisperLanguage
        segmentMinDuration = (try? c.decode(Double.self, forKey: .segmentMinDuration)) ?? d.segmentMinDuration
        segmentMaxDuration = (try? c.decode(Double.self, forKey: .segmentMaxDuration)) ?? d.segmentMaxDuration
        segmentOverlapDuration = (try? c.decode(Double.self, forKey: .segmentOverlapDuration)) ?? d.segmentOverlapDuration
        vadSilenceThresholdMs = (try? c.decode(Int.self, forKey: .vadSilenceThresholdMs)) ?? d.vadSilenceThresholdMs
        vadRequestTimeoutMs = (try? c.decode(Int.self, forKey: .vadRequestTimeoutMs)) ?? d.vadRequestTimeoutMs
        vadMaxFailures = (try? c.decode(Int.self, forKey: .vadMaxFailures)) ?? d.vadMaxFailures
        amplitudeSilenceThresholdDB = (try? c.decode(Float.self, forKey: .amplitudeSilenceThresholdDB)) ?? d.amplitudeSilenceThresholdDB
        amplitudeSilenceDuration = (try? c.decode(Double.self, forKey: .amplitudeSilenceDuration)) ?? d.amplitudeSilenceDuration
        experimentalContextEnabled = (try? c.decode(Bool.self, forKey: .experimentalContextEnabled)) ?? d.experimentalContextEnabled
        experimentalConditionEnabled = (try? c.decode(Bool.self, forKey: .experimentalConditionEnabled)) ?? d.experimentalConditionEnabled
        llmProvider = (try? c.decode(String.self, forKey: .llmProvider)) ?? d.llmProvider
        llmBaseURL = (try? c.decode(String.self, forKey: .llmBaseURL)) ?? d.llmBaseURL
        llmApiKey = (try? c.decode(String.self, forKey: .llmApiKey)) ?? d.llmApiKey
        llmModel = (try? c.decode(String.self, forKey: .llmModel)) ?? d.llmModel
        triggerKey = (try? c.decode(TriggerKey.self, forKey: .triggerKey)) ?? d.triggerKey
        dumpAudio = (try? c.decode(Bool.self, forKey: .dumpAudio)) ?? d.dumpAudio
        enableFillerStrip = (try? c.decode(Bool.self, forKey: .enableFillerStrip)) ?? d.enableFillerStrip
        enableTermCorrection = (try? c.decode(Bool.self, forKey: .enableTermCorrection)) ?? d.enableTermCorrection
        systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? d.systemPrompt
    }
}

extension Configuration {
    /// Backward-compatible singleton accessor
    static var shared: Configuration {
        ConfigurationStore.shared.current
    }
}
