import Foundation
@preconcurrency import Speech
import AVFoundation

final class AppleSpeechProvider: SpeechProvider, @unchecked Sendable {
    var name: String { "AppleSpeech" }

    private var recognizer: SFSpeechRecognizer?
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private nonisolated(unsafe) var recognitionTask: SFSpeechRecognitionTask?

    private nonisolated(unsafe) var previewContinuation: AsyncStream<String>.Continuation?
    private nonisolated(unsafe) var finalResult: String = ""

    init() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        // Only use on-device recognition; if not supported, the recognizer is nil-effectively
        if let r = recognizer, !r.supportsOnDeviceRecognition {
            print("[AppleSpeechProvider] WARNING: On-device recognition not supported on this device. AppleSpeech will not be available.")
        }
        self.recognizer = recognizer
    }

    /// Check if on-device speech recognition is available on this Mac.
    static func isAvailable() -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            return false
        }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    // MARK: - SpeechProvider Protocol

    /// One-shot offline recognition from WAV data.
    /// Writes data to a temp file and uses SFSpeechURLRecognitionRequest with on-device recognition.
    func transcribe(audioData: Data, timeout: TimeInterval = 20) async throws -> String {
        guard let recognizer = recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw SpeechProviderError.notAvailable
        }

        // Write WAV data to a temporary file
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("flowtype_apple_speech_\(UUID().uuidString).wav")
        try audioData.write(to: tmpFile)
        defer {
            try? FileManager.default.removeItem(at: tmpFile)
        }

        let request = SFSpeechURLRecognitionRequest(url: tmpFile)
        request.requiresOnDeviceRecognition = true

        return try await withCheckedThrowingContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: SpeechProviderError.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result = result else {
                    continuation.resume(throwing: SpeechProviderError.transcriptionFailed("No result"))
                    return
                }
                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                    continuation.resume(returning: text)
                }
            }

            // Timeout guard
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                task.cancel()
            }
        }
    }

    // MARK: - Real-time Streaming Recognition (for preview during recording)

    func startStreamingRecognition() -> AsyncStream<String> {
        finalResult = ""

        // Check authorization and request if needed
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            print("[AppleSpeechProvider] Requesting speech recognition authorization...")
            SFSpeechRecognizer.requestAuthorization { _ in }
            // Return empty stream this time; next toggle will have auth status
            return AsyncStream { $0.finish() }
        }
        guard authStatus == .authorized else {
            print("[AppleSpeechProvider] Speech recognition not authorized (status: \(authStatus.rawValue)), skipping preview")
            return AsyncStream { $0.finish() }
        }

        guard let recognizer = recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            print("[AppleSpeechProvider] On-device speech recognizer not available")
            return AsyncStream { $0.finish() }
        }

        return AsyncStream { continuation in
            self.previewContinuation = continuation

            // Create recognition request
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.recognitionRequest = request

            // Create recognition task
            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }

                if error != nil {
                    self.previewContinuation?.finish()
                    return
                }

                guard let result = result else { return }

                let transcript = result.bestTranscription.formattedString
                self.finalResult = transcript
                self.previewContinuation?.yield(transcript)

                if result.isFinal {
                    self.previewContinuation?.finish()
                }
            }

            continuation.onTermination = { [weak self] _ in
                _ = self?.stopStreamingRecognition()
            }
        }
    }

    // Called by AudioRecorder's tap callback with raw audio buffers
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopStreamingRecognition() -> String {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        return finalResult
    }
}
