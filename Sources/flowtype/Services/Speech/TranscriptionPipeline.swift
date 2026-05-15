import Foundation

/// Ordered transcription dispatch with dynamic worker scaling and quality assessment.
///
/// Consumes an `AsyncStream<AudioSegment>`, dispatches each to Whisper (with
/// AppleSpeech fallback), and produces an `AsyncStream<SegmentResult>`.
final class TranscriptionPipeline: @unchecked Sendable {
    private var _pendingDepth: Int = 0
    private(set) var pendingDepth: Int {
        get { _pendingDepth }
        set { _pendingDepth = newValue }
    }

    private var streamTask: Task<Void, Never>?

    // Worker scaling state
    private var maxWorkers: Int = 1
    private var recentLatencies: [TimeInterval] = []
    private let maxLatencyHistory = 3

    // Experimental context (read from config at start)
    private var contextEnabled: Bool = false
    private var conditionEnabled: Bool = false

    /// Reference to the accumulator for reading stable prefix (context passing).
    /// Set before calling start() if experimental context is enabled.
    weak var accumulator: StableTextAccumulator?

    func start(
        segments: AsyncStream<AudioSegment>,
        provider: SpeechProvider,
        fallback: SpeechProvider
    ) -> AsyncStream<SegmentResult> {
        let config = Configuration.shared
        contextEnabled = config.experimentalContextEnabled
        conditionEnabled = config.experimentalConditionEnabled

        let (stream, continuation) = AsyncStream<SegmentResult>.makeStream()

        streamTask = Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.run(
                segments: segments,
                provider: provider,
                fallback: fallback,
                continuation: continuation
            )
            continuation.finish()
        }

        return stream
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Main Loop

    private func run(
        segments: AsyncStream<AudioSegment>,
        provider: SpeechProvider,
        fallback: SpeechProvider,
        continuation: AsyncStream<SegmentResult>.Continuation
    ) async {
        let serverReady = WhisperServerManager.shared.isServerReady

        await withTaskGroup(of: SegmentResult.self) { group in
            var iterator = segments.makeAsyncIterator()
            var activeCount = 0
            var streamEnded = false

            repeat {
                while activeCount < maxWorkers && !streamEnded {
                    if let segment = await iterator.next() {
                        group.addTask { [weak self] in
                            await self?.transcribeOne(
                                segment: segment,
                                provider: provider,
                                fallback: fallback,
                                serverReady: serverReady
                            ) ?? SegmentResult(
                                index: segment.index,
                                text: "",
                                quality: .empty,
                                whisperSegments: nil,
                                cutReason: segment.cutReason,
                                overlapDuration: segment.overlapDuration
                            )
                        }
                        activeCount += 1
                        pendingDepth = activeCount
                    } else {
                        streamEnded = true
                        break
                    }
                }

                if activeCount > 0 {
                    if let result = await group.next() {
                        activeCount -= 1
                        pendingDepth = activeCount
                        continuation.yield(result)
                        adjustWorkerCount()
                    }
                }
            } while activeCount > 0 || !streamEnded
        }
    }

    // MARK: - Single Segment Transcription

    private func transcribeOne(
        segment: AudioSegment,
        provider: SpeechProvider,
        fallback: SpeechProvider,
        serverReady: Bool
    ) async -> SegmentResult {
        let startTime = Date()

        // Build context prompt
        let prompt: String?
        let useCondition: Bool
        if contextEnabled, let acc = accumulator {
            let quality = acc.lastStableQuality
            if quality != .hallucination && quality != .empty {
                let stable = acc.stablePrefix
                prompt = stable.isEmpty ? nil : String(stable.suffix(200))
            } else {
                prompt = nil
            }
        } else {
            prompt = nil
        }
        useCondition = conditionEnabled

        // Try primary provider (Whisper)
        if serverReady {
            do {
                let detail = try await provider.transcribeWithDetails(
                    audioData: segment.audioData,
                    initialPrompt: prompt,
                    conditionOnPrevious: useCondition,
                    timeout: 30
                )
                let elapsed = Date().timeIntervalSince(startTime)
                recordLatency(elapsed)

                let quality = assessQuality(text: detail.text, segments: detail.segments)
                AppLogger.log("[Pipeline] Segment #\(segment.index): Whisper completed in \(String(format: "%.1f", elapsed))s, quality=\(quality), text='\(detail.text.prefix(60))'")

                return SegmentResult(
                    index: segment.index,
                    text: detail.text,
                    quality: quality,
                    whisperSegments: detail.segments,
                    cutReason: segment.cutReason,
                    overlapDuration: segment.overlapDuration
                )
            } catch {
                AppLogger.log("[Pipeline] Segment #\(segment.index): Whisper failed: \(error)")
            }
        }

        // Fallback to AppleSpeech
        do {
            let text = try await fallback.transcribe(audioData: segment.audioData, timeout: 10)
            if !text.isEmpty {
                AppLogger.log("[Pipeline] Segment #\(segment.index): AppleSpeech fallback: '\(text.prefix(40))'")
                return SegmentResult(
                    index: segment.index,
                    text: text,
                    quality: .fallback,
                    whisperSegments: nil,
                    cutReason: segment.cutReason,
                    overlapDuration: segment.overlapDuration
                )
            }
        } catch {
            AppLogger.log("[Pipeline] Segment #\(segment.index): all providers failed: \(error)")
        }

        return SegmentResult(
            index: segment.index,
            text: "",
            quality: .empty,
            whisperSegments: nil,
            cutReason: segment.cutReason,
            overlapDuration: segment.overlapDuration
        )
    }

    // MARK: - Quality Assessment

    private func assessQuality(text: String, segments: [WhisperSegment]?) -> SegmentQuality {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        if let segments = segments, !segments.isEmpty {
            let filteredCount = segments.filter(\.filtered).count
            if filteredCount > segments.count / 2 { return .hallucination }
        }
        return .normal
    }

    // MARK: - Worker Scaling

    private func recordLatency(_ latency: TimeInterval) {
        recentLatencies.append(latency)
        if recentLatencies.count > maxLatencyHistory {
            recentLatencies.removeFirst()
        }
    }

    private func adjustWorkerCount() {
        let avgLatency = recentLatencies.isEmpty ? 0 :
            recentLatencies.reduce(0, +) / Double(recentLatencies.count)
        let queued = pendingDepth

        if maxWorkers == 1 && queued >= 2 && avgLatency > 5.0 {
            maxWorkers = 2
            AppLogger.log("[Pipeline] Worker adjustment: 1 -> 2 (queued=\(queued), avgLatency=\(String(format: "%.1f", avgLatency))s)")
        } else if maxWorkers == 2 && queued == 0 && avgLatency < 3.0 {
            maxWorkers = 1
            AppLogger.log("[Pipeline] Worker adjustment: 2 -> 1 (queued=\(queued), avgLatency=\(String(format: "%.1f", avgLatency))s)")
        }
    }
}
