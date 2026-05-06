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

enum ASRStrategy: String, Codable, CaseIterable {
    case parallel
    case fallback

    var displayName: String {
        switch self {
        case .parallel: return "并行双发，择优选取"
        case .fallback: return "主模型优先，失败回退"
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
    // ASR Primary
    var asrPrimaryProvider: String
    var asrPrimaryBaseURL: String
    var asrPrimaryApiKey: String
    var asrPrimaryModel: String

    // ASR Fallback
    var asrFallbackProvider: String
    var asrFallbackBaseURL: String
    var asrFallbackApiKey: String
    var asrFallbackModel: String

    // LLM
    var llmProvider: String
    var llmBaseURL: String
    var llmApiKey: String
    var llmModel: String

    // Other settings
    var triggerKey: TriggerKey
    var asrStrategy: ASRStrategy
    var dumpAudio: Bool
    var enableFillerStrip: Bool
    var enableTermCorrection: Bool

    // Constants
    let temperature: Double
    let maxTokens: Int
    let systemPrompt: String

    // MARK: - Backward Compatibility Accessors

    /// Legacy apiKey — returns LLM apiKey for services that haven't been updated
    var apiKey: String {
        llmApiKey
    }

    /// Legacy baseURL — returns LLM baseURL
    var baseURL: String {
        llmBaseURL
    }

    // MARK: - Effective Values (fall back to primary config if fallback is empty)

    var effectiveAsrPrimaryConfig: ServiceConfig {
        ServiceConfig(
            provider: asrPrimaryProvider,
            baseURL: asrPrimaryBaseURL,
            apiKey: asrPrimaryApiKey.isEmpty ? llmApiKey : asrPrimaryApiKey,
            model: asrPrimaryModel
        )
    }

    var effectiveAsrFallbackConfig: ServiceConfig {
        let resolvedApiKey: String
        if !asrFallbackApiKey.isEmpty {
            resolvedApiKey = asrFallbackApiKey
        } else if !asrPrimaryApiKey.isEmpty {
            resolvedApiKey = asrPrimaryApiKey
        } else {
            resolvedApiKey = llmApiKey
        }
        return ServiceConfig(
            provider: asrFallbackProvider,
            baseURL: asrFallbackBaseURL.isEmpty ? asrPrimaryBaseURL : asrFallbackBaseURL,
            apiKey: resolvedApiKey,
            model: asrFallbackModel
        )
    }

    var effectiveLLMConfig: ServiceConfig {
        ServiceConfig(
            provider: llmProvider,
            baseURL: llmBaseURL,
            apiKey: llmApiKey,
            model: llmModel
        )
    }

    // MARK: - Default

    static let `default` = Configuration(
        asrPrimaryProvider: "SiliconFlow",
        asrPrimaryBaseURL: "https://api.siliconflow.cn/v1",
        asrPrimaryApiKey: "",
        asrPrimaryModel: "TeleAI/TeleSpeechASR",
        asrFallbackProvider: "SiliconFlow",
        asrFallbackBaseURL: "",
        asrFallbackApiKey: "",
        asrFallbackModel: "FunAudioLLM/SenseVoiceSmall",
        llmProvider: "SiliconFlow",
        llmBaseURL: "https://api.siliconflow.cn/v1",
        llmApiKey: "",
        llmModel: "deepseek-ai/DeepSeek-V3",
        triggerKey: .command,
        asrStrategy: .parallel,
        dumpAudio: false,
        enableFillerStrip: true,
        enableTermCorrection: true,
        temperature: 0.3,
        maxTokens: 2048,
        systemPrompt: """
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
    )
}

extension Configuration {
    /// Backward-compatible singleton accessor
    static var shared: Configuration {
        ConfigurationStore.shared.current
    }
}
