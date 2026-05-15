# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

FlowType is a macOS voice-input app for AI coding workflows. It captures speech, transcribes via a local MLX Whisper server, optionally refines with an LLM, and injects the result into the active text field. Swift 6.2, SPM, macOS 14+, no external Swift dependencies.

## Build & Run

```bash
swift build                    # Debug build
swift run FlowType             # Run from CLI (stdout visible)
./scripts/build-app.sh         # Build .app bundle → build/Flowtype.app
./scripts/build-dmg.sh         # Build distributable DMG
```

No test targets exist. The project has no linter configured. Verify changes with `swift build`.

## Whisper Server (Python)

The local ASR server lives at `services/whisper_server/main.py` (FastAPI + uvicorn). It's also bundled as a resource at `Sources/flowtype/Resources/services/whisper_server/` for the .app bundle.

```bash
# Setup (one-time)
./scripts/setup_whisper.sh

# Manual run (for debugging)
cd services/whisper_server
.venv/bin/python main.py --model mlx-community/whisper-large-v3-turbo --language zh
```

The Swift app manages the server lifecycle automatically via `WhisperServerManager` — launches on app start, monitors health, auto-restarts up to 3 times.

## Logs

Diagnostic logs write to `~/Library/Logs/flowtype/diagnostic.log` via `AppLogger.log()`. Use this instead of `print()` — stdout is lost inside .app bundles. All log lines are prefixed with ISO8601 timestamps and component tags like `[SessionController#1]`, `[WhisperServer-stderr]`, `[AudioSlicer]`.

## Architecture

### Session lifecycle (state machine)

`PipelineOrchestrator.swift` contains both `SessionState` and `SessionController` — the central orchestrator. This is the most critical file.

```
SessionState: .idle → .recording → .processing → [.polishing] → .injecting → .idle
                                                                    ↘ .error → .idle (auto-dismiss 3s)
```

`SessionController` is a `@MainActor ObservableObject` singleton. It owns the full pipeline: audio recording → slice-based streaming ASR → ordered merge → optional LLM polish → keyboard injection.

### Audio pipeline

1. **AudioRecorder** captures mic input, feeds PCM frames to **AudioSlicer**
2. **AudioSlicer** emits `AudioSlice` via `AsyncStream` — silence-priority cutting with max-duration fallback (configurable: 5-12s slices, 1s overlap)
3. **SessionController.runStreamingTranscription()** processes slices with 2 parallel workers: tries MLXWhisper first, falls back to AppleSpeech per slice
4. Results are merged in index order, post-processed by **ASRPostProcessor** (filler stripping, repetition detection, tech term correction, Chinese punctuation)

### Provider routing

- **SpeechRouter** holds three providers: `primaryProvider` (MLXWhisperProvider), `fallbackProvider` (AppleSpeechProvider), `previewProvider` (AppleSpeechProvider)
- Real-time preview during recording uses AppleSpeech streaming
- Final transcription uses Whisper with AppleSpeech fallback per slice
- **MLXWhisperProvider** sends multipart POST to `http://127.0.0.1:{port}/transcribe`

### Hotkey & UI

- **WindowManager** sets up a CGEventTap for the trigger key (default: Command)
- **OptionTapDetector** detects single/double taps with a 0.35s window
- Double-tap starts recording; single-tap ends with raw ASR; double-tap while recording ends with LLM polish
- **FloatingPanel** / **CapsuleView** show the recording UI at screen bottom

### Configuration

- `Configuration` struct (Codable) with backward-compatible decoding — new fields get defaults
- `ConfigurationStore` persists to UserDefaults with 0.5s debounce; API key stored in Keychain via `KeychainHelper`
- Whisper server reads config from `Configuration.shared` at launch (model, language)
- LLM config: provider/baseURL/apiKey/model for OpenAI-compatible API (default: SiliconFlow + DeepSeek-V3)

### Text injection

**KeyboardInjector** uses two strategies:
- Short single-line text: simulated keystrokes via CGEvent
- Multi-line or long text: clipboard paste (Cmd+V) with clipboard save/restore

## Key Constraints

- The Whisper Python server uses `ThreadPoolExecutor(max_workers=1)` — only one transcription runs at a time server-side, even though Swift dispatches 2 parallel workers
- `SessionController` is `@MainActor` — all state mutations happen on the main thread
- The app runs as `.accessory` (no dock icon) — UI is status bar menu + floating panel only
- Audio format: 16kHz mono 16-bit PCM WAV for all ASR providers
