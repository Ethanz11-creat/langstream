# Streaming ASR Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace FlowType's fixed-duration audio slicing with a VAD-driven adaptive segmentation pipeline that produces near-instant results after recording ends, with no text duplication or breaks.

**Architecture:** Three-stage streaming pipeline — StreamingSegmentFormer (VAD-driven cut points) → TranscriptionPipeline (ordered Whisper dispatch with quality assessment) → StableTextAccumulator (overlap dedup + stable/pending window). Python server gains Silero VAD `/vad` endpoint. Interaction model unchanged.

**Tech Stack:** Swift 6.2, macOS 14+, SPM (no external Swift deps). Python FastAPI + mlx-whisper + Silero VAD. No test target exists — verify all Swift changes with `swift build`.

**Spec:** `docs/superpowers/specs/2026-05-15-streaming-pipeline-design.md`

---

## File Map

### New Files
| File | Responsibility |
|---|---|
| `Sources/flowtype/Services/StreamingSegmentFormer.swift` | VAD-driven segment formation, amplitude fallback, pressure adaptation |
| `Sources/flowtype/Services/Speech/TranscriptionPipeline.swift` | Ordered Whisper dispatch, dynamic workers, quality assessment |
| `Sources/flowtype/Services/Speech/StableTextAccumulator.swift` | Overlap dedup, boundary repair, stable/pending window |
| `Sources/flowtype/Utilities/EditDistance.swift` | Levenshtein edit distance for overlap alignment |

### Modified Files
| File | Changes |
|---|---|
| `services/whisper_server/main.py` | Add Silero VAD, `/vad` endpoint, modify `/transcribe` response, update `/health` |
| `services/whisper_server/requirements.txt` | Add `silero-vad` dependency |
| `Sources/flowtype/Resources/services/whisper_server/main.py` | Sync bundled copy |
| `Sources/flowtype/Resources/services/whisper_server/requirements.txt` | Sync bundled copy |
| `Sources/flowtype/Core/Configuration.swift` | New segment/VAD/experiment config fields, remove old slice fields |
| `Sources/flowtype/Services/Speech/SpeechProvider.swift` | Add `transcribeWithDetails()` protocol method + `TranscriptionDetail` type |
| `Sources/flowtype/Services/Speech/MLXWhisperProvider.swift` | Implement `transcribeWithDetails()` with initial_prompt, segments parsing |
| `Sources/flowtype/Services/Speech/SpeechRouter.swift` | Remove dead `previewProvider` |
| `Sources/flowtype/Services/AudioRecorder.swift` | Replace AudioSlicer with StreamingSegmentFormer, remove 60s buffer |
| `Sources/flowtype/Core/PipelineOrchestrator.swift` | Rewire SessionController to use new pipeline components |

### Deleted Files
| File | Reason |
|---|---|
| `Sources/flowtype/Services/AudioSlicer.swift` | Replaced by StreamingSegmentFormer |
| `Sources/flowtype/Services/ParallelTranscriber.swift` | Dead code |
| `Sources/flowtype/Utilities/SegmentMerger.swift` | Dead code, logic absorbed into StableTextAccumulator |

---

## Task 1: Python Server — Silero VAD and /vad Endpoint

**Files:**
- Modify: `services/whisper_server/main.py`
- Modify: `services/whisper_server/requirements.txt`

- [ ] **Step 1: Add silero-vad dependency**

In `services/whisper_server/requirements.txt`, append:
```
silero-vad>=5.1
```

- [ ] **Step 2: Add VAD loading and /vad endpoint to main.py**

Add these imports at the top of `main.py` (after existing imports, before `# Global state`):

```python
import torch
```

Add VAD global state after existing globals (after line 30 `_args`):

```python
_vad_model = None
_vad_ready = False
_previous_speech_ratio: float = 0.0
```

Add VAD loading function after `_load_model_sync()` (after line 58):

```python
def _load_vad_sync():
    """Load Silero VAD model (CPU only, ~2MB, ~1s)."""
    global _vad_model, _vad_ready
    try:
        model, utils = torch.hub.load(
            repo_or_dir="snakers4/silero-vad",
            model="silero_vad",
            trust_repo=True,
        )
        _vad_model = model
        _vad_ready = True
        print("[vad] Silero VAD model loaded", flush=True)
    except Exception as e:
        print(f"[vad] Failed to load VAD model: {e}", flush=True, file=sys.stderr)
```

Modify the `startup()` function to also load VAD:

```python
@app.on_event("startup")
async def startup():
    loop = asyncio.get_event_loop()
    # Load VAD synchronously first (fast, ~1s)
    await loop.run_in_executor(None, _load_vad_sync)
    # Then start Whisper loading in background
    asyncio.create_task(_background_load_model())
```

Add the `/vad` endpoint after the `/health` endpoint:

```python
@app.post("/vad")
async def vad(file: UploadFile = File(...)):
    global _previous_speech_ratio

    if not _vad_ready or _vad_model is None:
        return JSONResponse(
            status_code=503,
            content={"error": "VAD model not loaded"},
        )

    try:
        content = await file.read()
        audio = _load_audio_from_bytes(content)
    except Exception as e:
        return JSONResponse(
            status_code=400,
            content={"error": f"Invalid audio: {e}"},
        )

    try:
        audio_tensor = torch.from_numpy(audio)
        # Get speech timestamps from Silero VAD
        speech_timestamps = _vad_model.get_speech_timestamps(
            audio_tensor, sampling_rate=16000,
            threshold=0.5,
            min_speech_duration_ms=100,
            min_silence_duration_ms=100,
        )

        sample_count = len(audio)
        duration_ms = sample_count / 16000 * 1000

        # Build speeches list
        speeches = []
        for ts in speech_timestamps:
            speeches.append({
                "start": round(ts["start"] / 16000, 3),
                "end": round(ts["end"] / 16000, 3),
            })

        # Compute has_speech and speech_ratio
        speech_samples = sum(ts["end"] - ts["start"] for ts in speech_timestamps)
        speech_ratio = round(speech_samples / sample_count, 3) if sample_count > 0 else 0.0
        has_speech = len(speech_timestamps) > 0

        # Compute trailing_silence_ms
        if speech_timestamps:
            last_speech_end = speech_timestamps[-1]["end"]
            trailing_silence_samples = sample_count - last_speech_end
            trailing_silence_ms = int(trailing_silence_samples / 16000 * 1000)
        else:
            trailing_silence_ms = int(duration_ms)

        # Compute suggest_cut
        suggest_cut = False
        if trailing_silence_ms >= 500 and speech_ratio < 0.3:
            suggest_cut = True
        elif _previous_speech_ratio > 0.8 and speech_ratio < 0.2:
            suggest_cut = True

        _previous_speech_ratio = speech_ratio

        return JSONResponse(content={
            "has_speech": has_speech,
            "speech_ratio": speech_ratio,
            "trailing_silence_ms": trailing_silence_ms,
            "suggest_cut": suggest_cut,
            "speeches": speeches,
        })
    except Exception as e:
        print(f"[vad] VAD inference failed: {e}", flush=True, file=sys.stderr)
        return JSONResponse(
            status_code=500,
            content={"error": str(e)},
        )
```

- [ ] **Step 3: Test /vad endpoint**

Start the server manually and test with curl:
```bash
cd services/whisper_server
.venv/bin/python main.py --model mlx-community/whisper-large-v3-turbo --language zh
```

In another terminal, create a test WAV and send it:
```bash
# Generate 1s of silence as 16kHz 16-bit mono WAV
python3 -c "
import wave, struct
with wave.open('/tmp/test_vad.wav','w') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
    f.writeframes(struct.pack('<'+'h'*16000, *([0]*16000)))
"
curl -X POST http://127.0.0.1:8765/vad -F "file=@/tmp/test_vad.wav"
```

Expected: `{"has_speech": false, "speech_ratio": 0.0, "trailing_silence_ms": 1000, "suggest_cut": false, ...}`

- [ ] **Step 4: Commit**

```bash
git add services/whisper_server/main.py services/whisper_server/requirements.txt
git commit -m "feat(server): add Silero VAD model and /vad endpoint

Load Silero VAD at startup, expose POST /vad that returns has_speech,
speech_ratio, trailing_silence_ms, suggest_cut, and raw speech spans.
Server tracks previous_speech_ratio for abrupt-stop detection."
```

---

## Task 2: Python Server — /transcribe Changes and /health Update

**Files:**
- Modify: `services/whisper_server/main.py`

- [ ] **Step 1: Update /health to include vad_ready**

Replace the `/health` endpoint:

```python
@app.get("/health")
async def health():
    stage = "model_loaded" if _model_loaded else "model_loading" if _model_loading else "error" if _model_error else "process_started"
    return JSONResponse(
        content={
            "status": "ok" if _model_loaded else "warming_up",
            "stage": stage,
            "model": _args.model,
            "language": _args.language,
            "progress": None,
            "error": _model_error,
            "vad_ready": _vad_ready,
        }
    )
```

- [ ] **Step 2: Modify /transcribe to accept initial_prompt and condition_on_previous**

Replace the `/transcribe` endpoint signature and implementation:

```python
@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    initial_prompt: Optional[str] = None,
    condition_on_previous: Optional[bool] = None,
):
    if not _model_loaded:
        return JSONResponse(
            status_code=503,
            content={"error": "Model not loaded yet", "stage": "model_loading"},
        )

    start_time = time.time()

    try:
        content = await file.read()
        audio = _load_audio_from_bytes(content)
    except Exception as e:
        print(f"[whisper] Failed to parse audio: {e}", flush=True, file=sys.stderr)
        return JSONResponse(
            status_code=400,
            content={"error": f"Invalid audio file: {e}"},
        )

    try:
        import mlx_whisper

        print(f"[whisper] Audio array: {len(audio)} samples, {len(audio)/16000:.2f}s", flush=True)

        # Build transcribe kwargs
        use_condition = bool(condition_on_previous) if condition_on_previous is not None else False
        prompt = initial_prompt if initial_prompt else None

        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(
            executor,
            lambda: mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=_args.model,
                language=_args.language if _args.language != "auto" else None,
                verbose=False,
                initial_prompt=prompt,
                condition_on_previous_text=use_condition,
                hallucination_silence_threshold=2.0,
            ),
        )

        # Extract text and segments
        if hasattr(result, 'get'):
            raw_text = result.get("text", "").strip()
            raw_segments = result.get("segments", [])
        else:
            raw_text = getattr(result, 'text', str(result)).strip()
            raw_segments = []

        detected_lang = None
        if hasattr(result, 'get'):
            detected_lang = result.get("language", None)

        # Build response segments with filtered/filter_reason
        response_segments = []
        good_texts = []
        for seg in raw_segments:
            if not hasattr(seg, 'get'):
                response_segments.append({
                    "text": str(seg),
                    "start": 0.0, "end": 0.0,
                    "no_speech_prob": 0.0, "compression_ratio": 0.0,
                    "filtered": False, "filter_reason": None,
                })
                good_texts.append(str(seg).strip())
                continue

            seg_text = seg.get("text", "")
            cr = seg.get("compression_ratio", 0)
            nsp = seg.get("no_speech_prob", 0)

            filtered = False
            filter_reason = None
            if cr > 2.4:
                filtered = True
                filter_reason = "compression_ratio_exceeded"
                print(f"[whisper] Filtered segment (cr={cr:.1f}): {seg_text[:40]}", flush=True)
            elif nsp > 0.6:
                filtered = True
                filter_reason = "no_speech_high"
                print(f"[whisper] Filtered segment (nsp={nsp:.2f}): {seg_text[:40]}", flush=True)

            response_segments.append({
                "text": seg_text,
                "start": round(seg.get("start", 0.0), 3),
                "end": round(seg.get("end", 0.0), 3),
                "no_speech_prob": round(nsp, 3),
                "compression_ratio": round(cr, 2),
                "filtered": filtered,
                "filter_reason": filter_reason,
            })

            if not filtered:
                good_texts.append(seg_text.strip())

        # Build final text from non-filtered segments
        if response_segments:
            text = " ".join(good_texts).strip()
            if len(good_texts) < len(response_segments):
                print(f"[whisper] Segment filter: {len(response_segments)} -> {len(good_texts)} segments", flush=True)
        else:
            text = raw_text

        # Server-side repetition stripping
        stripped = _strip_repetitions(text)
        if stripped != text:
            # Check if stripping was triggered — mark as repetition_detected
            # (already logged inside _strip_repetitions)
            text = stripped

        duration = time.time() - start_time
        print(f"[whisper] Transcribed in {duration:.2f}s: {text[:80]}...", flush=True)
        return JSONResponse(content={
            "text": text,
            "segments": response_segments,
            "language": detected_lang or _args.language,
        })
    except Exception as e:
        print(f"[whisper] Transcription failed: {e}", flush=True, file=sys.stderr)
        import traceback
        traceback.print_exc()
        return JSONResponse(
            status_code=500,
            content={"error": str(e)},
        )
```

- [ ] **Step 3: Sync bundled copies**

```bash
cp services/whisper_server/main.py Sources/flowtype/Resources/services/whisper_server/main.py
cp services/whisper_server/requirements.txt Sources/flowtype/Resources/services/whisper_server/requirements.txt
```

- [ ] **Step 4: Commit**

```bash
git add services/whisper_server/main.py services/whisper_server/requirements.txt \
  Sources/flowtype/Resources/services/whisper_server/main.py \
  Sources/flowtype/Resources/services/whisper_server/requirements.txt
git commit -m "feat(server): enhance /transcribe with segments, initial_prompt, condition_on_previous

/transcribe now returns segments array with filtered/filter_reason fields,
accepts optional initial_prompt and condition_on_previous parameters.
/health includes vad_ready field. Synced bundled copies."
```

---

## Task 3: Swift Configuration and Data Models

**Files:**
- Modify: `Sources/flowtype/Core/Configuration.swift`
- Modify: `Sources/flowtype/Services/Speech/SpeechProvider.swift`

- [ ] **Step 1: Update Configuration with new fields**

In `Configuration.swift`, replace the audio slicing parameters block (lines 77-84):

Old:
```swift
    // Audio slicing parameters (adaptive slicer — three-tier constraints)
    var sliceMinDuration: Double = 8.0
    var sliceTargetLower: Double = 10.0
    var sliceTargetUpper: Double = 18.0
    var sliceMaxDuration: Double = 20.0
    var sliceSilenceThresholdDB: Float = -40.0
    var sliceSilenceDuration: Double = 0.5
    var sliceOverlapDuration: Double = 1.0
```

New:
```swift
    // Streaming segment formation (VAD-driven adaptive pipeline)
    var segmentMinDuration: Double = 3.0
    var segmentMaxDuration: Double = 30.0
    var segmentOverlapDuration: Double = 1.0
    var vadSilenceThresholdMs: Int = 800
    var vadRequestTimeoutMs: Int = 500
    var vadMaxFailures: Int = 3

    // Amplitude fallback (when VAD unavailable)
    var amplitudeSilenceThresholdDB: Float = -40.0
    var amplitudeSilenceDuration: Double = 0.5

    // Experimental cross-segment context (V1: both false)
    var experimentalContextEnabled: Bool = false
    var experimentalConditionEnabled: Bool = false
```

In the `init(from decoder:)` method, replace the old slice field decoding with new field decoding. Remove:
```swift
        sliceMaxDuration = (try? c.decode(Double.self, forKey: .sliceMaxDuration)) ?? d.sliceMaxDuration
        sliceMinDuration = (try? c.decode(Double.self, forKey: .sliceMinDuration)) ?? d.sliceMinDuration
        sliceTargetLower = (try? c.decode(Double.self, forKey: .sliceTargetLower)) ?? d.sliceTargetLower
        sliceTargetUpper = (try? c.decode(Double.self, forKey: .sliceTargetUpper)) ?? d.sliceTargetUpper
        sliceSilenceThresholdDB = (try? c.decode(Float.self, forKey: .sliceSilenceThresholdDB)) ?? d.sliceSilenceThresholdDB
        sliceSilenceDuration = (try? c.decode(Double.self, forKey: .sliceSilenceDuration)) ?? d.sliceSilenceDuration
        sliceOverlapDuration = (try? c.decode(Double.self, forKey: .sliceOverlapDuration)) ?? d.sliceOverlapDuration
```

Add:
```swift
        segmentMinDuration = (try? c.decode(Double.self, forKey: .segmentMinDuration)) ?? d.segmentMinDuration
        segmentMaxDuration = (try? c.decode(Double.self, forKey: .segmentMaxDuration)) ?? d.segmentMaxDuration
        segmentOverlapDuration = (try? c.decode(Double.self, forKey: .segmentOverlapDuration)) ?? d.segmentOverlapDuration
        vadSilenceThresholdMs = (try? c.decode(Int.self, forKey: .vadSilenceThresholdMs)) ?? d.vadSilenceThresholdMs
        vadRequestTimeoutMs = (try? c.decode(Int.self, forKey: .vadRequestTimeoutMs)) ?? d.vadRequestTimeoutMs
        vadMaxFailures = (try? c.decode(Int.self, forKey: .vadMaxFailures)) ?? d.vadMaxFailures
        amplitudeSilenceThresholdDB = (try? c.decode(Float.self, forKey: .amplitudeSilenceThresholdDB)) ?? d.amplitudeSilenceThresholdDB
        amplitudeSilenceDuration = (try? c.decode(Double.self, forKey: .amplitudeSilenceDuration)) ?? d.amplitudeSilenceDuration
        experimentalContextEnabled = (try? c.decode(Bool.self, forKey: .experimentalContextEnabled)) ?? d.experimentalContextEnabled
        experimentalConditionEnabled = (try? c.decode(Bool.self, forKey: .experimentalConditionEnabled)) ?? d.experimentalConditionEnabled
```

- [ ] **Step 2: Add data models and enhanced SpeechProvider protocol**

Replace the full contents of `Sources/flowtype/Services/Speech/SpeechProvider.swift`:

```swift
import Foundation

// MARK: - Speech Provider Protocol

protocol SpeechProvider: Sendable {
    var name: String { get }
    func transcribe(audioData: Data, timeout: TimeInterval) async throws -> String
    func transcribeWithDetails(
        audioData: Data,
        initialPrompt: String?,
        conditionOnPrevious: Bool,
        timeout: TimeInterval
    ) async throws -> TranscriptionDetail
}

extension SpeechProvider {
    func transcribeWithDetails(
        audioData: Data,
        initialPrompt: String?,
        conditionOnPrevious: Bool,
        timeout: TimeInterval
    ) async throws -> TranscriptionDetail {
        let text = try await transcribe(audioData: audioData, timeout: timeout)
        return TranscriptionDetail(text: text, segments: nil, language: nil)
    }
}

// MARK: - Provider Types

enum SpeechProviderError: Error {
    case transcriptionFailed(String)
    case networkError(Error)
    case notAvailable
    case permissionDenied
}

struct TranscriptionDetail: Sendable {
    let text: String
    let segments: [WhisperSegment]?
    let language: String?
}

struct WhisperSegment: Sendable, Codable {
    let text: String
    let start: Double
    let end: Double
    let noSpeechProb: Double
    let compressionRatio: Double
    let filtered: Bool
    let filterReason: String?

    enum CodingKeys: String, CodingKey {
        case text, start, end, filtered
        case noSpeechProb = "no_speech_prob"
        case compressionRatio = "compression_ratio"
        case filterReason = "filter_reason"
    }
}

// MARK: - Segment Pipeline Types

struct AudioSegment: Sendable {
    let index: Int
    let audioData: Data
    let duration: Double
    let overlapDuration: Double
    let cutReason: CutReason
}

enum CutReason: Sendable {
    case vadSpeechEnd
    case maxDurationReached
    case sessionEnded
}

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

struct TextSnapshot: Sendable {
    let stable: String
    let pending: String
    let fullText: String
}
```

- [ ] **Step 3: Verify build**

```bash
swift build 2>&1 | tail -5
```

Expected: Build errors related to removed `slice*` config fields in AudioSlicer.swift and AudioRecorder.swift. This is expected — those files will be replaced/modified in later tasks. The new types themselves compile.

Note: Until Task 9 (integration), the project will not compile cleanly because old code still references removed config fields. This is acceptable — each new component is self-contained and the integration task will resolve all references.

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/Core/Configuration.swift Sources/flowtype/Services/Speech/SpeechProvider.swift
git commit -m "feat: add streaming pipeline data models and configuration

New Configuration fields for VAD-driven segmentation (replaces old slice*
fields). New types: AudioSegment, CutReason, SegmentResult, SegmentQuality,
WhisperSegment, TextSnapshot, TranscriptionDetail. Enhanced SpeechProvider
protocol with transcribeWithDetails() method."
```

---

## Task 4: Edit Distance Utility

**Files:**
- Create: `Sources/flowtype/Utilities/EditDistance.swift`

- [ ] **Step 1: Implement edit distance and overlap alignment**

Create `Sources/flowtype/Utilities/EditDistance.swift`:

```swift
import Foundation

enum EditDistance {
    /// Compute Levenshtein edit distance between two strings (character-level).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,         // deletion
                    curr[j - 1] + 1,     // insertion
                    prev[j - 1] + cost   // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    /// Find the best overlap alignment between the suffix of `anchor` and the
    /// prefix of `candidate`.
    ///
    /// Searches for a suffix of `anchor` (lengths 5, 8, 12, 16, 20, ...) that
    /// matches a prefix of `candidate` within an edit distance ratio of
    /// `maxRatio` (default 0.3). Returns the number of characters to trim from
    /// the front of `candidate` to remove the overlap, or 0 if no overlap found.
    ///
    /// - Parameters:
    ///   - anchor: The stable text suffix to match against.
    ///   - candidate: The new segment text whose prefix may overlap with anchor.
    ///   - searchWindow: Maximum characters from anchor tail and candidate head
    ///     to consider.
    ///   - maxRatio: Maximum `editDistance / matchLength` to accept as overlap.
    /// - Returns: Number of characters to trim from `candidate`'s front.
    static func findOverlapTrim(
        anchor: String,
        candidate: String,
        searchWindow: Int,
        maxRatio: Double = 0.3
    ) -> Int {
        guard !anchor.isEmpty, !candidate.isEmpty, searchWindow >= 5 else { return 0 }

        let anchorChars = Array(anchor)
        let candidateChars = Array(candidate)
        let anchorLen = anchorChars.count
        let candidateLen = candidateChars.count

        let maxAnchorSuffix = min(anchorLen, searchWindow)
        let maxCandidatePrefix = min(candidateLen, searchWindow)

        var bestTrim = 0
        var bestScore = Double.infinity

        // Try suffix lengths: 5, 8, 12, 16, 20, ...
        var suffixLen = 5
        while suffixLen <= maxAnchorSuffix {
            let suffix = String(anchorChars[(anchorLen - suffixLen)...])

            // Slide over candidate prefixes of similar length (+/- 30%)
            let minPrefixLen = max(3, Int(Double(suffixLen) * 0.7))
            let maxPrefixLen = min(maxCandidatePrefix, Int(Double(suffixLen) * 1.3))

            for prefixLen in minPrefixLen...maxPrefixLen {
                let prefix = String(candidateChars[0..<prefixLen])
                let dist = distance(suffix, prefix)
                let ratio = Double(dist) / Double(max(suffixLen, prefixLen))

                if ratio < maxRatio && ratio < bestScore {
                    bestScore = ratio
                    bestTrim = prefixLen
                }
            }

            if suffixLen < 8 { suffixLen = 8 }
            else { suffixLen += 4 }
        }

        return bestTrim
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/flowtype/Utilities/EditDistance.swift
git commit -m "feat: add edit distance utility for overlap alignment

Levenshtein distance + findOverlapTrim() that searches for the best
suffix-prefix alignment between anchor and candidate text. Used by
StableTextAccumulator for cross-segment deduplication."
```

---

## Task 5: StableTextAccumulator

**Files:**
- Create: `Sources/flowtype/Services/Speech/StableTextAccumulator.swift`

- [ ] **Step 1: Implement StableTextAccumulator**

Create `Sources/flowtype/Services/Speech/StableTextAccumulator.swift`:

```swift
import Foundation

/// Accumulates transcription results into a growing text stream with
/// stable (frozen) and pending (revisable) regions.
///
/// Results are processed in index order via an internal reorder buffer.
/// Low-quality segments (empty, hallucination) are discarded. Overlap
/// between adjacent segments is deduplicated using edit-distance alignment.
final class StableTextAccumulator: @unchecked Sendable {
    // MARK: - Public State

    private(set) var stablePrefix: String = ""
    private(set) var lastStableQuality: SegmentQuality = .normal

    // MARK: - Internal State

    private var pendingTail: String = ""
    private var pendingQuality: SegmentQuality = .normal
    private var nextExpectedIndex: Int = 1
    private var resultBuffer: [Int: SegmentResult] = [:]
    private var lastSnapshot: TextSnapshot = TextSnapshot(stable: "", pending: "", fullText: "")

    // MARK: - Configuration

    /// Estimated Chinese speech rate in characters per second.
    private let charsPerSecond: Double = 4.0

    // MARK: - Public API

    /// Accept a transcription result. Results may arrive out of order;
    /// they are buffered and processed sequentially by index.
    func accept(_ result: SegmentResult) -> TextSnapshot {
        resultBuffer[result.index] = result

        while let next = resultBuffer[nextExpectedIndex] {
            resultBuffer.removeValue(forKey: nextExpectedIndex)
            nextExpectedIndex += 1
            processInOrder(next)
        }

        lastSnapshot = TextSnapshot(
            stable: stablePrefix,
            pending: pendingTail,
            fullText: stablePrefix + pendingTail
        )
        return lastSnapshot
    }

    /// Force-freeze all pending content. Called when recording ends.
    func finalize() -> String {
        if !pendingTail.isEmpty {
            stablePrefix += pendingTail
            lastStableQuality = pendingQuality
            pendingTail = ""
        }
        return stablePrefix
    }

    // MARK: - Sequential Processing

    private func processInOrder(_ result: SegmentResult) {
        // 1. Anomaly filter
        switch result.quality {
        case .empty:
            AppLogger.log("[Accumulator] Segment #\(result.index): skipped (quality=empty)")
            return
        case .hallucination:
            AppLogger.log("[Accumulator] Segment #\(result.index): skipped (quality=hallucination)")
            return
        case .normal, .fallback:
            break
        }

        // 2. Freeze previous pending
        if !pendingTail.isEmpty {
            stablePrefix += pendingTail
            lastStableQuality = pendingQuality
        }

        // 3. Overlap dedup
        var newText = result.text.trimmingCharacters(in: .whitespaces)
        if !stablePrefix.isEmpty && result.overlapDuration > 0 {
            newText = deduplicateOverlap(newText: newText, overlapDuration: result.overlapDuration)
        }

        // 4. Boundary repair
        newText = repairBoundary(newText: newText)

        // 5. Update pending
        pendingTail = newText
        pendingQuality = result.quality

        AppLogger.log("[Accumulator] Segment #\(result.index): accepted, stable=\(stablePrefix.count) chars, pending=\(pendingTail.count) chars")
    }

    // MARK: - Overlap Deduplication

    private func deduplicateOverlap(newText: String, overlapDuration: Double) -> String {
        let estimatedOverlapChars = Int(overlapDuration * charsPerSecond)
        let searchWindow = max(10, estimatedOverlapChars * 2)

        let anchorLen = min(stablePrefix.count, searchWindow)
        guard anchorLen >= 5 else { return newText }

        let anchor = String(stablePrefix.suffix(anchorLen))

        let trimCount = EditDistance.findOverlapTrim(
            anchor: anchor,
            candidate: newText,
            searchWindow: searchWindow
        )

        if trimCount > 0 && trimCount < newText.count {
            let trimmed = String(newText.dropFirst(trimCount))
            AppLogger.log("[Accumulator] Overlap dedup: removed \(trimCount) chars from segment prefix")
            return trimmed
        }

        return newText
    }

    // MARK: - Boundary Repair

    private func repairBoundary(newText: String) -> String {
        guard !stablePrefix.isEmpty, !newText.isEmpty else { return newText }

        let stableLast = stablePrefix.last!
        let newFirst = newText.first!

        // Deduplicate overlapping punctuation at boundary
        let punctuation: Set<Character> = ["，", "。", "！", "？", "；", "、", ",", ".", "!", "?", ";"]
        if punctuation.contains(stableLast) && stableLast == newFirst {
            return String(newText.dropFirst())
        }

        // Chinese text: no space separator needed
        let isChinese = stableLast.isChineseCharacter || newFirst.isChineseCharacter
        if isChinese {
            return newText
        }

        // English/mixed: ensure single space between words
        if !stableLast.isWhitespace && !newFirst.isWhitespace && !punctuation.contains(newFirst) {
            return " " + newText
        }

        return newText
    }
}

// MARK: - Character Extension

private extension Character {
    var isChineseCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)    // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(value)    // CJK Extension A
            || (0x20000...0x2A6DF).contains(value)  // CJK Extension B
            || (0x3000...0x303F).contains(value)    // CJK Symbols and Punctuation
            || (0xFF00...0xFFEF).contains(value)    // Fullwidth Forms
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/flowtype/Services/Speech/StableTextAccumulator.swift
git commit -m "feat: add StableTextAccumulator with overlap dedup and stable/pending window

Processes SegmentResults in index order, deduplicates overlap regions via
edit-distance alignment, repairs boundary punctuation, filters anomalous
segments. Maintains frozen stablePrefix and revisable pendingTail."
```

---

## Task 6: StreamingSegmentFormer

**Files:**
- Create: `Sources/flowtype/Services/StreamingSegmentFormer.swift`

- [ ] **Step 1: Implement StreamingSegmentFormer**

Create `Sources/flowtype/Services/StreamingSegmentFormer.swift`:

```swift
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
        guard isCollecting else { return }
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let frames = Array(UnsafeBufferPointer(start: data, count: count))
        appendFrames(frames)
    }

    func finish() {
        guard isCollecting else { return }
        isCollecting = false

        // Emit whatever remains — user's last words, never discard
        if !segmentBuffer.isEmpty {
            emitSegment(cutReason: .sessionEnded)
        }

        segmentContinuation?.finish()
        segmentContinuation = nil
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
            defer { self.vadRequestInFlight = false }

            do {
                let response = try await self.postVad(wavData: wavData, timeoutMs: timeoutMs)
                self.vadFailureCount = 0
                self.handleVadResponse(response)
            } catch {
                self.vadFailureCount += 1
                if self.vadFailureCount >= self.vadMaxFailures && !self.vadDegraded {
                    self.vadDegraded = true
                    AppLogger.log("[SegmentFormer] VAD degraded after \(self.vadMaxFailures) failures, falling back to amplitude mode")
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
```

- [ ] **Step 2: Commit**

```bash
git add Sources/flowtype/Services/StreamingSegmentFormer.swift
git commit -m "feat: add StreamingSegmentFormer with VAD-driven adaptive segmentation

VAD-first segment formation with amplitude fallback. Sends ~1s audio
chunks to /vad, cuts at speech boundaries. Guard rails: min 3s, max 30s.
Pressure-adaptive: queue backlog lowers silence threshold. Degrades to
amplitude mode after 3 consecutive VAD failures."
```

---

## Task 7: MLXWhisperProvider Changes

**Files:**
- Modify: `Sources/flowtype/Services/Speech/MLXWhisperProvider.swift`

- [ ] **Step 1: Implement transcribeWithDetails()**

Replace the full contents of `MLXWhisperProvider.swift`:

```swift
import Foundation

final class MLXWhisperProvider: SpeechProvider {
    let name: String = "MLXWhisper"

    func transcribe(audioData: Data, timeout: TimeInterval = 300) async throws -> String {
        let detail = try await transcribeWithDetails(
            audioData: audioData,
            initialPrompt: nil,
            conditionOnPrevious: false,
            timeout: timeout
        )
        return detail.text
    }

    func transcribeWithDetails(
        audioData: Data,
        initialPrompt: String?,
        conditionOnPrevious: Bool,
        timeout: TimeInterval
    ) async throws -> TranscriptionDetail {
        let port = WhisperServerManager.shared.port ?? 8765
        guard let url = URL(string: "http://127.0.0.1:\(port)/transcribe") else {
            throw SpeechProviderError.transcriptionFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // File part
        body.append(string: "--\(boundary)\r\n")
        body.append(string: "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.append(string: "Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append(string: "\r\n")

        // initial_prompt part (optional)
        if let prompt = initialPrompt, !prompt.isEmpty {
            body.append(string: "--\(boundary)\r\n")
            body.append(string: "Content-Disposition: form-data; name=\"initial_prompt\"\r\n\r\n")
            body.append(string: prompt)
            body.append(string: "\r\n")
        }

        // condition_on_previous part (only if true)
        if conditionOnPrevious {
            body.append(string: "--\(boundary)\r\n")
            body.append(string: "Content-Disposition: form-data; name=\"condition_on_previous\"\r\n\r\n")
            body.append(string: "true")
            body.append(string: "\r\n")
        }

        body.append(string: "--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechProviderError.networkError(SpeechProviderError.transcriptionFailed("Invalid response"))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[MLXWhisper] HTTP error \(httpResponse.statusCode): \(errorText)")
            throw SpeechProviderError.transcriptionFailed("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        struct FullResponse: Codable {
            let text: String
            let segments: [WhisperSegment]?
            let language: String?
        }

        do {
            let result = try JSONDecoder().decode(FullResponse.self, from: data)
            return TranscriptionDetail(
                text: result.text,
                segments: result.segments,
                language: result.language
            )
        } catch {
            // Fallback: try parsing as legacy {"text": "..."} response
            struct LegacyResponse: Codable { let text: String }
            if let legacy = try? JSONDecoder().decode(LegacyResponse.self, from: data) {
                return TranscriptionDetail(text: legacy.text, segments: nil, language: nil)
            }
            throw SpeechProviderError.transcriptionFailed("Failed to parse response")
        }
    }
}

private extension Data {
    mutating func append(string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/flowtype/Services/Speech/MLXWhisperProvider.swift
git commit -m "feat: MLXWhisperProvider supports initial_prompt, segments, and condition_on_previous

transcribeWithDetails() sends optional initial_prompt and condition_on_previous
to /transcribe, parses full response including WhisperSegment array with
filtered/filter_reason. Falls back to legacy response format for compatibility."
```

---

## Task 8: TranscriptionPipeline

**Files:**
- Create: `Sources/flowtype/Services/Speech/TranscriptionPipeline.swift`

- [ ] **Step 1: Implement TranscriptionPipeline**

Create `Sources/flowtype/Services/Speech/TranscriptionPipeline.swift`:

```swift
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
```

- [ ] **Step 2: Commit**

```bash
git add Sources/flowtype/Services/Speech/TranscriptionPipeline.swift
git commit -m "feat: add TranscriptionPipeline with dynamic workers and quality assessment

Ordered dispatch via sliding-window TaskGroup. Starts with 1 worker, scales
to 2 on backlog. Whisper primary with AppleSpeech fallback per segment.
Quality assessment: normal/empty/hallucination/fallback. Experimental
cross-segment context passing (off by default)."
```

---

## Task 9: Integration — AudioRecorder, SpeechRouter, SessionController, Dead Code

This is the integration task. It modifies multiple files atomically to swap the old pipeline for the new one.

**Files:**
- Modify: `Sources/flowtype/Services/AudioRecorder.swift`
- Modify: `Sources/flowtype/Services/Speech/SpeechRouter.swift`
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Delete: `Sources/flowtype/Services/AudioSlicer.swift`
- Delete: `Sources/flowtype/Services/ParallelTranscriber.swift`
- Delete: `Sources/flowtype/Utilities/SegmentMerger.swift`

- [ ] **Step 1: Clean up SpeechRouter — remove previewProvider**

Replace `Sources/flowtype/Services/Speech/SpeechRouter.swift`:

```swift
import Foundation
import AVFoundation

final class SpeechRouter: @unchecked Sendable {
    let primaryProvider: MLXWhisperProvider
    let fallbackProvider: AppleSpeechProvider

    init() {
        self.primaryProvider = MLXWhisperProvider()
        self.fallbackProvider = AppleSpeechProvider()
    }
}
```

- [ ] **Step 2: Rewrite AudioRecorder — replace AudioSlicer, remove 60s buffer**

Replace the full contents of `Sources/flowtype/Services/AudioRecorder.swift`:

```swift
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
    /// Real-time audio segment stream for the transcription pipeline.
    let segments: AsyncStream<AudioSegment>
}

final class AudioRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private nonisolated(unsafe) var amplitudeContinuation: AsyncStream<Float>.Continuation?

    // Real-time segment former (replaces AudioSlicer)
    private var segmentFormer: StreamingSegmentFormer?

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

    /// Update the segment former's view of recognition queue depth.
    func updateQueueDepth(_ depth: Int) {
        segmentFormer?.pendingQueueDepth = depth
    }

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

        // Start segment former
        let former = StreamingSegmentFormer()
        let config = Configuration.shared
        former.minDuration = config.segmentMinDuration
        former.maxDuration = config.segmentMaxDuration
        former.overlapDuration = config.segmentOverlapDuration
        former.vadSilenceThresholdMs = config.vadSilenceThresholdMs
        former.vadRequestTimeoutMs = config.vadRequestTimeoutMs
        former.vadMaxFailures = config.vadMaxFailures
        former.amplitudeSilenceThresholdDB = config.amplitudeSilenceThresholdDB
        former.amplitudeSilenceDuration = config.amplitudeSilenceDuration
        self.segmentFormer = former
        let segmentStream = former.startForming()

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

                // Feed to segment former
                self.segmentFormer?.appendBuffer(convertedBuffer)

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

        return RecordingOutput(amplitude: amplitudeStream, segments: segmentStream)
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

        // Finish segment former (emits final segment + closes stream)
        segmentFormer?.finish()
        segmentFormer = nil

        // Stop engine
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        stateLock.withLock {
            _isStopping = false
        }
    }
}
```

- [ ] **Step 3: Rewrite SessionController in PipelineOrchestrator.swift**

Replace the full contents of `Sources/flowtype/Core/PipelineOrchestrator.swift`:

```swift
import Foundation
import AppKit
import SwiftUI

// MARK: - Session State

enum SessionState: Equatable {
    case idle
    case recording(elapsedSeconds: Int)
    case processing(provider: String)
    case polishing(preview: String)
    case injecting
    case error(String)
}

// MARK: - Session Controller

@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    private let audioRecorder = AudioRecorder()
    private let speechRouter = SpeechRouter()
    private let llmService = LLMService()
    private let appleSpeechProvider = AppleSpeechProvider()

    // MARK: - Published State

    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var amplitude: Float = 0.0
    @Published private(set) var previewText: String = ""

    // MARK: - Session Identity

    private var sessionID: UInt64 = 0
    private var activeSessionID: UInt64 = 0
    private var useLLMPolish: Bool = false

    // MARK: - Tasks

    private var recordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var previewStreamTask: Task<Void, Never>?

    // MARK: - Pipeline Components (per-session)

    private var pipeline: TranscriptionPipeline?
    private var accumulator: StableTextAccumulator?

    // MARK: - Recording Timer

    private var recordingTimer = CancellableTimer()
    private var elapsedSeconds: Int = 0

    // MARK: - Preview Debounce

    private var previewDebounceTask: Task<Void, Never>?
    private var pendingPreviewText: String = ""

    // MARK: - Injection Guard

    private var hasInjected: Bool = false

    // MARK: - Error Dismiss

    private var errorDismissTask: Task<Void, Never>?

    // MARK: - Diagnostics

    private var recordingStartTime: Date?

    // MARK: - Computed

    var isRecording: Bool {
        if case .recording = sessionState { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = sessionState { return true }
        return false
    }

    // MARK: - Public API

    func startRecording() {
        let newID = nextSessionID()
        AppLogger.log("[SessionController#\(newID)] startRecording requested")

        switch sessionState {
        case .idle, .error:
            break
        default:
            AppLogger.log("[SessionController#\(newID)] REJECTED: state=\(sessionState)")
            return
        }

        errorDismissTask?.cancel()
        errorDismissTask = nil

        activeSessionID = newID
        useLLMPolish = false
        hasInjected = false
        recordingStartTime = Date()

        // Create per-session pipeline components
        pipeline = TranscriptionPipeline()
        accumulator = StableTextAccumulator()
        pipeline?.accumulator = accumulator

        previewText = ""
        amplitude = 0.0
        pendingPreviewText = ""
        previewDebounceTask?.cancel()
        previewDebounceTask = nil

        sessionState = .recording(elapsedSeconds: 0)
        startRecordingTimer()
        WindowManager.shared.showWindow()

        recordingTask = Task { [weak self] in
            guard let self else { return }
            await self.runRecordingSession(id: newID)
        }
    }

    func endRecording(withPolish: Bool) {
        AppLogger.log("[SessionController#\(activeSessionID)] endRecording called, withPolish=\(withPolish)")

        guard isRecording else {
            AppLogger.log("[SessionController#\(activeSessionID)] endRecording: not recording, ignoring")
            return
        }

        useLLMPolish = withPolish
        stopRecordingTimer()

        recordingTask?.cancel()
        recordingTask = nil

        sessionState = .processing(provider: WhisperServerManager.shared.isServerReady ? "本地识别" : "本地识别(兜底)")

        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runProcessingSession(id: self.activeSessionID)
        }
    }

    func cancel() {
        AppLogger.log("[SessionController#\(activeSessionID)] cancel called, state=\(sessionState)")

        recordingTask?.cancel()
        recordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        previewStreamTask?.cancel()
        previewStreamTask = nil
        pipeline?.cancel()

        audioRecorder.onAudioBuffer = nil
        audioRecorder.onRecordingFrozen = nil
        audioRecorder.stopRecording()
        _ = appleSpeechProvider.stopStreamingRecognition()

        resetToIdle()
        AppLogger.log("[SessionController] Cancelled — session reset to idle")
    }

    // MARK: - Recording Phase

    private func runRecordingSession(id: UInt64) async {
        AppLogger.log("[SessionController#\(id)] Recording phase started")
        let recordingStart = Date()

        defer {
            let elapsed = Date().timeIntervalSince(recordingStart)
            AppLogger.log("[SessionController#\(id)] Recording phase ended (duration: \(String(format: "%.1f", elapsed))s)")
        }

        do {
            let granted = await audioRecorder.requestPermission()
            guard granted else {
                let status = audioRecorder.authorizationStatus()
                let msg = micPermissionMessage(status: status)
                showError(msg)
                AppLogger.log("[SessionController#\(id)] Mic permission denied (status=\(status))")
                return
            }
            try checkCancellation(id: id)

            let output = try await audioRecorder.startRecording()
            AppLogger.log("[SessionController#\(id)] AudioRecorder started")

            // AppleSpeech preview
            audioRecorder.onAudioBuffer = { [weak self] buffer in
                self?.appleSpeechProvider.appendAudioBuffer(buffer)
            }
            let previewStream = await appleSpeechProvider.startStreamingRecognition()
            AppLogger.log("[SessionController#\(id)] AppleSpeech preview started")

            self.previewStreamTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await text in previewStream {
                    guard self.activeSessionID == id else { break }
                    self.updatePreviewText(text)
                }
            }

            // Streaming transcription pipeline
            guard let pipeline = self.pipeline, let accumulator = self.accumulator else { return }

            let resultStream = pipeline.start(
                segments: output.segments,
                provider: speechRouter.primaryProvider,
                fallback: speechRouter.fallbackProvider
            )

            self.streamingTask = Task { [weak self] in
                guard let self else { return }
                for await result in resultStream {
                    guard self.activeSessionID == id else { break }
                    let _ = accumulator.accept(result)
                    // Bridge queue depth to segment former for pressure adaptation
                    self.audioRecorder.updateQueueDepth(pipeline.pendingDepth)
                }
            }

            AppLogger.log("[SessionController#\(id)] Streaming pipeline started")
            for await amp in output.amplitude {
                try checkCancellation(id: id)
                if abs(self.amplitude - amp) > 0.005 {
                    self.amplitude = amp
                }
            }
            AppLogger.log("[SessionController#\(id)] Audio amplitude stream ended")

        } catch is CancellationError {
            AppLogger.log("[SessionController#\(id)] Recording cancelled")
        } catch {
            AppLogger.log("[SessionController#\(id)] Recording failed: \(error)")
            showError("录音启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Processing Phase

    private func runProcessingSession(id: UInt64) async {
        AppLogger.log("[SessionController#\(id)] Processing phase started")
        let processingStartTime = Date()

        defer {
            let totalProcessingTime = Date().timeIntervalSince(processingStartTime)
            if let recStart = recordingStartTime {
                let totalSessionTime = Date().timeIntervalSince(recStart)
                AppLogger.log("[SessionController#\(id)] ===== TIMING SUMMARY =====")
                AppLogger.log("[SessionController#\(id)] Total session time: \(String(format: "%.1f", totalSessionTime))s")
                AppLogger.log("[SessionController#\(id)] Processing time: \(String(format: "%.1f", totalProcessingTime))s")
            }
            AppLogger.log("[SessionController#\(id)] Processing phase ended (total: \(String(format: "%.1f", totalProcessingTime))s)")
        }

        // Stop recording — triggers segmentFormer.finish() which emits final segment
        let stopAudioStart = Date()
        audioRecorder.stopRecording()
        audioRecorder.onAudioBuffer = nil
        audioRecorder.onRecordingFrozen = nil
        AppLogger.log("[SessionController#\(id)] AudioRecorder stopped in \(String(format: "%.2f", Date().timeIntervalSince(stopAudioStart)))s")

        let localPreviewText = appleSpeechProvider.stopStreamingRecognition()
        AppLogger.log("[SessionController#\(id)] AppleSpeech final preview: '\(localPreviewText.prefix(80))'")

        // Wait for streaming pipeline to finish
        let waitStreamStart = Date()
        let streamCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.streamingTask?.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 15_000_000_000); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        if !streamCompleted {
            AppLogger.log("[SessionController#\(id)] Streaming pipeline timed out after 15s")
            streamingTask?.cancel()
            pipeline?.cancel()
        }
        streamingTask = nil
        AppLogger.log("[SessionController#\(id)] Waited for streaming in \(String(format: "%.2f", Date().timeIntervalSince(waitStreamStart)))s")

        // Finalize accumulator — freeze pending tail
        let mergeStart = Date()
        var finalASRText = accumulator?.finalize() ?? ""
        AppLogger.log("[SessionController#\(id)] Accumulator finalized: \(finalASRText.count) chars (merge took \(String(format: "%.2f", Date().timeIntervalSince(mergeStart)))s)")

        if finalASRText.isEmpty, !localPreviewText.isEmpty {
            AppLogger.log("[SessionController#\(id)] Using AppleSpeech preview as fallback")
            finalASRText = localPreviewText
        }

        let postProcessStart = Date()
        let processedText = ASRPostProcessor.process(finalASRText)
        let textToUse = processedText.isEmpty ? finalASRText.trimmingCharacters(in: .whitespaces) : processedText
        AppLogger.log("[SessionController#\(id)] Post-processed in \(String(format: "%.2f", Date().timeIntervalSince(postProcessStart)))s: '\(textToUse.prefix(200))'")

        guard !textToUse.isEmpty else {
            AppLogger.log("[SessionController#\(id)] Empty text, aborting")
            showError("语音识别结果为空")
            return
        }

        if useLLMPolish {
            let polishStart = Date()
            sessionState = .polishing(preview: "")

            var polishedText: String? = nil
            do {
                let stream = await llmService.polishText(textToUse)
                var accumulated = ""
                for try await chunk in stream {
                    guard activeSessionID == id else { throw CancellationError() }
                    accumulated += chunk
                    sessionState = .polishing(preview: accumulated)
                }
                if !accumulated.isEmpty && accumulated != textToUse {
                    polishedText = accumulated
                    AppLogger.log("[SessionController#\(id)] LLM polished in \(String(format: "%.1f", Date().timeIntervalSince(polishStart)))s: '\(accumulated.prefix(100))'")
                } else {
                    AppLogger.log("[SessionController#\(id)] LLM returned empty/same, using raw")
                }
            } catch is CancellationError {
                AppLogger.log("[SessionController#\(id)] LLM polish cancelled")
                resetToIdle()
                return
            } catch {
                AppLogger.log("[SessionController#\(id)] LLM polish failed: \(error)")
            }

            let finalText = polishedText ?? textToUse
            await injectText(finalText, sessionID: id)
        } else {
            AppLogger.log("[SessionController#\(id)] Using raw ASR text (single-tap end)")
            await injectText(textToUse, sessionID: id)
        }
    }

    // MARK: - Injection Phase

    private func injectText(_ text: String, sessionID: UInt64) async {
        guard !hasInjected else {
            AppLogger.log("[SessionController#\(sessionID)] Duplicate injection blocked")
            return
        }
        hasInjected = true
        AppLogger.log("[SessionController#\(sessionID)] Injection phase started")
        let injectStart = Date()

        sessionState = .injecting
        WindowManager.shared.hide()

        try? await Task.sleep(nanoseconds: 100_000_000)

        guard activeSessionID == sessionID else {
            AppLogger.log("[SessionController#\(sessionID)] Session changed before injection, aborting")
            return
        }

        do {
            try await KeyboardInjector.insertText(text)
            AppLogger.log("[SessionController#\(sessionID)] Text injected successfully in \(String(format: "%.2f", Date().timeIntervalSince(injectStart)))s")
        } catch {
            AppLogger.log("[SessionController#\(sessionID)] Injection failed: \(error)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showError("已复制到剪贴板")
            return
        }

        resetToIdle()
        if let recStart = recordingStartTime {
            let totalSessionTime = Date().timeIntervalSince(recStart)
            AppLogger.log("[SessionController#\(sessionID)] ===== SESSION COMPLETE =====")
            AppLogger.log("[SessionController#\(sessionID)] Total session time: \(String(format: "%.1f", totalSessionTime))s")
        }
    }

    // MARK: - Timer

    private func startRecordingTimer() {
        elapsedSeconds = 0
        recordingTimer.schedule(withTimeInterval: 1.0, repeats: true) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.elapsedSeconds += 1
                self.sessionState = .recording(elapsedSeconds: self.elapsedSeconds)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer.cancel()
        elapsedSeconds = 0
    }

    // MARK: - Preview Debounce

    private func updatePreviewText(_ text: String) {
        if case .recording = sessionState, text.isEmpty, !previewText.isEmpty {
            return
        }
        guard text != pendingPreviewText else { return }
        pendingPreviewText = text

        if previewText.isEmpty, !text.isEmpty {
            previewText = text
            return
        }

        previewDebounceTask?.cancel()
        previewDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch { return }
            guard let self else { return }
            self.previewText = self.pendingPreviewText
            self.previewDebounceTask = nil
        }
    }

    // MARK: - Error

    private func showError(_ message: String) {
        let errorSessionID = activeSessionID
        sessionState = .error(message)
        WindowManager.shared.showWindow()
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch { return }
            guard let self else { return }
            if case .error = self.sessionState, self.activeSessionID == errorSessionID {
                self.resetToIdle()
            }
        }
    }

    // MARK: - Reset

    private func resetToIdle() {
        sessionState = .idle
        activeSessionID = 0
        useLLMPolish = false
        hasInjected = false
        recordingStartTime = nil
        previewText = ""
        amplitude = 0.0
        pendingPreviewText = ""
        previewDebounceTask?.cancel()
        previewDebounceTask = nil
        previewStreamTask?.cancel()
        previewStreamTask = nil
        errorDismissTask?.cancel()
        errorDismissTask = nil
        pipeline?.cancel()
        pipeline = nil
        accumulator = nil
        stopRecordingTimer()
        WindowManager.shared.hide()
    }

    // MARK: - Helpers

    private func nextSessionID() -> UInt64 {
        sessionID += 1
        return sessionID
    }

    private func checkCancellation(id: UInt64) throws {
        guard activeSessionID == id else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func micPermissionMessage(status: Int) -> String {
        if status == 0 {
            return "麦克风权限未响应。请先退出 Flowtype，重新打开后再试一次。"
        } else if status == 1 {
            return "麦克风权限已拒绝。请前往「系统设置 → 隐私与安全性 → 麦克风」，找到 Flowtype 并开启。"
        } else {
            return "请在系统设置中允许麦克风访问"
        }
    }
}

// MARK: - SessionState UI Properties

extension SessionState {

    var iconName: String {
        switch self {
        case .idle:       return "mic"
        case .recording:  return "waveform"
        case .processing: return "brain.head.profile"
        case .polishing:  return "sparkles"
        case .injecting:  return "keyboard"
        case .error:      return "exclamationmark.triangle"
        }
    }

    var statusColor: Color {
        switch self {
        case .idle:       return Color.white.opacity(0.5)
        case .recording:  return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .processing: return .blue
        case .polishing:  return Color(red: 0.8, green: 0.4, blue: 0.9)
        case .injecting:  return .green
        case .error:      return .red
        }
    }

    var statusTitle: String {
        switch self {
        case .idle:                      return "准备就绪"
        case .recording:                 return "Listening..."
        case .processing(let provider):  return "\(provider)..."
        case .polishing:                 return "润色中..."
        case .injecting:                 return "输入中..."
        case .error:                     return "出错了"
        }
    }

    var isRecordingIndicator: Bool {
        if case .recording = self { return true }
        return false
    }

    var showSpinner: Bool {
        switch self {
        case .processing, .polishing: return true
        default: return false
        }
    }

    var showPanel: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}
```

- [ ] **Step 4: Delete old files**

```bash
rm Sources/flowtype/Services/AudioSlicer.swift
rm Sources/flowtype/Services/ParallelTranscriber.swift
rm Sources/flowtype/Utilities/SegmentMerger.swift
```

- [ ] **Step 5: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: `Build complete!` with no errors (existing warnings are OK).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: integrate streaming pipeline, remove legacy slicing architecture

Replace AudioSlicer with StreamingSegmentFormer in AudioRecorder.
Rewire SessionController to use TranscriptionPipeline + StableTextAccumulator.
Remove 60s rolling buffer, finalData path, and dead code (AudioSlicer,
ParallelTranscriber, SegmentMerger, SpeechRouter.previewProvider).
SessionController is now a pure state machine + pipeline orchestrator."
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Python /vad endpoint with has_speech, speech_ratio, trailing_silence_ms, suggest_cut → Task 1
- [x] Python /transcribe with initial_prompt, condition_on_previous, segments with filtered/filter_reason → Task 2
- [x] Python /health with vad_ready → Task 2
- [x] Configuration changes (new segment/VAD/experiment fields, remove old slice fields) → Task 3
- [x] AudioSegment, CutReason, SegmentResult, SegmentQuality, WhisperSegment, TextSnapshot types → Task 3
- [x] SpeechProvider.transcribeWithDetails() + TranscriptionDetail → Task 3
- [x] Edit distance utility → Task 4
- [x] StableTextAccumulator (reorder buffer, overlap dedup, boundary repair, stable/pending) → Task 5
- [x] StreamingSegmentFormer (VAD-driven, amplitude fallback, pressure adaptation, guard rails) → Task 6
- [x] MLXWhisperProvider enhanced with initial_prompt, segments parsing → Task 7
- [x] TranscriptionPipeline (dynamic workers, quality assessment, context passing) → Task 8
- [x] AudioRecorder cleanup (remove 60s buffer, use SegmentFormer, stopRecording returns void) → Task 9
- [x] SpeechRouter cleanup (remove previewProvider) → Task 9
- [x] SessionController rewire (pipeline + accumulator, no finalData path) → Task 9
- [x] Delete AudioSlicer, ParallelTranscriber, SegmentMerger → Task 9
- [x] Degradation levels (VAD down → amplitude fallback, Whisper down → AppleSpeech) → Tasks 6, 8
- [x] Logging at all decision points → Tasks 5, 6, 8

**Placeholder scan:** No TBD, TODO, or vague steps found.

**Type consistency:**
- `AudioSegment` defined in Task 3, used consistently in Tasks 6, 8, 9
- `SegmentResult` defined in Task 3, used in Tasks 5, 8, 9
- `SegmentQuality` defined in Task 3, used in Tasks 5, 8
- `CutReason` defined in Task 3, used in Tasks 6, 8
- `WhisperSegment` defined in Task 3, used in Tasks 7, 8
- `TranscriptionDetail` defined in Task 3, used in Tasks 7, 8
- `TextSnapshot` defined in Task 3, used in Task 5
- `StableTextAccumulator` created in Task 5, referenced in Tasks 8, 9 — method names match (`accept`, `finalize`, `stablePrefix`, `lastStableQuality`)
- `StreamingSegmentFormer` created in Task 6, used in Task 9 — method names match (`startForming`, `appendBuffer`, `finish`, `pendingQueueDepth`)
- `TranscriptionPipeline` created in Task 8, used in Task 9 — method names match (`start`, `cancel`, `pendingDepth`, `accumulator`)
- `EditDistance.findOverlapTrim` defined in Task 4, called in Task 5 — parameters match
