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
    var whisperLanguage: WhisperLanguage = .auto

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
    let systemPrompt: String = ""

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

    static let `default` = Configuration(
        whisperModel: "mlx-community/whisper-large-v3-turbo",
        whisperLanguage: .auto,
        llmProvider: "SiliconFlow",
        llmBaseURL: "https://api.siliconflow.cn/v1",
        llmApiKey: "",
        llmModel: "deepseek-ai/DeepSeek-V3",
        triggerKey: .command,
        dumpAudio: false,
        enableFillerStrip: true,
        enableTermCorrection: true
    )
}

extension Configuration {
    /// Backward-compatible singleton accessor
    static var shared: Configuration {
        ConfigurationStore.shared.current
    }
}
