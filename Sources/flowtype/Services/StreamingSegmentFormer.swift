import Foundation
import AVFoundation

/// VAD response from the Python server's /vad endpoint.
private struct VadResponse: Codable {
    let hasSpeech: Bool
    let speechRatio: Double
    let trailingSilenceMs: Int
    let suggestCut: Bool

    enum CodingKeys: String, CodingKey {
        case hasSpeech = "has_speech"
        case speechRatio = "speech_ratio"
        case trailingSilenceMs = "trailing_silence_ms"
        case suggestCut = "suggest_cut"
    }
}

/// VAD-driven adaptive segment former. Replaces AudioSlicer.
///
/// Receives PCM frames from the audio tap, periodically sends ~1s chunks
/// to the server's /vad endpoint, and uses the response to decide when to
/// cut segments. Falls back to amplitude-based silence detection when VAD
/// is unavailable.
final class StreamingSegmentFormer: @unchecked Sendable {
    // MARK: - Configuration

    var minDuration: Double = 3.0
    var maxDuration: Double = 30.0
    var overlapDuration: Double = 1.0
    var vadSilenceThresholdMs: Int = 800
    var vadRequestTimeoutMs: Int = 500
    var vadMaxFailures: Int = 3
    var amplitudeSilenceThresholdDB: Float = -40.0
    var amplitudeSilenceDuration: Double = 0.5

    /// Recognition queue depth, updated externally for pressure adaptation.
    var pendingQueueDepth: Int = 0

    // MARK: - State

    /// Serial queue protecting all mutable state from concurrent access
    /// (audio tap thread vs. VAD response task).
    private let stateQueue = DispatchQueue(label: "flowtype.segment-former")

    private let sampleRate: Double = 16000
    private var segmentIndex: Int = 0
    private var segmentBuffer: [Float] = []
    private var vadChunkBuffer: [Float] = []
    private var overlapBuffer: [Float] = []
    private var isCollecting = false

    private var segmentContinuation: AsyncStream<AudioSegment>.Continuation?

    // VAD state
    private var vadFailureCount: Int = 0
    private var vadDegraded: Bool = false
    private var vadRequestInFlight: Bool = false

    // Amplitude fallback state
    private var silenceFrameCount: Int = 0
    private var _silenceThresholdLinear: Float = 0
    private var _silenceFrameThreshold: Int = 0
    private var _overlapFrameCount: Int = 0
    private var _minFrameCount: Int = 0
    private var _maxFrameCount: Int = 0

    // VAD chunk size: ~1s = 16000 frames
    private let vadChunkSize: Int = 16000

    // MARK: - Public API

    func startForming() -> AsyncStream<AudioSegment> {
        segmentIndex = 0
        segmentBuffer.removeAll()
        vadChunkBuffer.removeAll()
        overlapBuffer.removeAll()
        silenceFrameCount = 0
        vadFailureCount = 0
        vadDegraded = false
        vadRequestInFlight = false
        isCollecting = true

        // Cache amplitude fallback thresholds
        _silenceThresholdLinear = pow(10, amplitudeSilenceThresholdDB / 20)
        _silenceFrameThreshold = Int(amplitudeSilenceDuration * sampleRate)
        _overlapFrameCount = Int(overlapDuration * sampleRate)
        _minFrameCount = Int(minDuration * sampleRate)
        _maxFrameCount = Int(maxDuration * sampleRate)

        let stream = AsyncStream<AudioSegment> { continuation in
            self.segmentContinuation = continuation
        }
        return stream
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let frames = Array(UnsafeBufferPointer(start: data, count: count))
        stateQueue.sync {
            guard isCollecting else { return }
            appendFrames(frames)
        }
    }

    func finish() {
        stateQueue.sync {
            guard isCollecting else { return }
            isCollecting = false

            // Emit whatever remains — user's last words, never discard
            if !segmentBuffer.isEmpty {
                emitSegment(cutReason: .sessionEnded)
            }

            segmentContinuation?.finish()
            segmentContinuation = nil
        }
    }

    // MARK: - Frame Processing

    private func appendFrames(_ frames: [Float]) {
        segmentBuffer.append(contentsOf: frames)
        vadChunkBuffer.append(contentsOf: frames)

        // Max duration guard rail — always force cut
        if segmentBuffer.count >= _maxFrameCount {
            AppLogger.log("[SegmentFormer] Max duration (\(maxDuration)s) reached, force cutting")
            emitSegment(cutReason: .maxDurationReached)
            return
        }

        // If VAD is degraded, use amplitude fallback
        if vadDegraded || !WhisperServerManager.shared.isServerReady {
            amplitudeFallback(frames: frames)
            return
        }

        // Send VAD chunk when buffer is full (~1s)
        if vadChunkBuffer.count >= vadChunkSize && !vadRequestInFlight {
            let chunk = Array(vadChunkBuffer.prefix(vadChunkSize))
            vadChunkBuffer = Array(vadChunkBuffer.dropFirst(vadChunkSize))
            sendVadRequest(chunk: chunk)
        }
    }

    // MARK: - VAD Communication

    private func sendVadRequest(chunk: [Float]) {
        guard let wavData = floatArrayToWAV(chunk) else { return }

        vadRequestInFlight = true
        let timeoutMs = vadRequestTimeoutMs

        Task.detached { [weak self] in
            guard let self else { return }

            do {
                let response = try await self.postVad(wavData: wavData, timeoutMs: timeoutMs)
                self.stateQueue.sync {
                    self.vadRequestInFlight = false
                    self.vadFailureCount = 0
                    self.handleVadResponse(response)
                }
            } catch {
                self.stateQueue.sync {
                    self.vadRequestInFlight = false
                    self.vadFailureCount += 1
                    if self.vadFailureCount >= self.vadMaxFailures && !self.vadDegraded {
                        self.vadDegraded = true
                        AppLogger.log("[SegmentFormer] VAD degraded after \(self.vadMaxFailures) failures, falling back to amplitude mode")
                    }
                }
            }
        }
    }

    private func postVad(wavData: Data, timeoutMs: Int) async throws -> VadResponse {
        let port = WhisperServerManager.shared.port ?? 8765
        guard let url = URL(string: "http://127.0.0.1:\(port)/vad") else {
            throw SpeechProviderError.transcriptionFailed("Invalid VAD URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"vad_chunk.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(VadResponse.self, from: data)
    }

    private func handleVadResponse(_ response: VadResponse) {
        guard isCollecting else { return }

        let segmentDuration = Double(segmentBuffer.count) / sampleRate

        // Min guard rail
        if segmentDuration < minDuration { return }

        // Pressure-adapted threshold
        let silenceThreshold: Int
        if pendingQueueDepth >= 2 {
            silenceThreshold = 300 // aggressive: cut at 300ms silence
        } else {
            silenceThreshold = vadSilenceThresholdMs
        }

        let shouldCut: Bool
        if response.suggestCut {
            shouldCut = true
        } else if !response.hasSpeech && response.trailingSilenceMs >= silenceThreshold {
            shouldCut = true
        } else {
            shouldCut = false
        }

        if shouldCut {
            AppLogger.log("[SegmentFormer] VAD response: suggest_cut=\(response.suggestCut), trailing_silence=\(response.trailingSilenceMs)ms, segment=\(String(format: "%.1f", segmentDuration))s -> cutting")
            emitSegment(cutReason: .vadSpeechEnd)
        }
    }

    // MARK: - Amplitude Fallback

    private func amplitudeFallback(frames: [Float]) {
        let threshold = _silenceThresholdLinear

        for sample in frames {
            if abs(sample) < threshold {
                silenceFrameCount += 1
            } else {
                silenceFrameCount = 0
            }

            let currentFrames = segmentBuffer.count
            if silenceFrameCount >= _silenceFrameThreshold && currentFrames >= _minFrameCount {
                AppLogger.log("[SegmentFormer] Amplitude fallback: silence detected, segment=\(String(format: "%.1f", Double(currentFrames) / sampleRate))s -> cutting")
                emitSegment(cutReason: .vadSpeechEnd)
                silenceFrameCount = 0
                return
            }
        }
    }

    // MARK: - Segment Emission

    private func emitSegment(cutReason: CutReason) {
        guard !segmentBuffer.isEmpty else { return }

        // Build segment audio: overlap prefix + current segment
        var segmentAudio = overlapBuffer
        segmentAudio.append(contentsOf: segmentBuffer)

        let overlapDur = Double(overlapBuffer.count) / sampleRate

        // Update overlap buffer for next segment
        let overlapFrames = min(segmentBuffer.count, _overlapFrameCount)
        overlapBuffer = Array(segmentBuffer.suffix(overlapFrames))

        // Clear segment buffer and VAD chunk buffer
        segmentBuffer.removeAll()
        vadChunkBuffer.removeAll()
        silenceFrameCount = 0

        // Convert to WAV and emit
        guard let wavData = floatArrayToWAV(segmentAudio) else {
            AppLogger.log("[SegmentFormer] Failed to convert segment to WAV")
            return
        }

        segmentIndex += 1
        let duration = Double(segmentAudio.count) / sampleRate

        let segment = AudioSegment(
            index: segmentIndex,
            audioData: wavData,
            duration: duration,
            overlapDuration: overlapDur,
            cutReason: cutReason
        )

        AppLogger.log("[SegmentFormer] Emitted segment #\(segmentIndex): \(String(format: "%.1f", duration))s, cutReason=\(cutReason), queueDepth=\(pendingQueueDepth)")
        segmentContinuation?.yield(segment)
    }

    // MARK: - WAV Conversion

    private func floatArrayToWAV(_ frames: [Float]) -> Data? {
        guard !frames.isEmpty else { return nil }

        var int16Data = Data(count: frames.count * 2)
        int16Data.withUnsafeMutableBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in frames.indices {
                let clamped = max(-1.0, min(1.0, frames[i]))
                buffer[i] = Int16(clamped * 32767.0).littleEndian
            }
        }

        let header = AudioFormatConverter.createWAVHeader(
            dataSize: int16Data.count,
            sampleRate: Int32(sampleRate),
            channels: 1
        )
        return header + int16Data
    }
}
