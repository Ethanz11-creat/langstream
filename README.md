# Flowtype

**English** | [简体中文](README.zh.md)

> Voice-to-prompt input for AI coding

Flowtype is a macOS voice input app built for AI coding workflows.

It helps developers turn spoken, messy, and highly verbal thoughts into clearer prompts for coding agents like Codex, Claude Code, and similar tools.

## Why Flowtype

- **Voice is faster than typing** — describe ideas at natural speaking speed
- **Spoken thoughts flow better** — they're more continuous and expressive than typed text
- **Raw transcription isn't enough** — speech is too conversational for AI coding tools
- **Flowtype bridges the gap** — structured, coding-oriented text refinement with one keypress

## Core interaction

| Action | Result |
|--------|--------|
| Double press `Command` | Start voice recording (capsule window appears) |
| Single press `Command` (while recording) | Stop and output raw spoken text |
| Double press `Command` (while recording) | Stop and output LLM-polished structured prompt |

## Use cases

- Describe a feature idea hands-free while reviewing code
- Turn rough implementation thoughts into a usable coding prompt
- Quickly draft UI, workflow, and product instructions for AI coding tools
- Brainstorm architecture decisions out loud, then paste the cleaned result

## How it works

1. **Record** — Double press `Command` to start voice capture (a capsule window appears at the bottom)
2. **Preview** — Apple on-device speech recognition shows real-time transcription as you speak
3. **Transcribe** — When recording stops, audio is sent to the local MLX Whisper server for high-quality transcription; if the server is unavailable, it falls back to AppleSpeech
4. **Refine** — LLM cleans up filler words, fixes recognition errors, and structures the prompt (double-press end only)
5. **Inject** — Result is typed directly into your active text field

## Architecture

```
Sources/flowtype/
├── App/
│   ├── FlowTypeApp.swift              # Entry point, accessory-only app
│   └── StatusBarController.swift      # Status bar icon & menu
├── Core/
│   ├── AppState.swift                 # Global state management
│   ├── Configuration.swift            # Configuration model
│   ├── ConfigurationStore.swift       # UserDefaults persistence with debounce
│   ├── EnvMigration.swift             # One-time .env → GUI migration
│   ├── PipelineOrchestrator.swift     # End-to-end audio → text pipeline
│   └── AsyncRefiner.swift             # ASR + LLM refinement
├── Services/
│   ├── AudioRecorder.swift            # macOS audio capture (segmented)
│   ├── KeyboardInjector.swift         # Text insertion via clipboard / HID
│   ├── LLMService.swift               # SiliconFlow SSE streaming client
│   ├── WhisperServerManager.swift     # Python server lifecycle (launch / port / health)
│   ├── WhisperSetupChecker.swift      # Environment readiness checker
│   └── Speech/
│       ├── SpeechRouter.swift         # Provider routing (MLXWhisper → AppleSpeech fallback)
│       ├── SpeechProvider.swift       # Protocol
│       ├── ASRPostProcessor.swift     # Filler stripping, term correction
│       ├── ASRResultScorer.swift      # 7-dimension quality scoring
│       ├── AppleSpeechProvider.swift  # On-device speech recognition (preview + fallback)
│       └── MLXWhisperProvider.swift   # Local MLX Whisper HTTP client
├── Settings/
│   ├── SettingsView.swift             # SwiftUI settings panel
│   └── SettingsWindowController.swift # Settings window host
├── UI/
│   └── AudioVisualizer.swift          # Recording visual feedback
├── Utilities/
│   ├── AudioFormatConverter.swift     # PCM → WAV, normalization, silence trim
│   ├── SegmentMerger.swift            # Deduplicated segment merging
│   ├── DotEnv.swift                   # .env file parser (legacy)
│   └── PermissionHelper.swift         # Accessibility permission check & guide
├── Resources/
│   ├── tech_terms.json                # Tech term corrections
│   └── filler_words.json              # Filler word dictionary
```

## Model Choice

Flowtype uses [MLX Whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper), a port of OpenAI's Whisper optimized for Apple Silicon via the [MLX framework](https://ml-explore.github.io/mlx/).

### Why MLX

[MLX](https://github.com/ml-explore/mlx) is Apple's machine learning framework built specifically for Apple Silicon. Key advantages for a macOS voice app:

- **Unified memory** — model weights live in system RAM, no VRAM copying overhead
- **Native Metal backend** — compute shaders run directly on the GPU / Neural Engine
- **Low latency** — no network round-trip; transcription happens on-device
- **Privacy** — audio never leaves your machine

### Why `whisper-large-v3-turbo`

The default model is [`mlx-community/whisper-large-v3-turbo`](https://huggingface.co/mlx-community/whisper-large-v3-turbo), a distilled variant of Whisper Large v3 optimized for MLX:

| Model | Size | Speed | Quality | Best For |
|-------|------|-------|---------|----------|
| `whisper-large-v3-turbo` | ~1.6 GB | Fast | Excellent | Default — balanced speed & accuracy |

- **Distilled** — trained from Large v3 with fewer decoder layers, achieving near-Large quality at ~2× the speed
- **MLX-optimized** — weights are pre-converted to MLX format (`.safetensors`), loading and running natively on Apple Silicon
- **Multilingual** — supports automatic language detection (中文 / English / others) via a single model
- **Local-only** — runs entirely offline after the one-time download

> **Coming soon**: support for lighter variants such as `whisper-tiny` for users who prefer minimal memory footprint over absolute accuracy.

## Requirements

- macOS 14+
- Swift 6.2+
- Apple Silicon (M1 or later) — for local MLX Whisper inference
- [uv](https://docs.astral.sh/uv/getting-started/installation/) — Python package manager
- [SiliconFlow API key](https://cloud.siliconflow.cn/account/ak) — for LLM text refinement only (ASR is fully local)

## Setup

### 1. Install uv (Python manager)

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### 2. Install local ASR environment

```bash
./scripts/setup_whisper.sh
```

This creates a Python virtual environment, installs dependencies, and downloads the Whisper model (~1.6 GB). The model is cached globally at `~/.cache/huggingface/hub/`.

### 3. Build & run

```bash
# Build
swift build

# Run
swift run FlowType
```

Or build the `.app` bundle:

```bash
./scripts/build-app.sh
open build/Flowtype.app
```

## Configuration

All settings are managed through the **Settings GUI** (click the status bar icon → Settings, or press `Cmd + ,`):

| Section | Settings |
|----------|---------|
| **Local ASR** | Model status, one-click install, language (Auto / 中文 / English) |
| **LLM** | Provider, Base URL, API Key, Model ID |
| **Trigger Key** | Fn / Control / Option / Command |

Settings are persisted to `UserDefaults` automatically. An existing `.env` file will be **migrated once** on first launch, after which the GUI settings take precedence.

### ASR fallback behavior

| Scenario | Behavior |
|----------|----------|
| Local model ready | MLX Whisper serves final transcription |
| Local model not installed / loading / crashed | AppleSpeech provides final transcription |
| Real-time preview | AppleSpeech streams live transcription during recording |

## ASR Evaluation

The `tools/` directory includes an evaluation framework for benchmarking ASR providers:

```bash
cd tools
cp .env ../.env  # ensure API key is available
python evaluate_asr.py --output-dir eval_output/
```

See [`tools/eval_data/README.md`](tools/eval_data/README.md) for dataset details.

## License

MIT
