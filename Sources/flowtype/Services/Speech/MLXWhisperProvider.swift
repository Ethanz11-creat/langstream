import Foundation

final class MLXWhisperProvider: SpeechProvider {
    let name: String = "MLXWhisper"

    func transcribe(audioData: Data, timeout: TimeInterval = 300) async throws -> String {
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
            print("[MLXWhisper] HTTP error \(httpResponse.statusCode): \(errorText)")
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
