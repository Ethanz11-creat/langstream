import Foundation

enum LLMError: Error {
    case invalidResponse
    case apiError(String)
    case streamDecodingError
    case networkError(Error)
    case timeout
}

actor LLMService {

    init() {}

    static func shouldPolish(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }

        let fillerPattern = "^[嗯啊哦呃哼哈呀哪那个这个那么就是对吧然后然后]+$"
        if let regex = try? NSRegularExpression(pattern: fillerPattern),
           regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
            return nil
        }

        return trimmed
    }

    // MARK: - Public API

    func polishText(_ text: String, systemPrompt: String? = nil) -> AsyncThrowingStream<String, Error> {
        let config = ConfigurationStore.shared.current
        let prompt = systemPrompt ?? config.systemPrompt
        let maxTokens = config.maxTokens
        return makeStream(text: text, systemPrompt: prompt, maxTokens: maxTokens, timeoutSeconds: 30, config: config)
    }

    @MainActor
    static func composeSystemPrompt(fallback: String) -> String {
        let activePack = StylePackStore.shared.activePack
        var prompt = activePack?.prompt ?? fallback

        let phrases = DictionaryStore.shared.enabledPhrases
        if !phrases.isEmpty {
            let hotwordBlock = "\n\n以下是用户的专有名词词典，请在输出中优先使用这些正确写法：\n" + phrases.joined(separator: "、")
            if prompt.contains("{{HOTWORDS}}") {
                prompt = prompt.replacingOccurrences(of: "{{HOTWORDS}}", with: hotwordBlock)
            } else {
                prompt += hotwordBlock
            }
        } else {
            prompt = prompt.replacingOccurrences(of: "{{HOTWORDS}}", with: "")
        }

        return prompt
    }

    // MARK: - Provider Resolution

    private func resolveProviderChain(providers: [LLMProvider]) -> [(provider: LLMProvider, apiKey: String)] {
        var result: [(provider: LLMProvider, apiKey: String)] = []

        // Active provider first
        if let active = providers.first(where: \.isActive) {
            if let apiKey = ConfigurationStore.shared.loadProviderAPIKey(active.id),
               !apiKey.isEmpty {
                result.append((active, apiKey))
            }
        }

        // Then other providers with valid API keys
        for provider in providers {
            if provider.isActive { continue } // Skip active, already added
            if let apiKey = ConfigurationStore.shared.loadProviderAPIKey(provider.id),
               !apiKey.isEmpty {
                result.append((provider, apiKey))
            }
        }

        return result
    }

    // MARK: - Connection Test

    func testConnection(provider: LLMProvider) async -> Result<String, LLMError> {
        guard let apiKey = ConfigurationStore.shared.loadProviderAPIKey(provider.id),
              !apiKey.isEmpty else {
            return .failure(LLMError.apiError("请在设置中配置 LLM API Key"))
        }

        guard let url = URL(string: "\(provider.baseURL)/chat/completions") else {
            return .failure(LLMError.invalidResponse)
        }

        let body: [String: Any] = [
            "model": provider.model,
            "messages": [
                ["role": "user", "content": "hello"]
            ],
            "stream": false,
            "temperature": 0.3,
            "max_tokens": 5
        ]

        do {
            let requestBody = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = requestBody

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(LLMError.apiError("Non-HTTP response"))
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let statusCode = httpResponse.statusCode
                let errorBody = String(data: data, encoding: .utf8) ?? "(unable to decode error body)"
                AppLogger.log("[LLMService] testConnection HTTP \(statusCode): \(errorBody.prefix(500))")
                return .failure(LLMError.apiError("HTTP \(statusCode): \(errorBody.prefix(200))"))
            }

            return .success("连接成功")
        } catch {
            AppLogger.log("[LLMService] testConnection error: \(error)")
            return .failure(LLMError.networkError(error))
        }
    }

    // MARK: - Shared streaming infrastructure

    private func makeStream(
        text: String,
        systemPrompt: String,
        maxTokens: Int,
        timeoutSeconds: UInt64,
        config: Configuration
    ) -> AsyncThrowingStream<String, Error> {
        let temperature = config.temperature

        return AsyncThrowingStream { continuation in
            Task {
                guard let validatedText = Self.shouldPolish(text) else {
                    continuation.finish()
                    return
                }
                if systemPrompt.isEmpty {
                    AppLogger.log("[LLMService] WARNING: systemPrompt is empty, skipping")
                    continuation.finish()
                    return
                }

                let chain = self.resolveProviderChain(providers: config.llmProviders)
                guard !chain.isEmpty else {
                    continuation.finish(throwing: LLMError.apiError("请在设置中配置 LLM API Key"))
                    return
                }

                var lastError: Error?
                let maxAttempts = min(chain.count, 2)
                for i in 0..<maxAttempts {
                    let resolved = chain[i]
                    do {
                        AppLogger.log("[LLMService] Trying provider \(resolved.provider.name) (attempt \(i+1)/\(maxAttempts))")
                        try await Self.streamRequest(
                            apiKey: resolved.apiKey,
                            baseURL: resolved.provider.baseURL,
                            model: resolved.provider.model,
                            temperature: temperature,
                            systemPrompt: systemPrompt,
                            userMessage: validatedText,
                            maxTokens: maxTokens,
                            timeoutSeconds: timeoutSeconds,
                            continuation: continuation
                        )
                        return // Success — streamRequest finished normally
                    } catch {
                        lastError = error
                        AppLogger.log("[LLMService] Provider \(resolved.provider.name) failed: \(error)")
                        if i < maxAttempts - 1 {
                            AppLogger.log("[LLMService] Falling back to next provider...")
                        }
                    }
                }

                // All attempts exhausted
                if let lastError = lastError {
                    continuation.finish(throwing: lastError)
                } else {
                    continuation.finish(throwing: LLMError.apiError("所有 Provider 均不可用"))
                }
            }
        }
    }

    private static func streamRequest(
        apiKey: String,
        baseURL: String,
        model: String,
        temperature: Double,
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int,
        timeoutSeconds: UInt64,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.invalidResponse
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]

        let requestBody = try JSONSerialization.data(withJSONObject: body)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = TimeInterval(timeoutSeconds)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = requestBody

                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LLMError.apiError("Non-HTTP response")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = httpResponse.statusCode
                    var errorBody = ""
                    do {
                        for try await line in bytes.lines.prefix(20) {
                            errorBody += line + "\n"
                        }
                    } catch {
                        errorBody = "(unable to read error body)"
                    }
                    AppLogger.log("[LLMService] HTTP \(statusCode): \(errorBody.prefix(500))")
                    throw LLMError.apiError("HTTP \(statusCode): \(errorBody.prefix(200))")
                }

                for try await line in bytes.lines {
                    if line.hasPrefix("data: ") {
                        let data = String(line.dropFirst(6))
                        if data == "[DONE]" {
                            continuation.finish()
                            return
                        }

                        if let chunkData = data.data(using: .utf8) {
                            if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: chunkData),
                               let content = chunk.choices.first?.delta.content {
                                continuation.yield(content)
                            }
                        }
                    }
                }

                continuation.finish()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw LLMError.timeout
            }

            try await group.next()!
            group.cancelAll()
        }
    }
}

private struct StreamChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
            let content: String?
        }
        let delta: Delta
    }
    let choices: [Choice]
}
