@preconcurrency import AVFoundation
import os

enum AudioRecorderError: Error, Equatable {
    case permissionDenied
    case engineStartFailed
    case formatCreationFailed
}

/// Output streams from a recording session.
struct RecordingOutput: @unchecked Sendable {
    /// VU-meter amplitude stream (for UI animation).
    let amplitude: AsyncStream<Float>
}

final class AudioRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private nonisolated(unsafe) var amplitudeContinuation: AsyncStream<Float>.Continuation?

    // Raw sample accumulator for batch ASR (Qwen3-ASR)
    private var rawSamples: [Float] = []
    private let sampleLock = OSAllocatedUnfairLock()

    // Recording state
    private let stateLock = OSAllocatedUnfairLock()
    private var _isRecording = false
    private var _isStopping = false

    var isRecording: Bool {
        stateLock.withLock { _isRecording }
    }
    var isStopping: Bool {
        stateLock.withLock { _isStopping }
    }

    // Diagnostics
    private nonisolated(unsafe) var tapCallCount = 0

    /// Callback to forward real-time audio buffers to a streaming recognizer.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called when no audio tap callbacks have been received for a while.
    var onRecordingFrozen: (() -> Void)?

    // MARK: - Heartbeat detection
    private nonisolated(unsafe) var lastTapCallCount = 0
    private nonisolated(unsafe) var lastTapTimestamp: Date?
    private var heartbeatTimer = CancellableTimer()
    private let heartbeatInterval: TimeInterval = 2.0
    private let heartbeatTimeout: TimeInterval = 5.0

    func authorizationStatus() -> Int {
        AVAudioApplication.shared.recordPermission.rawValue
    }

    func requestPermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        AppLogger.log("AudioRecorder: mic status = \(status) (undetermined/denied/granted)")
        guard status == .undetermined else {
            AppLogger.log("AudioRecorder: mic status is not undetermined, skipping request")
            return status == .granted
        }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        AppLogger.log("AudioRecorder: mic request result = \(granted)")
        return granted
    }

    nonisolated func startRecording() async throws -> RecordingOutput {
        guard await requestPermission() else {
            throw AudioRecorderError.permissionDenied
        }

        let freshEngine = AVAudioEngine()
        self.engine = freshEngine

        let inputNode = freshEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioRecorder] Hardware input format: \(inputFormat)")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioRecorderError.formatCreationFailed
        }

        stateLock.withLock {
            _isRecording = true
            _isStopping = false
        }
        tapCallCount = 0
        lastTapCallCount = 0
        lastTapTimestamp = Date()
        sampleLock.withLock {
            rawSamples.removeAll(keepingCapacity: true)
        }
        heartbeatTimer.schedule(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] in
            guard let self = self else { return }
            guard self.isRecording && !self.isStopping else { return }
            let currentCount = self.tapCallCount
            let now = Date()
            if currentCount > self.lastTapCallCount {
                self.lastTapCallCount = currentCount
                self.lastTapTimestamp = now
            } else if let lastTap = self.lastTapTimestamp, now.timeIntervalSince(lastTap) > self.heartbeatTimeout {
                print("[AudioRecorder] HEARTBEAT FAILURE: No tap callbacks for \(self.heartbeatTimeout)s. Auto-stopping.")
                self.heartbeatTimer.cancel()
                self.onRecordingFrozen?()
            }
        }

        let amplitudeStream = AsyncStream<Float> { continuation in
            self.amplitudeContinuation = continuation

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
                guard let self = self else { return }
                guard self.isRecording || self.isStopping else { return }

                self.tapCallCount += 1

                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
                    return
                }
                var error: NSError?
                let inputBuffer = buffer
                var inputConsumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if !inputConsumed {
                        inputConsumed = true
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                    outStatus.pointee = .noDataNow
                    return nil
                }

                // Forward to streaming recognizer (AppleSpeech preview)
                self.onAudioBuffer?(convertedBuffer)

                // Accumulate raw samples for batch ASR
                if let data = convertedBuffer.floatChannelData?[0] {
                    let frames = Int(convertedBuffer.frameLength)
                    let samplesArray = Array(UnsafeBufferPointer(start: data, count: frames))
                    self.sampleLock.withLock {
                        self.rawSamples.append(contentsOf: samplesArray)
                    }

                    // Yield average amplitude for VU meter
                    var sum: Float = 0
                    for i in 0..<frames {
                        sum += abs(data[i])
                    }
                    let avg = frames > 0 ? sum / Float(frames) : 0
                    self.amplitudeContinuation?.yield(avg)
                }
            }

            do {
                freshEngine.prepare()
                try freshEngine.start()
                print("[AudioRecorder] Engine prepared and started successfully")
            } catch {
                print("[AudioRecorder] Engine start FAILED: \(error)")
                continuation.finish()
            }
        }

        return RecordingOutput(amplitude: amplitudeStream)
    }

    nonisolated func stopRecording() {
        print("[AudioRecorder] stopRecording called, tapCallCount=\(tapCallCount)")

        let wasRecording = stateLock.withLock {
            let was = _isRecording || _isStopping
            _isStopping = true
            _isRecording = false
            return was
        }
        if !wasRecording {
            print("[AudioRecorder] stopRecording: already stopped")
            return
        }

        if tapCallCount == 0 {
            print("[AudioRecorder] CRITICAL: No tap callbacks received.")
        }

        heartbeatTimer.cancel()
        lastTapTimestamp = nil
        amplitudeContinuation?.finish()
        amplitudeContinuation = nil

        // Stop engine
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        stateLock.withLock {
            _isStopping = false
        }
    }

    /// Take accumulated raw Float32 samples and clear the buffer.
    nonisolated func takeAccumulatedSamples() -> [Float] {
        sampleLock.withLock {
            let samples = rawSamples
            rawSamples.removeAll(keepingCapacity: false)
            return samples
        }
    }
}
