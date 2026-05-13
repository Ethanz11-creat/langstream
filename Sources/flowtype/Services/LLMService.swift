import Foundation

enum LLMError: Error {
    case invalidResponse
    case apiError(String)
    case streamDecodingError
    case networkError(Error)
    case timeout
}

actor LLMService {
    private var config: Configuration {
        ConfigurationStore.shared.current
    }

    private var apiKey: String { config.llmApiKey }
    private var baseURL: String { config.llmBaseURL }
    private var model: String { config.llmModel }
    private var temperature: Double { config.temperature }

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

    func polishText(_ text: String) -> AsyncThrowingStream<String, Error> {
        let systemPrompt = self.config.systemPrompt
        let maxTokens = self.config.maxTokens
        return makeStream(text: text, systemPrompt: systemPrompt, maxTokens: maxTokens, timeoutSeconds: 30)
    }

    // MARK: - Shared streaming infrastructure

    private func makeStream(
        text: String,
        systemPrompt: String,
        maxTokens: Int,
        timeoutSeconds: UInt64
    ) -> AsyncThrowingStream<String, Error> {
        let apiKey = self.apiKey
        let baseURL = self.baseURL
        let model = self.model
        let temperature = self.temperature

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
                do {
                    try await Self.streamRequest(
                        apiKey: apiKey,
                        baseURL: baseURL,
                        model: model,
                        temperature: temperature,
                        systemPrompt: systemPrompt,
                        userMessage: validatedText,
                        maxTokens: maxTokens,
                        timeoutSeconds: timeoutSeconds,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
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
