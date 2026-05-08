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
        if let r = recognizer {
            WindowManager.fileLog("[AppleSpeechProvider] init: recognizer available, supportsOnDevice=\(r.supportsOnDeviceRecognition), isAvailable=\(r.isAvailable)")
            if !r.supportsOnDeviceRecognition {
                print("[AppleSpeechProvider] WARNING: On-device recognition not supported on this device. AppleSpeech will not be available.")
            }
        } else {
            WindowManager.fileLog("[AppleSpeechProvider] init: recognizer is nil")
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
            WindowManager.fileLog("[AppleSpeechProvider] transcribe: not available")
            throw SpeechProviderError.notAvailable
        }

        WindowManager.fileLog("[AppleSpeechProvider] transcribe: starting with \(audioData.count) bytes")

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
                    WindowManager.fileLog("[AppleSpeechProvider] transcribe error: \(error.localizedDescription)")
                    continuation.resume(throwing: SpeechProviderError.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result = result else {
                    WindowManager.fileLog("[AppleSpeechProvider] transcribe: no result")
                    continuation.resume(throwing: SpeechProviderError.transcriptionFailed("No result"))
                    return
                }
                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                    WindowManager.fileLog("[AppleSpeechProvider] transcribe final: '\(text.prefix(80))'")
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

    func startStreamingRecognition() async -> AsyncStream<String> {
        finalResult = ""

        // Check authorization and request if needed
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        WindowManager.fileLog("[AppleSpeechProvider] startStreaming: authStatus=\(authStatus.rawValue) (0=notDetermined,1=denied,2=restricted,3=authorized)")
        if authStatus == .notDetermined {
            WindowManager.fileLog("[AppleSpeechProvider] Requesting speech recognition authorization...")
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    WindowManager.fileLog("[AppleSpeechProvider] Authorization callback: status=\(status.rawValue)")
                    continuation.resume()
                }
            }
            // Re-check after the request completes
            let newStatus = SFSpeechRecognizer.authorizationStatus()
            guard newStatus == .authorized else {
                WindowManager.fileLog("[AppleSpeechProvider] Speech recognition NOT authorized after request (status: \(newStatus.rawValue))")
                return AsyncStream { $0.finish() }
            }
            WindowManager.fileLog("[AppleSpeechProvider] Authorization granted, continuing...")
        } else if authStatus != .authorized {
            WindowManager.fileLog("[AppleSpeechProvider] Speech recognition NOT authorized (status: \(authStatus.rawValue)), skipping preview")
            return AsyncStream { $0.finish() }
        }

        guard let recognizer = recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            let reason = recognizer == nil ? "recognizer=nil" : (recognizer!.isAvailable ? "supportsOnDevice=false" : "isAvailable=false")
            WindowManager.fileLog("[AppleSpeechProvider] On-device speech recognizer not available: \(reason)")
            return AsyncStream { $0.finish() }
        }

        WindowManager.fileLog("[AppleSpeechProvider] Starting real-time streaming recognition...")
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

                if let error = error {
                    WindowManager.fileLog("[AppleSpeechProvider] Recognition error: \(error.localizedDescription)")
                    self.previewContinuation?.finish()
                    return
                }

                guard let result = result else {
                    WindowManager.fileLog("[AppleSpeechProvider] Recognition result is nil")
                    return
                }

                let transcript = result.bestTranscription.formattedString
                self.finalResult = transcript
                WindowManager.fileLog("[AppleSpeechProvider] Partial result: '\(transcript.prefix(60))' isFinal=\(result.isFinal)")
                self.previewContinuation?.yield(transcript)

                if result.isFinal {
                    WindowManager.fileLog("[AppleSpeechProvider] Final result received")
                    self.previewContinuation?.finish()
                }
            }

            continuation.onTermination = { [weak self] _ in
                WindowManager.fileLog("[AppleSpeechProvider] Stream terminated")
                _ = self?.stopStreamingRecognition()
            }
        }
    }

    // Called by AudioRecorder's tap callback with raw audio buffers
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let request = recognitionRequest else { return }
        request.append(buffer)
    }

    func stopStreamingRecognition() -> String {
        WindowManager.fileLog("[AppleSpeechProvider] stopStreamingRecognition called, finalResult='\(finalResult.prefix(80))'")
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        return finalResult
    }
}
