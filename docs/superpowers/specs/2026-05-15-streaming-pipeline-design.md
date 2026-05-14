# Streaming ASR Pipeline Redesign

## Summary

Restructure FlowType's internal audio transcription pipeline from "fixed-duration slicing + batch merge after recording" to "continuous capture + VAD-driven adaptive segmentation + stable commit window". The user-facing interaction model (double-tap start, single/double-tap end, process then inject) does not change. The goal is: minimal wait after recording ends, high-quality text with no duplicates or breaks, and a preview that closely matches the final output.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Interaction model | Record-then-inject (unchanged) | User chose to keep existing UX, improve internal pipeline only |
| Preview source | AppleSpeech (UI only) + Whisper fallback | AppleSpeech for low-latency preview, Whisper for all real ASR |
| Segment formation | Server-side Silero VAD drives cut points | Semantic speech boundaries, not fixed durations |
| Duration constraints | Min 3s guard rail + max 30s guard rail only | No "target range" — segment length determined by speech content |
| Cross-segment context | Isolated by default, experimental toggles for prompt/conditioning | V1 keeps full isolation; A/B testable without code changes |
| Overlap dedup | Edit-distance alignment at segment boundaries | Tolerates minor Whisper transcription variance across slices |
| Stable commit window | StableTextAccumulator with stable/pending split | Ensures ordered, growing, low-rollback text accumulation |

## End-to-End Data Flow

```
Microphone (AVAudioEngine tap, 16kHz mono Float32)
  |
  |---> AppleSpeechProvider.appendAudioBuffer()     [UI preview, independent stream]
  |
  +---> StreamingSegmentFormer
          |  Receives PCM frames, sends ~1s audio chunks to /vad
          |  VAD returns speech boundaries + suggest_cut signal
          |  speech_end -> primary cut point
          |  guard rails: min 3s (merge short segments), max 30s (force cut)
          |  pressure-adaptive: queue backlog -> more aggressive cutting at VAD boundaries
          v
       AsyncStream<AudioSegment>
          |  AudioSegment: index, audioData(WAV), duration, overlapDuration, cutReason
          |
          v
       TranscriptionPipeline
          |  Ordered dispatch, dynamic 1-2 workers
          |  Whisper request with optional initial_prompt (experimental, off by default)
          |  Quality assessment: empty / hallucination / fallback / normal
          |  Returns: SegmentResult(index, text, quality, whisperSegments, cutReason, overlapDuration)
          |
          v
       StableTextAccumulator
          |  Reorder buffer -> process in index order
          |  Overlap dedup via edit-distance alignment
          |  stablePrefix (frozen) / pendingTail (latest, may be revised)
          |  Anomalous segments (empty, hallucination) -> discard
          |  Boundary repair: punctuation, spacing
          v
       committedText (on recording end -> pendingTail force-frozen)
          |
          v
       ASRPostProcessor.process()    [existing post-processing pipeline]
          |
          v
       [optional] LLM Polish
          |
          v
       KeyboardInjector.insertText()
```

## Component Specifications

### 1. Python Server Changes

#### New `/vad` Endpoint

```
POST /vad
Content-Type: multipart/form-data
Body: audio file (16kHz mono 16-bit WAV, ~1s chunk)

Response 200:
{
  "has_speech": true,
  "speech_ratio": 0.82,
  "trailing_silence_ms": 0,
  "suggest_cut": false,
  "speeches": [
    {"start": 0.0, "end": 0.82}
  ]
}
```

Field semantics:
- `has_speech`: whether any voice activity was detected in this chunk
- `speech_ratio`: proportion of chunk duration containing speech (0.0-1.0)
- `trailing_silence_ms`: milliseconds of continuous silence at the end of the chunk
- `suggest_cut`: server-side recommendation. The server maintains a `previous_speech_ratio` across /vad calls within a session (reset on server startup or explicit session reset). True when: trailing_silence_ms >= 500 and speech_ratio < 0.3, OR speech abruptly stopped (previous_speech_ratio > 0.8 and current speech_ratio < 0.2)
- `speeches`: raw speech spans for debugging/logging; client main path does not parse these

Implementation:
- Silero VAD model loaded at startup (~2MB, CPU only, ~1s load time)
- VAD inference <10ms per chunk, runs on main thread (not ThreadPoolExecutor)
- Does not contend with Whisper worker

#### Modified `/transcribe` Endpoint

```
POST /transcribe
Content-Type: multipart/form-data
Body:
  - file: audio WAV
  - initial_prompt: string (optional)
  - condition_on_previous: bool (optional, default false)

Response 200:
{
  "text": "transcribed text (filtered segments excluded)",
  "segments": [
    {
      "text": "segment text",
      "start": 0.0,
      "end": 3.2,
      "no_speech_prob": 0.05,
      "compression_ratio": 1.8,
      "filtered": false,
      "filter_reason": null
    },
    {
      "text": "hallucinated text",
      "start": 3.2,
      "end": 5.1,
      "no_speech_prob": 0.02,
      "compression_ratio": 3.1,
      "filtered": true,
      "filter_reason": "compression_ratio_exceeded"
    }
  ],
  "language": "zh"
}
```

Changes:
- `initial_prompt` and `condition_on_previous` are independent parameters. V1 defaults: both off.
- Each segment includes `filtered` (bool) and `filter_reason` (null, `"compression_ratio_exceeded"`, `"no_speech_high"`, `"repetition_detected"`)
- `text` field contains only non-filtered segment text (backward compatible)
- `segments` array contains all segments including filtered ones
- Filter thresholds: `compression_ratio > 2.4`, `no_speech_prob > 0.6` (unchanged)

Server startup:
- Load Silero VAD (~1s) then Whisper model (~10-30s)
- `/health` response adds `vad_ready: true` field
- `max_workers=1` unchanged (Whisper is the bottleneck)

### 2. StreamingSegmentFormer

Replaces AudioSlicer. VAD-driven adaptive segment formation.

#### Data Model

```swift
struct AudioSegment: Sendable {
    let index: Int
    let audioData: Data         // WAV with overlap prefix
    let duration: Double
    let overlapDuration: Double // how much of audioData is overlap from previous segment
    let cutReason: CutReason
}

enum CutReason: Sendable {
    case vadSpeechEnd
    case maxDurationReached
    case sessionEnded
}
```

#### Internal State

- `segmentBuffer: [Float]` — accumulating PCM for current segment
- `vadChunkBuffer: [Float]` — accumulates ~1s of audio before sending to /vad
- `overlapBuffer: [Float]` — last 1s of previous segment
- `vadState` — tracks VAD response history, degraded mode flag

#### Cut Decision Logic

On each /vad response:

1. If `segmentDuration < 3s` (min guard rail): never cut, regardless of VAD signal
2. If `segmentDuration >= 30s` (max guard rail): force cut (`cutReason: .maxDurationReached`)
3. If `vad.suggest_cut == true`: cut (`cutReason: .vadSpeechEnd`)
4. If `vad.has_speech == false && vad.trailing_silence_ms >= 800`: cut (`cutReason: .vadSpeechEnd`) — client-side fallback for conservative server suggest_cut

No "target range". Segment length is fully determined by speech content. 3s and 30s are guard rails only.

#### Pressure Adaptation

`pendingQueueDepth` is read from TranscriptionPipeline:

- `depth >= 2`: lower silence threshold for cutting — `trailing_silence_ms >= 300` is sufficient (don't wait for `suggest_cut`)
- `depth == 0`: no intervention, let VAD decide naturally

Pressure only affects how quickly the former responds to VAD signals. It does not create artificial cut points.

#### VAD Communication

- vadChunkBuffer fills at ~1s intervals, then POSTs to /vad
- Async fire-and-forget: audio capture is never blocked by VAD latency
- Timeout: 500ms per request
- Failure handling: after 3 consecutive failures, degrade to amplitude mode for the rest of the session

#### Amplitude Fallback Mode

When VAD is unavailable (server down or degraded):
- Per-sample silence detection (threshold -40dB)
- Continuous silence >= 0.5s and segment >= 3s: cut
- Continuous speech >= 30s: force cut
- This ensures the pipeline works even with zero server availability

#### Overlap

- Each emitted segment retains last 1s of audio as `overlapBuffer`
- Next segment audio = `overlapBuffer` + new PCM
- `AudioSegment.overlapDuration` records actual overlap seconds for downstream dedup

#### finish() (User Ends Recording)

- Remaining audio in segmentBuffer emitted unconditionally (`cutReason: .sessionEnded`)
- No minimum duration check — this is the user's last words, never discard
- TranscriptionPipeline treats `.sessionEnded` segments normally (sends to Whisper even if short)

### 3. TranscriptionPipeline

Replaces inline `runStreamingTranscription()` code. Ordered dispatch, context passing, quality assessment.

#### Interface

```swift
final class TranscriptionPipeline: Sendable {
    func start(
        segments: AsyncStream<AudioSegment>,
        provider: SpeechProvider,
        fallback: SpeechProvider
    ) -> AsyncStream<SegmentResult>

    var pendingDepth: Int { get }
    func cancel()
}
```

#### SegmentResult

```swift
struct SegmentResult: Sendable {
    let index: Int
    let text: String
    let quality: SegmentQuality
    let whisperSegments: [WhisperSegment]?
    let cutReason: CutReason
    let overlapDuration: Double
}

enum SegmentQuality: Sendable {
    case normal
    case empty
    case hallucination
    case fallback
}
```

#### Dispatch Model

Sliding-window TaskGroup consuming AsyncStream<AudioSegment>:

- Initial `maxWorkers = 1`
- Scale to 2 when: `queuedSegments >= 2 && avgLatency > 5s`
- Scale back to 1 when: `queuedSegments == 0 && avgLatency < 3s`
- Never exceeds 2 (server is single-threaded)

Per-worker logic:
1. Try Whisper (`/transcribe`, 30s timeout). Parse `segments` array, assess quality.
2. Whisper fail/empty: try AppleSpeech (10s timeout), `quality = .fallback`
3. All fail: `quality = .empty`, `text = ""`
4. No retries — same audio likely yields same result

#### Context Passing (Experimental, V1 Off)

Two independent toggles (stored in Configuration):
- `experimentalContextEnabled`: whether to send `initial_prompt` (last 200 chars of stable prefix, only if last stable quality != .hallucination and != .empty)
- `experimentalConditionEnabled`: whether to set `condition_on_previous = true`

V1: both `false`. Full cross-segment isolation.

#### Quality Assessment

```swift
func assessQuality(text: String, segments: [WhisperSegment]?) -> SegmentQuality {
    if text.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
    if let segments = segments {
        let filteredCount = segments.filter(\.filtered).count
        if filteredCount > segments.count / 2 { return .hallucination }
    }
    return .normal
}
```

#### pendingDepth

Read-only property: `in-flight workers + queued segments`. Updated on dispatch (+1) and completion (-1). StreamingSegmentFormer reads this for pressure adaptation.

### 4. StableTextAccumulator

Core innovation — overlap dedup, boundary fusion, stable/pending window.

#### Interface

```swift
final class StableTextAccumulator: Sendable {
    func accept(_ result: SegmentResult) -> TextSnapshot
    func finalize() -> String
    var stablePrefix: String { get }
    var lastStableQuality: SegmentQuality { get }
}

struct TextSnapshot: Sendable {
    let stable: String
    let pending: String
    let fullText: String
}
```

#### Internal State

- `stablePrefix: String` — frozen text, never modified
- `pendingTail: String` — latest segment text, may be revised on next arrival
- `pendingQuality: SegmentQuality`
- `nextExpectedIndex: Int` — for reordering out-of-order results
- `resultBuffer: [Int: SegmentResult]` — holds results that arrived ahead of order

#### Processing Flow (on each accept)

1. Buffer the result; process sequentially by index (reorder buffer)
2. **Anomaly filter**: `.empty` or `.hallucination` quality -> skip entirely, no state change
3. **Freeze previous pending**: if pendingTail is non-empty, append to stablePrefix
4. **Overlap dedup**: align new text against stable suffix using edit distance
5. **Boundary repair**: fix punctuation/spacing at join point
6. **Update pending**: new text becomes pendingTail

#### Overlap Dedup Algorithm (deduplicateOverlap)

```
Input:
  stableSuffix = last N chars of stablePrefix
  newText = full text of new segment
  estimatedOverlapChars = overlapDuration * ~4 chars/sec (Chinese speech rate)

Process:
  1. Take stableSuffix tail of min(len, estimatedOverlapChars * 2) characters as anchor
  2. For suffix lengths 5, 8, 12, ... of anchor text:
     - Find minimum edit distance match in newText prefix (first half)
     - If best match: editDistance / matchLength < 0.3 -> overlap confirmed
  3. Overlap found: trim matching prefix from newText
     Not found: keep newText as-is

Output:
  newText with duplicate prefix removed
```

Edit distance instead of exact match because Whisper may produce minor variants for the same audio ("用户登录" vs "用户登陆").

#### Boundary Repair (repairBoundary)

- No sentence-ending punctuation at stable tail + non-sentence-start at new text head: join directly
- Both have sentence boundary punctuation: join directly, no extra spacing
- Overlapping punctuation (stable ends with "，", new starts with "，"): deduplicate
- Chinese text: no space between segments. English/mixed: preserve space.

#### finalize()

Force-freeze pendingTail into stablePrefix regardless of quality. Return full stablePrefix. This is the user's last words — always preserve.

#### Result Ordering

Results may arrive out of order (2 workers). Internal reorder buffer:
- Store result by index
- Process sequentially: while `resultBuffer[nextExpectedIndex]` exists, process it and increment

### 5. SessionController Changes

#### State Machine (Unchanged)

```
.idle -> .recording(elapsedSeconds:) -> .processing(provider:) -> [.polishing(preview:)] -> .injecting -> .idle
```

#### New runRecordingSession()

1. Request mic permission
2. `audioRecorder.startRecording()` -> `RecordingOutput(amplitude:, segments:)`
3. Start AppleSpeech preview (unchanged)
4. Create per-session `TranscriptionPipeline` + `StableTextAccumulator`
5. Launch streaming task: consume pipeline result stream, feed to accumulator
6. Bridge `pipeline.pendingDepth` to segmentFormer for pressure adaptation
7. Await amplitude stream (keeps recording alive)

#### New runProcessingSession()

1. `audioRecorder.stopRecording()` — triggers segmentFormer.finish(), no return value
2. `appleSpeechProvider.stopStreamingRecognition()` -> localPreviewText
3. Wait for streaming task (15s timeout, unchanged)
4. `accumulator.finalize()` -> finalText (near-instant, most text already stable)
5. Empty fallback to localPreviewText
6. ASRPostProcessor + optional LLM polish + inject

Key difference: no `finalData` path. All audio is covered by segments.

#### AudioRecorder Cleanup

Remove:
- `audioBuffer` (60s rolling PCM buffer)
- `segmentContinuation` / `recordedSegments` (legacy segment stream)
- `stopRecording()` return value — becomes `Void`
- `trimSilence` / `normalizeAndConvertToWAV` / `finalData` logic
- `dumpWAVData`

Modify:
- `RecordingOutput` simplified: old `segments: AsyncStream<Data>` (60s WAV chunks) replaced by `segments: AsyncStream<AudioSegment>` (VAD-driven segments). `amplitude: AsyncStream<Float>` unchanged.
- AudioSlicer replaced by StreamingSegmentFormer as internal component
- Expose `updateQueueDepth(_ depth: Int)` for pressure feedback

#### Component Ownership

```
SessionController (singleton, @MainActor)
  +-- audioRecorder: AudioRecorder
  |     +-- segmentFormer: StreamingSegmentFormer (internal, per-session)
  +-- speechRouter: SpeechRouter
  +-- appleSpeechProvider: AppleSpeechProvider (preview)
  +-- llmService: LLMService
  |
  |  [per-session, created on startRecording, nil on resetToIdle]
  +-- pipeline: TranscriptionPipeline?
  +-- accumulator: StableTextAccumulator?
```

### 6. Deleted Code

| File/Component | Reason |
|---|---|
| `AudioSlicer.swift` | Replaced by StreamingSegmentFormer |
| `ParallelTranscriber.swift` | Dead code, superseded by TranscriptionPipeline |
| `SegmentMerger.swift` | Dead code, approach absorbed into StableTextAccumulator |
| `SpeechRouter.previewProvider` | Dead code, never referenced |
| `AudioRecorder.audioBuffer` (60s rolling buffer) | Redundant, all audio covered by segment stream |
| `AudioRecorder.segmentContinuation` / `recordedSegments` | Legacy 60s WAV segment machinery, no consumer |
| `SessionController.collectedSlices` | Replaced by StableTextAccumulator |
| `SessionController.streamingResults` | Replaced by StableTextAccumulator |
| `SessionController.runStreamingTranscription()` | Replaced by TranscriptionPipeline |
| `SessionController.orderedTexts()` | Replaced by StableTextAccumulator |
| `PipelineOrchestrator` finalData transcription logic | Redundant, no finalData path |

### 7. Error Handling and Degradation

#### Degradation Levels

| Level | Condition | Segment Formation | Transcription |
|---|---|---|---|
| 0 (full) | Whisper + VAD healthy | VAD-driven | Whisper |
| 1 (VAD down) | Whisper healthy, /vad failing | Amplitude fallback | Whisper |
| 2 (Whisper down) | isServerReady == false | Amplitude fallback | AppleSpeech |
| 3 (all down) | Whisper + AppleSpeech fail | Amplitude fallback | Empty (use preview) |

#### VAD Fault Tolerance

- /vad timeout: 500ms
- After 3 consecutive failures: degrade to amplitude mode for remainder of session
- No retry — localhost failures indicate service problems, not transient network issues

#### Whisper Per-Segment Failure

- Whisper timeout (30s) or error: fall back to AppleSpeech (10s)
- AppleSpeech also fails: quality = .empty, StableTextAccumulator skips
- No retry on same audio

#### Edge Cases

| Scenario | Handling |
|---|---|
| Very short recording (<3s) | `finish()` emits unconditionally; Whisper/AppleSpeech processes normally |
| Pure silence recording | VAD reports no speech; 30s guard rail force-cuts; Whisper returns empty; error shown |
| Very long recording (>5min) | Natural pipeline operation; finalize() near-instant since most text already stable |
| Whisper crashes mid-session | In-flight requests timeout -> AppleSpeech fallback; VAD degrades to amplitude; Whisper auto-restarts, subsequent segments may recover |
| Out-of-order results | StableTextAccumulator reorder buffer ensures sequential processing |
| Overlap dedup failure | Edit distance threshold not met -> no trimming; ASRPostProcessor.stripRepetitions as second defense |
| Consecutive low-quality segments | Each skipped independently; no error propagation; stable prefix unaffected |

### 8. Logging

All critical decision points log via `AppLogger.log()`:

```
[SegmentFormer] VAD response: suggest_cut=true, trailing_silence=620ms, segment=12.3s -> cutting
[SegmentFormer] VAD degraded after 3 failures, falling back to amplitude mode
[SegmentFormer] Emitted segment #3: 14.2s, cutReason=vadSpeechEnd
[Pipeline] Segment #3: Whisper completed in 2.1s, quality=normal, text='...'
[Pipeline] Segment #4: Whisper failed, fallback to AppleSpeech, quality=fallback
[Pipeline] Worker adjustment: 1 -> 2 (queued=2, avgLatency=6.2s)
[Accumulator] Segment #3: overlap dedup removed 6 chars, boundary repaired
[Accumulator] Segment #4: skipped (quality=hallucination)
[Accumulator] Finalized: stable=156 chars, pending=23 chars -> total=179 chars
```

### 9. Configuration Changes

New fields in `Configuration` (with backward-compatible decoding):

```swift
// Streaming segment formation (replaces old slice* fields)
var segmentMinDuration: Double = 3.0
var segmentMaxDuration: Double = 30.0
var segmentOverlapDuration: Double = 1.0
var vadSilenceThresholdMs: Int = 800       // client-side fallback threshold
var vadRequestTimeoutMs: Int = 500
var vadMaxFailures: Int = 3                // before degrading to amplitude mode

// Amplitude fallback (used when VAD unavailable)
var amplitudeSilenceThresholdDB: Float = -40.0
var amplitudeSilenceDuration: Double = 0.5

// Experimental cross-segment context (V1: both false)
var experimentalContextEnabled: Bool = false
var experimentalConditionEnabled: Bool = false
```

Old `slice*` fields removed: `sliceMinDuration`, `sliceTargetLower`, `sliceTargetUpper`, `sliceMaxDuration`, `sliceSilenceThresholdDB`, `sliceSilenceDuration`, `sliceOverlapDuration`.
