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
    private var streamingTimeoutTimer = CancellableTimer()
    private let streamingTimeout: TimeInterval = 30.0

    init() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        // Only use on-device recognition; if not supported, the recognizer is nil-effectively
        if let r = recognizer {
            AppLogger.log("[AppleSpeechProvider] init: recognizer available, supportsOnDevice=\(r.supportsOnDeviceRecognition), isAvailable=\(r.isAvailable)")
            if !r.supportsOnDeviceRecognition {
                print("[AppleSpeechProvider] WARNING: On-device recognition not supported on this device. AppleSpeech will not be available.")
            }
        } else {
            AppLogger.log("[AppleSpeechProvider] init: recognizer is nil")
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
            AppLogger.log("[AppleSpeechProvider] transcribe: not available")
            throw SpeechProviderError.notAvailable
        }

        AppLogger.log("[AppleSpeechProvider] transcribe: starting with \(audioData.count) bytes")

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
                    AppLogger.log("[AppleSpeechProvider] transcribe error: \(error.localizedDescription)")
                    continuation.resume(throwing: SpeechProviderError.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result = result else {
                    AppLogger.log("[AppleSpeechProvider] transcribe: no result")
                    continuation.resume(throwing: SpeechProviderError.transcriptionFailed("No result"))
                    return
                }
                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                    AppLogger.log("[AppleSpeechProvider] transcribe final: '\(text.prefix(80))'")
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
        AppLogger.log("[AppleSpeechProvider] startStreaming: authStatus=\(authStatus.rawValue) (0=notDetermined,1=denied,2=restricted,3=authorized)")
        if authStatus == .notDetermined {
            AppLogger.log("[AppleSpeechProvider] Requesting speech recognition authorization...")
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    AppLogger.log("[AppleSpeechProvider] Authorization callback: status=\(status.rawValue)")
                    continuation.resume()
                }
            }
            // Re-check after the request completes
            let newStatus = SFSpeechRecognizer.authorizationStatus()
            guard newStatus == .authorized else {
                AppLogger.log("[AppleSpeechProvider] Speech recognition NOT authorized after request (status: \(newStatus.rawValue))")
                return AsyncStream { $0.finish() }
            }
            AppLogger.log("[AppleSpeechProvider] Authorization granted, continuing...")
        } else if authStatus != .authorized {
            AppLogger.log("[AppleSpeechProvider] Speech recognition NOT authorized (status: \(authStatus.rawValue)), skipping preview")
            return AsyncStream { $0.finish() }
        }

        guard let recognizer = recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            let reason = recognizer == nil ? "recognizer=nil" : (recognizer!.isAvailable ? "supportsOnDevice=false" : "isAvailable=false")
            AppLogger.log("[AppleSpeechProvider] On-device speech recognizer not available: \(reason)")
            return AsyncStream { $0.finish() }
        }

        AppLogger.log("[AppleSpeechProvider] Starting real-time streaming recognition...")
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
                    AppLogger.log("[AppleSpeechProvider] Recognition error: \(error.localizedDescription)")
                    self.streamingTimeoutTimer.cancel()
                    self.previewContinuation?.finish()
                    return
                }

                guard let result = result else {
                    AppLogger.log("[AppleSpeechProvider] Recognition result is nil")
                    return
                }

                let transcript = result.bestTranscription.formattedString
                self.finalResult = transcript
                AppLogger.log("[AppleSpeechProvider] Partial result: '\(transcript.prefix(60))' isFinal=\(result.isFinal)")
                self.previewContinuation?.yield(transcript)

                if result.isFinal {
                    AppLogger.log("[AppleSpeechProvider] Final result received")
                    self.streamingTimeoutTimer.cancel()
                    self.previewContinuation?.finish()
                }
            }

            // Timeout guard: if no final result within 30s, force-stop
            self.streamingTimeoutTimer.schedule(
                withTimeInterval: self.streamingTimeout,
                repeats: false
            ) { [weak self] in
                guard let self = self else { return }
                AppLogger.log("[AppleSpeechProvider] Streaming recognition timed out after \(self.streamingTimeout)s")
                self.previewContinuation?.finish()
                self.recognitionTask?.cancel()
                self.recognitionRequest?.endAudio()
            }

            continuation.onTermination = { [weak self] _ in
                AppLogger.log("[AppleSpeechProvider] Stream terminated")
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
        AppLogger.log("[AppleSpeechProvider] stopStreamingRecognition called, finalResult='\(finalResult.prefix(80))'")
        streamingTimeoutTimer.cancel()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        return finalResult
    }
}
