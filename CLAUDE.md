# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

FlowType is a macOS voice-input app for AI coding workflows. It captures speech, transcribes via a local Qwen3-ASR MLX model, optionally refines with an LLM, and injects the result into the active text field. Swift 6.2, SPM, macOS 15+.

## Build & Run

```bash
swift build                    # Debug build
swift run FlowType             # Run from CLI (requires mlx.metallib next to binary)
./scripts/build-app.sh         # Build .app bundle → build/Flowtype.app
./scripts/build-dmg.sh         # Build distributable DMG
```

No test targets exist. The project has no linter configured. Verify changes with `swift build`.

**Metal shaders**: SPM cannot compile Metal shaders. The `mlx.metallib` file from the Python `mlx-metal` package is copied next to the binary at build time. For `swift run`, manually copy it: `cp ~/.cache/uv/archive-v0/*/mlx/lib/mlx.metallib .build/debug/`

## Logs

Diagnostic logs write to `~/Library/Logs/flowtype/diagnostic.log` via `AppLogger.log()`. Use this instead of `print()` — stdout is lost inside .app bundles. All log lines are prefixed with ISO8601 timestamps and component tags like `[SessionController#1]`, `[QwenASR]`.

## Architecture

### Session lifecycle (state machine)

`PipelineOrchestrator.swift` contains both `SessionState` and `SessionController` — the central orchestrator. This is the most critical file.

```
SessionState: .idle → .recording → .processing → [.polishing] → .injecting → .idle
                                                                    ↘ .error → .idle (auto-dismiss 3s)
```

`SessionController` is a `@MainActor ObservableObject` singleton. It owns the full pipeline: audio recording → batch Qwen3-ASR transcription → optional LLM polish → keyboard injection.

### Audio pipeline

1. **AudioRecorder** captures mic input at 16kHz mono Float32, accumulates raw samples
2. During recording, **AppleSpeechProvider** provides real-time preview text
3. On recording end, accumulated samples are sent to **QwenASRProvider.transcribe()** for batch ASR
4. If Qwen3-ASR fails or isn't loaded, AppleSpeech preview text is used as fallback
5. Result is post-processed by **ASRPostProcessor** (filler stripping, repetition detection, tech term correction, Chinese punctuation)

### Provider routing

- **SpeechRouter** holds two providers: `qwenProvider` (QwenASRProvider) and `fallbackProvider` (AppleSpeechProvider)
- Real-time preview during recording uses AppleSpeech streaming
- Final transcription uses Qwen3-ASR batch mode with AppleSpeech as fallback
- **QwenASRProvider** wraps `speech-swift` (Qwen3ASR MLX, ~300MB 4-bit model)

### Hotkey & UI

- **WindowManager** sets up a CGEventTap for the trigger key (default: Command)
- **OptionTapDetector** detects single/double taps with a 0.35s window
- Double-tap starts recording; single-tap ends with raw ASR; double-tap while recording ends with LLM polish
- **FloatingPanel** / **CapsuleView** show the recording UI at screen bottom

### Configuration

- `Configuration` struct (Codable) with backward-compatible decoding — new fields get defaults
- `ConfigurationStore` persists to UserDefaults with 0.5s debounce; API key stored in Keychain via `KeychainHelper`
- LLM config: provider/baseURL/apiKey/model for OpenAI-compatible API (default: SiliconFlow + DeepSeek-V3)

### Text injection

**KeyboardInjector** uses two strategies:
- Short single-line text: simulated keystrokes via CGEvent
- Multi-line or long text: clipboard paste (Cmd+V) with clipboard save/restore

## Key Constraints

- `SessionController` is `@MainActor` — all state mutations happen on the main thread
- The app runs as `.accessory` (no dock icon) — UI is status bar menu + floating panel only
- Audio format: 16kHz mono Float32 for Qwen3-ASR
- MLX requires Metal GPU — `mlx.metallib` must be colocated with the binary
- `speech-swift` types (Qwen3ASRModel, StreamingASR) are not Sendable — use `nonisolated(unsafe)` + DispatchQueue for thread safety
