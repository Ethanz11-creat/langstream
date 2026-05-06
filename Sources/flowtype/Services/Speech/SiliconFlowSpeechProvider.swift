import Foundation

class SiliconFlowSpeechProvider: SpeechProvider {
    let name: String
    let model: String
    private let apiKey: String
    private let baseURL: String
    private let prompt: String?

    init(name: String, model: String, prompt: String? = nil, config: ServiceConfig) {
        self.name = name
        self.model = model
        self.prompt = prompt
        self.apiKey = config.apiKey
        self.baseURL = config.baseURL
    }

    func transcribe(audioData: Data, timeout: TimeInterval = 20) async throws -> String {
        guard !apiKey.isEmpty else {
            throw SpeechProviderError.transcriptionFailed("API key not configured")
        }

        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw SpeechProviderError.transcriptionFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(string: "--\(boundary)\r\n")
        body.append(string: "Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append(string: "\(model)\r\n")

        body.append(string: "--\(boundary)\r\n")
        body.append(string: "Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        body.append(string: "zh\r\n")

        if let prompt = prompt {
            body.append(string: "--\(boundary)\r\n")
            body.append(string: "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            body.append(string: "\(prompt)\r\n")
        }

        body.append(string: "--\(boundary)\r\n")
        body.append(string: "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.append(string: "Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append(string: "\r\n")
        body.append(string: "--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechProviderError.networkError(SpeechProviderError.transcriptionFailed("Invalid response"))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[\(name)] HTTP error \(httpResponse.statusCode): \(errorText)")
            throw SpeechProviderError.transcriptionFailed("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        struct TranscriptionResponse: Codable {
            let text: String
        }

        do {
            let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            return result.text
        } catch {
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
