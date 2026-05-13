import Foundation
import Combine

class ConfigurationStore: ObservableObject, @unchecked Sendable {
    static let shared = ConfigurationStore()

    @Published var current: Configuration

    private let defaultsKey = "flowtype.config"
    private let migrationVersionKey = "flowtype.migrationVersion"
    private let currentMigrationVersion = 2
    private let keychainLLMApiKeyKey = "llmApiKey"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           var config = try? JSONDecoder().decode(Configuration.self, from: data) {
            let storedVersion = UserDefaults.standard.integer(forKey: migrationVersionKey)
            var needsSave = false

            if storedVersion < 1 {
                if config.whisperLanguage == .auto {
                    config.whisperLanguage = .zh
                }
                needsSave = true
            }

            // Migration 2: move API key from UserDefaults JSON to Keychain
            if storedVersion < 2 {
                if !config.llmApiKey.isEmpty {
                    _ = KeychainHelper.save(key: keychainLLMApiKeyKey, value: config.llmApiKey)
                    AppLogger.log("[ConfigurationStore] Migrated API key to Keychain")
                }
                needsSave = true
            }

            UserDefaults.standard.set(currentMigrationVersion, forKey: migrationVersionKey)

            // Always load API key from Keychain (overrides whatever is in JSON)
            if let keychainKey = KeychainHelper.load(key: keychainLLMApiKeyKey) {
                config.llmApiKey = keychainKey
            }

            if config.systemPrompt.isEmpty {
                config.systemPrompt = Configuration.default.systemPrompt
                needsSave = true
            }

            if needsSave {
                // Save config without API key in UserDefaults
                var configForDisk = config
                configForDisk.llmApiKey = ""
                if let encoded = try? JSONEncoder().encode(configForDisk) {
                    UserDefaults.standard.set(encoded, forKey: defaultsKey)
                }
            }
            self.current = config
        } else {
            self.current = Configuration.default
        }
    }

    private var saveWorkItem: DispatchWorkItem?

    func save(_ config: Configuration) {
        self.current = config

        // Save API key to Keychain
        if !config.llmApiKey.isEmpty {
            _ = KeychainHelper.save(key: keychainLLMApiKeyKey, value: config.llmApiKey)
        } else {
            KeychainHelper.delete(key: keychainLLMApiKeyKey)
        }

        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Strip API key before writing to UserDefaults
            var configForDisk = config
            configForDisk.llmApiKey = ""
            if let data = try? JSONEncoder().encode(configForDisk) {
                UserDefaults.standard.set(data, forKey: self.defaultsKey)
            }
        }
        self.saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}
