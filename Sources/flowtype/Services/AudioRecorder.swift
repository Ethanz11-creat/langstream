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
    /// Audio segment stream: each Data is a complete WAV file (16kHz mono 16-bit).
    /// Emitted whenever the 60s buffer fills up; the final partial segment is
    /// NOT emitted here — it is returned by `stopRecording()`.
    let segments: AsyncStream<Data>
    /// Real-time audio slice stream for parallel ASR.
    /// Each slice is a short WAV segment suitable for immediate transcription.
    let slices: AsyncStream<AudioSlice>
}

final class AudioRecorder: @unchecked Sendable {
    // NOTE: Create a fresh engine for each session to avoid state issues.
    private var engine: AVAudioEngine?
    private nonisolated(unsafe) var audioBuffer: AVAudioPCMBuffer?
    private nonisolated(unsafe) var amplitudeContinuation: AsyncStream<Float>.Continuation?
    private nonisolated(unsafe) var segmentContinuation: AsyncStream<Data>.Continuation?

    // Accumulated 60s segments (internal, since callers may not consume the segment stream).
    private nonisolated(unsafe) var recordedSegments: [Data] = []

    // Real-time audio slicer for parallel ASR
    private var audioSlicer: AudioSlicer?

    // Recording state — protected by stateLock because accessed from both
    // main thread (start/stop) and audio tap callback thread.
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

    /// Optional callback to forward real-time audio buffers to a streaming recognizer.
    /// Called on the audio tap thread with the converted 16kHz mono float32 buffer.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called when no audio tap callbacks have been received for a while (recording freeze).
    var onRecordingFrozen: (() -> Void)?

    // MARK: - Heartbeat detection
    private nonisolated(unsafe) var lastTapCallCount = 0
    private nonisolated(unsafe) var lastTapTimestamp: Date?
    private var heartbeatTimer = CancellableTimer()
    private let heartbeatInterval: TimeInterval = 2.0
    private let heartbeatTimeout: TimeInterval = 5.0

    /// Check current microphone permission status without triggering a dialog.
    /// Returns raw value: 0=undetermined, 1=denied, 2=granted
    func authorizationStatus() -> Int {
        AVAudioApplication.shared.recordPermission.rawValue
    }

    /// Request microphone permission. On macOS with ad-hoc signing, the system
    /// may silently deny without showing a dialog. Callers should check status
    /// afterward and guide the user to System Settings if needed.
    func requestPermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        // macOS uses FourCC values ('undt', 'deny', 'grnt'), not 0/1/2.
        // Compare enum cases directly instead of rawValue.
        AppLogger.log("AudioRecorder: mic status = \(status) (undetermined/denied/granted)")

        // Only request if undetermined; if already denied, don't re-prompt
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

    // nonisolated — ensures installTap closure is NOT created on @MainActor
    nonisolated func startRecording() async throws -> RecordingOutput {
        guard await requestPermission() else {
            throw AudioRecorderError.permissionDenied
        }

        // Fresh engine for each session
        let freshEngine = AVAudioEngine()
        self.engine = freshEngine

        // Start real-time audio slicer
        let slicer = AudioSlicer()
        let config = Configuration.shared
        slicer.maxSliceDuration = config.sliceMaxDuration
        slicer.minSliceDuration = config.sliceMinDuration
        slicer.silenceThresholdDB = config.sliceSilenceThresholdDB
        slicer.silenceDuration = config.sliceSilenceDuration
        slicer.overlapDuration = config.sliceOverlapDuration
        self.audioSlicer = slicer
        let sliceStream = slicer.startSlicing()

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

        audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 60)!
        recordedSegments = []
        stateLock.withLock {
            _isRecording = true
            _isStopping = false
        }
        tapCallCount = 0
        lastTapCallCount = 0
        lastTapTimestamp = Date()
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

        // Segment stream — emitted when 60s buffer rolls over (legacy)
        let segmentStream = AsyncStream<Data> { continuation in
            self.segmentContinuation = continuation
        }

        // Amplitude stream — VU meter
        let amplitudeStream = AsyncStream<Float> { continuation in
            self.amplitudeContinuation = continuation

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
                guard let self = self else {
                    print("[AudioRecorder] Tap callback: self is nil")
                    return
                }
                guard self.isRecording || self.isStopping else {
                    return
                }

                self.tapCallCount += 1
                let callIndex = self.tapCallCount
                let inputFrames = Int(buffer.frameLength)
                print("[AudioRecorder] Tap #\(callIndex) fired: inputFrames=\(inputFrames), time=\(time)")

                // Converted buffer capacity: same as input buffer size is sufficient
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
                    print("[AudioRecorder] Tap #\(callIndex): failed to create convertedBuffer")
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

                if let err = error {
                    print("[AudioRecorder] Tap #\(callIndex): converter error: \(err)")
                }
                let outputFrames = Int(convertedBuffer.frameLength)
                print("[AudioRecorder] Tap #\(callIndex): converted outputFrames=\(outputFrames)")

                // Forward to streaming recognizer (e.g., AppleSpeech) for real-time preview
                self.onAudioBuffer?(convertedBuffer)

                // Feed to real-time slicer for parallel ASR
                self.audioSlicer?.appendBuffer(convertedBuffer)

                // Append to accumulated full buffer
                if let mainBuffer = self.audioBuffer,
                   let mainData = mainBuffer.floatChannelData?[0],
                   let convertedData = convertedBuffer.floatChannelData?[0] {
                    let currentLength = Int(mainBuffer.frameLength)
                    let newLength = Int(convertedBuffer.frameLength)
                    if currentLength + newLength <= Int(mainBuffer.frameCapacity) {
                        for i in 0..<newLength {
                            mainData[currentLength + i] = convertedData[i]
                        }
                        mainBuffer.frameLength = AVAudioFrameCount(currentLength + newLength)
                        print("[AudioRecorder] Tap #\(callIndex): appended to audioBuffer, totalFrames=\(currentLength + newLength)")
                    } else {
                        // Buffer full: flush as a completed segment, reset, then append
                        print("[AudioRecorder] Tap #\(callIndex): audioBuffer full (60s), flushing segment")
                        if let wavData = AudioFormatConverter.normalizeAndConvertToWAV(mainBuffer) {
                            self.recordedSegments.append(wavData)
                            self.segmentContinuation?.yield(wavData)
                        }
                        mainBuffer.frameLength = 0
                        for i in 0..<newLength {
                            mainData[i] = convertedData[i]
                        }
                        mainBuffer.frameLength = AVAudioFrameCount(newLength)
                        print("[AudioRecorder] Tap #\(callIndex): reset buffer, new totalFrames=\(newLength)")
                    }
                } else {
                    print("[AudioRecorder] Tap #\(callIndex): audioBuffer is nil or channel data missing")
                }

                // Yield average amplitude for VU meter
                if let data = convertedBuffer.floatChannelData?[0] {
                    let frames = Int(convertedBuffer.frameLength)
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

        return RecordingOutput(amplitude: amplitudeStream, segments: segmentStream, slices: sliceStream)
    }

    /// Stops recording and returns all audio data.
    /// - `segments`: completed 60s WAV segments that were emitted during recording
    /// - `finalData`: the last (partial) segment as WAV, trimmed and normalized
    nonisolated func stopRecording() -> (segments: [Data], finalData: Data?) {
        print("[AudioRecorder] stopRecording called, tapCallCount=\(tapCallCount)")

        // Idempotent guard: if already stopped, return empty
        let wasRecording = stateLock.withLock {
            let was = _isRecording || _isStopping
            _isStopping = true
            _isRecording = false
            return was
        }
        if !wasRecording {
            print("[AudioRecorder] stopRecording: already stopped, returning empty")
            return ([], nil)
        }

        if tapCallCount == 0 {
            print("[AudioRecorder] CRITICAL: No tap callbacks received. Possible causes:")
            print("  - Microphone permission denied (check System Settings > Privacy > Microphone)")
            print("  - No input device available")
            print("  - AVAudioEngine failed to start")
        }

        heartbeatTimer.cancel()
        lastTapTimestamp = nil
        amplitudeContinuation?.finish()
        amplitudeContinuation = nil
        segmentContinuation?.finish()
        segmentContinuation = nil

        // Stop real-time slicer and emit final slice
        audioSlicer?.finishSlicing()
        audioSlicer = nil

        // Stop engine and remove tap
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        stateLock.withLock {
            _isStopping = false
        }

        // Combine internally accumulated segments with the final partial buffer.
        let allSegments = self.recordedSegments
        self.recordedSegments = []

        guard let buffer = audioBuffer else {
            print("[AudioRecorder] stopRecording: audioBuffer is nil")
            return (allSegments, nil)
        }

        let rawFrames = Int(buffer.frameLength)
        print("[AudioRecorder] stopRecording: raw audioBuffer has \(rawFrames) frames")

        // Trim silence, normalize, convert to WAV
        let trimmedBuffer = AudioFormatConverter.trimSilence(buffer)
        let trimmedFrames = Int(trimmedBuffer.frameLength)
        print("[AudioRecorder] stopRecording: after trimSilence has \(trimmedFrames) frames")

        let finalData = AudioFormatConverter.normalizeAndConvertToWAV(trimmedBuffer)

        if let data = finalData {
            let payload = data.count - 44
            let duration = Double(payload) / 32000.0
            print("[AudioRecorder] stopRecording: final WAV \(data.count) bytes, ~\(String(format: "%.2f", duration))s")
        } else {
            print("[AudioRecorder] stopRecording: normalizeAndConvertToWAV returned nil")
        }

        // Debug dump if enabled
        if let data = finalData, Configuration.shared.dumpAudio {
            dumpWAVData(data)
        }

        return (allSegments, finalData)
    }

    private func dumpWAVData(_ data: Data) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "dump_\(formatter.string(from: Date())).wav"
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/flowtype", isDirectory: true) else { return }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(filename)
            try data.write(to: url)
            print("[AudioRecorder] Dumped audio to \(url.path)")
        } catch {
            print("[AudioRecorder] Failed to dump audio: \(error)")
        }
    }
}
