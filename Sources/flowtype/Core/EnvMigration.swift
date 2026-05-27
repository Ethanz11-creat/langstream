import Foundation

enum EnvMigration {
    private static func apply(_ value: String?, to target: inout String, didMigrate: inout Bool) {
        guard let value, !value.isEmpty else { return }
        target = value
        didMigrate = true
    }

    static func migrateIfNeeded() {
        let hasMigratedKey = "flowtype.didMigrateEnv"
        guard !UserDefaults.standard.bool(forKey: hasMigratedKey) else { return }

        var config = ConfigurationStore.shared.current
        var didMigrate = false

        // Try to load from .env file
        let dotEnv = DotEnv.load(path: ".env")
        let processEnv = ProcessInfo.processInfo.environment
        let env = dotEnv.merging(processEnv) { _, new in new }

        // Env migration: update the active (first) provider, or create one if none exist
        var activeProvider = config.llmProviders.first ?? LLMProvider(
            id: UUID(),
            name: "默认配置",
            provider: "SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1",
            model: "deepseek-ai/DeepSeek-V3",
            isActive: true
        )
        if let apiKey = env["SILICONFLOW_API_KEY"], !apiKey.isEmpty {
            ConfigurationStore.shared.saveProviderAPIKey(apiKey, for: activeProvider.id)
            didMigrate = true
        }
        if let baseURL = env["SILICONFLOW_BASE_URL"], !baseURL.isEmpty {
            activeProvider.baseURL = baseURL
            didMigrate = true
        }
        if let model = env["LLM_MODEL"], !model.isEmpty {
            activeProvider.model = model
            didMigrate = true
        }
        // Ensure the provider is in the list
        if config.llmProviders.isEmpty {
            config.llmProviders = [activeProvider]
        } else {
            config.llmProviders[0] = activeProvider
        }

        // Migrate from old flat config format if present
        if let oldData = UserDefaults.standard.data(forKey: "flowtype.config"),
           let oldConfig = migrateOldConfiguration(from: oldData, into: config) {
            config = oldConfig
            didMigrate = true
        }

        if didMigrate {
            ConfigurationStore.shared.save(config)
            print("[EnvMigration] Migrated config to new format")
        }

        UserDefaults.standard.set(true, forKey: hasMigratedKey)
    }

    /// Attempt to decode old flat configuration and map to new nested structure
    private static func migrateOldConfiguration(from data: Data, into config: Configuration) -> Configuration? {
        struct OldConfiguration: Codable {
            var apiKey: String?
            var baseURL: String?
            var llmModel: String?
            var triggerKey: TriggerKey?
        }

        guard let old = try? JSONDecoder().decode(OldConfiguration.self, from: data) else {
            return nil
        }

        var newConfig = config
        var activeProvider = newConfig.llmProviders.first ?? LLMProvider(
            id: UUID(),
            name: "默认配置",
            provider: "SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1",
            model: "deepseek-ai/DeepSeek-V3",
            isActive: true
        )

        if let apiKey = old.apiKey, !apiKey.isEmpty {
            ConfigurationStore.shared.saveProviderAPIKey(apiKey, for: activeProvider.id)
        }
        if let baseURL = old.baseURL, !baseURL.isEmpty {
            activeProvider.baseURL = baseURL
        }
        if let llmModel = old.llmModel, !llmModel.isEmpty {
            activeProvider.model = llmModel
        }
        if let triggerKey = old.triggerKey {
            newConfig.triggerKey = triggerKey
        }

        if newConfig.llmProviders.isEmpty {
            newConfig.llmProviders = [activeProvider]
        } else {
            newConfig.llmProviders[0] = activeProvider
        }

        return newConfig
    }
}
