import Foundation
import AVFoundation

/// A real-time audio slice produced by the AudioSlicer.
struct AudioSlice: @unchecked Sendable {
    let index: Int
    let audioData: Data
    let duration: Double
    let isForced: Bool
}

/// Real-time audio slicer with silence detection + max-duration fallback.
///
/// Strategy:
/// 1. Accumulate converted PCM frames into an internal buffer.
/// 2. Every `analysisInterval` frames, compute RMS energy of the trailing window.
/// 3. If energy stays below `silenceThreshold` for `silenceDuration`, and the
///    current slice length is within [minSliceDuration, maxSliceDuration],
///    emit a slice at the silence point.
/// 4. If the slice reaches `maxSliceDuration` without finding a silence point,
///    force-emit a slice (isForced = true).
/// 5. Each emitted slice retains `overlapDuration` of audio at its tail,
///    which is also prepended to the next slice to aid cross-segment merging.
final class AudioSlicer: @unchecked Sendable {
    // MARK: - Configuration

    var maxSliceDuration: Double = 15.0
    var minSliceDuration: Double = 3.0
    var silenceThresholdDB: Float = -40.0
    var silenceDuration: Double = 0.5
    var overlapDuration: Double = 1.0

    // MARK: - State

    private let sampleRate: Double = 16000
    private var sliceIndex: Int = 0
    private var sliceBuffer: [Float] = []
    private var overlapBuffer: [Float] = []
    private var silenceFrameCount: Int = 0
    private var isCollecting = false

    private var sliceContinuation: AsyncStream<AudioSlice>.Continuation?
    private var _stream: AsyncStream<AudioSlice>?

    // Cached thresholds — computed once in startSlicing() to avoid per-sample overhead.
    private var _silenceThresholdLinear: Float = 0
    private var _silenceFrameThreshold: Int = 0
    private var _overlapFrameCount: Int = 0
    private var _maxFrameCount: Int = 0
    private var _minFrameCount: Int = 0

    // MARK: - Public API

    func startSlicing() -> AsyncStream<AudioSlice> {
        sliceIndex = 0
        sliceBuffer.removeAll()
        overlapBuffer.removeAll()
        silenceFrameCount = 0
        isCollecting = true

        _silenceThresholdLinear = pow(10, silenceThresholdDB / 20)
        _silenceFrameThreshold = Int(silenceDuration * sampleRate)
        _overlapFrameCount = Int(overlapDuration * sampleRate)
        _maxFrameCount = Int(maxSliceDuration * sampleRate)
        _minFrameCount = Int(minSliceDuration * sampleRate)

        let stream = AsyncStream<AudioSlice> { continuation in
            self.sliceContinuation = continuation
        }
        _stream = stream
        return stream
    }

    func appendFrames(_ frames: [Float]) {
        guard isCollecting else { return }

        let threshold = _silenceThresholdLinear
        let silenceThresh = _silenceFrameThreshold
        let minFrames = _minFrameCount
        let maxFrames = _maxFrameCount

        for sample in frames {
            sliceBuffer.append(sample)

            if abs(sample) < threshold {
                silenceFrameCount += 1
            } else {
                silenceFrameCount = 0
            }

            let currentFrames = sliceBuffer.count
            if silenceFrameCount >= silenceThresh
                && currentFrames >= minFrames
                && currentFrames <= maxFrames {
                let cutFrame = currentFrames - silenceFrameCount
                emitSlice(upTo: cutFrame, isForced: false)
                silenceFrameCount = 0
                continue
            }

            if currentFrames >= maxFrames {
                emitSlice(upTo: currentFrames, isForced: true)
                silenceFrameCount = 0
            }
        }
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let frames = Array(UnsafeBufferPointer(start: data, count: count))
        appendFrames(frames)
    }

    func finishSlicing() {
        guard isCollecting else { return }
        isCollecting = false

        if sliceBuffer.count >= _minFrameCount {
            emitSlice(upTo: sliceBuffer.count, isForced: false, isFinal: true)
        } else if !sliceBuffer.isEmpty {
            let combined = overlapBuffer + sliceBuffer
            if combined.count >= _minFrameCount {
                emitRawSlice(audio: combined, isForced: false, isFinal: true)
            }
        }

        sliceContinuation?.finish()
        sliceContinuation = nil
    }

    // MARK: - Private

    private func emitSlice(upTo cutFrame: Int, isForced: Bool, isFinal: Bool = false) {
        guard cutFrame > 0 else { return }

        var sliceAudio = overlapBuffer
        sliceAudio.append(contentsOf: sliceBuffer[0..<cutFrame])

        let overlapStart = max(0, cutFrame - _overlapFrameCount)
        overlapBuffer = Array(sliceBuffer[overlapStart..<cutFrame])

        let remainingStart = cutFrame
        if remainingStart < sliceBuffer.count {
            sliceBuffer = Array(sliceBuffer[remainingStart...])
        } else {
            sliceBuffer.removeAll()
        }

        emitRawSlice(audio: sliceAudio, isForced: isForced, isFinal: isFinal)
    }

    private func emitRawSlice(audio: [Float], isForced: Bool, isFinal: Bool) {
        guard !audio.isEmpty else { return }

        guard let wavData = Self.floatArrayToWAV(audio, sampleRate: sampleRate) else {
            print("[AudioSlicer] Failed to convert slice to WAV")
            return
        }

        sliceIndex += 1
        let duration = Double(audio.count) / sampleRate
        let slice = AudioSlice(
            index: sliceIndex,
            audioData: wavData,
            duration: duration,
            isForced: isForced
        )

        print("[AudioSlicer] Emitted slice #\(sliceIndex): \(String(format: "%.1f", duration))s, \(wavData.count) bytes, forced=\(isForced)")
        sliceContinuation?.yield(slice)
    }

    /// Convert a float32 PCM array to 16-bit WAV data using AudioFormatConverter's header.
    private static func floatArrayToWAV(_ frames: [Float], sampleRate: Double) -> Data? {
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
