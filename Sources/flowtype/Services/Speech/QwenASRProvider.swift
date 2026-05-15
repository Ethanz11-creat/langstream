import Foundation
import Qwen3ASR
import SpeechVAD
import AudioCommon

final class QwenASRProvider: @unchecked Sendable {
    let name: String = "QwenASR"

    private nonisolated(unsafe) var model: Qwen3ASRModel?
    private nonisolated(unsafe) var _streamingASR: StreamingASR?
    private let queue = DispatchQueue(label: "flowtype.qwen-asr")

    var isLoaded: Bool {
        queue.sync { model != nil }
    }

    // MARK: - Model Lifecycle

    func loadModel(
        modelId: String = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        AppLogger.log("[QwenASR] Loading model: \(modelId)")
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            progressHandler: progressHandler
        )
        let streaming = try await StreamingASR.fromPretrained(
            asrModelId: modelId
        )
        queue.sync {
            model = loaded
            _streamingASR = streaming
        }
        AppLogger.log("[QwenASR] Model loaded successfully")
    }

    func unloadModel() {
        queue.sync {
            model = nil
            _streamingASR = nil
        }
        AppLogger.log("[QwenASR] Model unloaded")
    }

    // MARK: - Transcription

    func transcribe(
        samples: [Float],
        sampleRate: Int = 16000,
        language: String? = nil,
        context: String? = nil
    ) async throws -> String {
        let currentModel: Qwen3ASRModel? = queue.sync { model }
        guard let currentModel else {
            throw SpeechProviderError.notAvailable
        }

        let options = Qwen3DecodingOptions(
            language: language,
            context: context,
            repetitionPenalty: 1.1,
            noRepeatNgramSize: 3
        )

        let text: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = currentModel.transcribe(
                    audio: samples,
                    sampleRate: sampleRate,
                    options: options
                )
                continuation.resume(returning: result)
            }
        }

        AppLogger.log("[QwenASR] Transcribed \(samples.count / sampleRate)s audio → \(text.count) chars")
        return text
    }

    func transcribeStreaming(
        samples: [Float],
        sampleRate: Int = 16000,
        language: String? = nil
    ) -> AsyncThrowingStream<TranscriptionSegment, Error>? {
        let currentStreaming: StreamingASR? = queue.sync { _streamingASR }
        guard let currentStreaming else { return nil }

        let config = StreamingASRConfig(
            language: language
        )

        return currentStreaming.transcribeStream(
            audio: samples,
            sampleRate: sampleRate,
            config: config
        )
    }

    // MARK: - SpeechProvider Conformance (Data-based)

    func transcribe(audioData: Data, timeout: TimeInterval = 300) async throws -> String {
        let samples = Self.wavDataToFloat32(audioData)
        return try await transcribe(samples: samples)
    }

    // MARK: - Helpers

    static func wavDataToFloat32(_ data: Data) -> [Float] {
        let headerSize = 44
        guard data.count > headerSize else { return [] }
        let pcmData = data.subdata(in: headerSize..<data.count)
        let sampleCount = pcmData.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { buffer in
            let int16Ptr = buffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Ptr[i]) / 32768.0
            }
        }
        return samples
    }
}
