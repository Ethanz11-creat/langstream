import Foundation

enum LLMError: Error {
    case invalidResponse
    case apiError(String)
    case streamDecodingError
    case networkError(Error)
    case timeout
}

actor LLMService {
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let temperature: Double
    private let maxTokens: Int
    private let systemPrompt: String

    init(configuration: Configuration) {
        self.apiKey = configuration.apiKey
        self.baseURL = configuration.baseURL
        self.model = configuration.llmModel
        self.temperature = configuration.temperature
        self.maxTokens = configuration.maxTokens
        self.systemPrompt = configuration.systemPrompt
    }

    /// Check if text is worth polishing. Returns nil if should skip.
    static func shouldPolish(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip empty or very short text
        guard trimmed.count >= 4 else { return nil }

        // Skip pure filler text
        let fillerPattern = "^[嗯啊哦呃哼哈呀哪那个这个那么就是对吧然后然后]+$"
        if let regex = try? NSRegularExpression(pattern: fillerPattern),
           regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
            return nil
        }

        return trimmed
    }

    func polishText(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Skip if text is not worth polishing
                guard let validatedText = Self.shouldPolish(text) else {
                    continuation.finish()
                    return
                }

                do {
                    try await self.streamPolish(text: validatedText, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamPolish(text: String, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.invalidResponse
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]

        let requestBody = try JSONSerialization.data(withJSONObject: body)

        // Use withThrowingTaskGroup for timeout control
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Main SSE reading task
            group.addTask {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 10  // 10s total timeout
                request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = requestBody

                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw LLMError.apiError("Invalid response")
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
                            } else if let raw = String(data: chunkData, encoding: .utf8) {
                                // Log unparseable chunks so we can diagnose API changes
                                print("[LLMService] Unparseable SSE chunk: \(raw)")
                            }
                        }
                    }
                }

                continuation.finish()
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                throw LLMError.timeout
            }

            // Wait for first to complete
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
