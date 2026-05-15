import Foundation

final class MLXWhisperProvider: SpeechProvider {
    let name: String = "MLXWhisper"

    func transcribe(audioData: Data, timeout: TimeInterval = 300) async throws -> String {
        let detail = try await transcribeWithDetails(
            audioData: audioData,
            initialPrompt: nil,
            conditionOnPrevious: false,
            timeout: timeout
        )
        return detail.text
    }

    func transcribeWithDetails(
        audioData: Data,
        initialPrompt: String?,
        conditionOnPrevious: Bool,
        timeout: TimeInterval
    ) async throws -> TranscriptionDetail {
        let port = WhisperServerManager.shared.port ?? 8765
        guard let url = URL(string: "http://127.0.0.1:\(port)/transcribe") else {
            throw SpeechProviderError.transcriptionFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // File part
        body.append(string: "--\(boundary)\r\n")
        body.append(string: "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.append(string: "Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append(string: "\r\n")

        // initial_prompt part (optional)
        if let prompt = initialPrompt, !prompt.isEmpty {
            body.append(string: "--\(boundary)\r\n")
            body.append(string: "Content-Disposition: form-data; name=\"initial_prompt\"\r\n\r\n")
            body.append(string: prompt)
            body.append(string: "\r\n")
        }

        // condition_on_previous part (only if true)
        if conditionOnPrevious {
            body.append(string: "--\(boundary)\r\n")
            body.append(string: "Content-Disposition: form-data; name=\"condition_on_previous\"\r\n\r\n")
            body.append(string: "true")
            body.append(string: "\r\n")
        }

        body.append(string: "--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechProviderError.networkError(SpeechProviderError.transcriptionFailed("Invalid response"))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[MLXWhisper] HTTP error \(httpResponse.statusCode): \(errorText)")
            throw SpeechProviderError.transcriptionFailed("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        struct FullResponse: Codable {
            let text: String
            let segments: [WhisperSegment]?
            let language: String?
        }

        do {
            let result = try JSONDecoder().decode(FullResponse.self, from: data)
            return TranscriptionDetail(
                text: result.text,
                segments: result.segments,
                language: result.language
            )
        } catch {
            // Fallback: try parsing as legacy {"text": "..."} response
            struct LegacyResponse: Codable { let text: String }
            if let legacy = try? JSONDecoder().decode(LegacyResponse.self, from: data) {
                return TranscriptionDetail(text: legacy.text, segments: nil, language: nil)
            }
            throw SpeechProviderError.transcriptionFailed("Failed to parse response")
        }
    }
}

private extension Data {
    mutating func append(string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
