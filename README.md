# Flowtype

**English** | [简体中文](README.zh.md)

> Voice-to-prompt input for AI coding

Flowtype is a macOS voice input app built for AI coding workflows.

It helps developers turn spoken, messy, and highly verbal thoughts into clearer prompts for coding agents like Codex, Claude Code, and similar tools.

## About this branch (`flowtype-local`)

This branch contains the **Qwen3-ASR + Modular Pipeline** architecture. Key differences from `main`:

- **ASR Engine**: Uses [`speech-swift`](https://github.com/soniqo/speech-swift) (Qwen3-ASR via MLX, ~300MB 4-bit) directly in Swift — no Python server
- **Pipeline Architecture**: Modular stage-based pipeline (Recording → ASR → PostProcess → Polish → Injection) with `SessionContext` state propagation
- **No Python dependency**: No `uv`, no Whisper Python server, no `setup_whisper.sh`
- **macOS 15+ required** (Swift 6.2)

> **What's missing from GitHub**: `mlx.metallib` (119MB Metal shader library) exceeds GitHub's file size limit. See [Continuing development on another machine](#continuing-development-on-another-machine) below.

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
3. **Transcribe** — When recording stops, audio is sent to the local Qwen3-ASR model for high-quality transcription; if the model is unavailable, it falls back to AppleSpeech
4. **Refine** — LLM cleans up filler words, fixes recognition errors, and structures the prompt (double-press end only)
5. **Inject** — Result is typed directly into your active text field

## Architecture

```
Sources/flowtype/
├── App/
│   ├── FlowTypeApp.swift              # Entry point, accessory-only app
│   └── StatusBarController.swift      # Status bar icon & menu
├── Core/
│   ├── Configuration.swift            # Configuration model
│   ├── ConfigurationStore.swift       # UserDefaults persistence with debounce
│   ├── PipelineOrchestrator.swift     # SessionController + SessionState state machine
│   ├── Pipeline/                      # Modular pipeline stage architecture
│   │   ├── SessionContext.swift       # Immutable context passed through stages
│   │   ├── PipelineStage.swift        # Stage protocol
│   │   ├── PipelineRegistry.swift     # Stage registration
│   │   ├── Observers/                 # Real-time state observation
│   │   └── Stages/                    # Individual pipeline stages
│   │       ├── RecordingStage.swift   # Audio capture
│   │       ├── ASRStage.swift         # Qwen3-ASR / AppleSpeech transcription
│   │       ├── PostProcessStage.swift # Filler stripping, term correction
│   │       ├── PolishStage.swift      # LLM refinement
│   │       └── InjectionStage.swift   # Keyboard text injection
│   ├── DailyStats.swift               # Usage statistics aggregation
│   ├── DictationHistory.swift         # History persistence
│   └── Dictionary.swift               # User vocabulary & auto-detected corrections
├── Services/
│   ├── AudioRecorder.swift            # macOS audio capture (16kHz mono Float32)
│   ├── AudioDevice.swift              # Input device enumeration & selection
│   ├── KeyboardInjector.swift         # Text insertion via clipboard / CGEvent keystrokes
│   ├── LLMService.swift               # OpenAI-compatible SSE streaming client
│   ├── WindowManager.swift            # CGEventTap hotkey setup
│   └── Speech/
│       ├── SpeechRouter.swift         # Provider routing (QwenASR → AppleSpeech fallback)
│       ├── SpeechProvider.swift       # Protocol
│       ├── QwenASRProvider.swift      # Local Qwen3-ASR MLX model (~300MB 4-bit)
│       ├── QwenModelState.swift       # Model load state management
│       ├── AppleSpeechProvider.swift  # On-device speech recognition (preview + fallback)
│       └── ASRPostProcessor.swift     # Filler stripping, repetition detection, term correction
├── Settings/
│   ├── SettingsView.swift             # SwiftUI settings panel
│   ├── SettingsWindowController.swift # Settings window host
│   ├── MainWindowView.swift           # Settings tab container
│   ├── OverviewPage.swift             # Daily stats dashboard
│   ├── HistoryPage.swift              # Dictation history with export
│   ├── VocabPage.swift                # Personal dictionary management
│   └── StylePage.swift                # UI style customization
├── Features/
│   └── Onboarding/
│       └── OnboardingPipeline.swift   # First-launch guide
├── UI/
│   ├── CapsuleView.swift              # Recording capsule window
│   ├── FloatingPanel.swift            # Panel window host
│   └── AudioVisualizer.swift          # Recording visual feedback
├── Utilities/
│   ├── AppLogger.swift                # File-based diagnostic logging
│   ├── AudioFormatConverter.swift     # PCM format conversion
│   ├── KeychainHelper.swift           # Secure API key storage
│   ├── PermissionHelper.swift         # Accessibility permission check & guide
│   ├── SoundFeedback.swift            # Audio feedback for recording events
│   └── UnsafeCell.swift               # Thread-safe value wrapper
└── Resources/
    ├── tech_terms.json                # Tech term corrections
    ├── filler_words.json              # Filler word dictionary
    ├── AppIcon.icns                   # App icon
    └── status_bar_icon*.png           # Status bar icons
```

## Model Choice

Flowtype uses [Qwen3-ASR](https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit) via the [`speech-swift`](https://github.com/soniqo/speech-swift) package — a Qwen3-based ASR model optimized for Apple Silicon via MLX.

### Why Qwen3-ASR

- **Small footprint** — ~300MB 4-bit quantized model, much lighter than Whisper Large v3 (~1.6GB)
- **Fast loading** — loads directly in Swift via MLX, no Python server overhead
- **Native MLX** — runs on Apple Silicon GPU/Neural Engine through Metal
- **Quality** — strong performance on Chinese-English code-switching and technical vocabulary

### Why MLX

[MLX](https://github.com/ml-explore/mlx) is Apple's machine learning framework built specifically for Apple Silicon:

- **Unified memory** — model weights live in system RAM, no VRAM copying overhead
- **Native Metal backend** — compute shaders run directly on the GPU / Neural Engine
- **Low latency** — no network round-trip; transcription happens on-device
- **Privacy** — audio never leaves your machine

## Requirements

- macOS 15+
- Swift 6.2+
- Apple Silicon (M1 or later) — for local MLX inference
- [SiliconFlow API key](https://cloud.siliconflow.cn/account/ak) — for LLM text refinement only (ASR is fully local)

## Setup

### 1. Build

```bash
swift build
```

### 2. Provide `mlx.metallib` (required for Qwen3-ASR GPU inference)

SPM cannot compile Metal shaders. The `mlx.metallib` file must be copied next to the binary from a Python `mlx` installation:

```bash
# Install Python mlx (if not already installed)
pip install mlx

# Find and copy the metallib
python3 -c "import mlx, pathlib; print(pathlib.Path(mlx.__file__).parent / 'lib' / 'mlx.metallib')"
# Then copy the printed path to:
cp <path-to-mlx.metallib> .build/debug/
```

Common locations:
- `~/.cache/uv/archive-v0/*/mlx/lib/mlx.metallib` (if using `uv`)
- `~/.cache/pip/*/mlx/lib/mlx.metallib` (if using `pip`)

> ⚠️ **Without `mlx.metallib`, Qwen3-ASR will crash at runtime.** This file is intentionally excluded from Git (119MB > GitHub's 100MB limit).

### 3. Run

```bash
swift run FlowType
```

Or build the `.app` bundle (which automatically copies `mlx.metallib` if found):

```bash
./scripts/build-app.sh
open build/Flowtype.app
```

## Configuration

All settings are managed through the **Settings GUI** (click the status bar icon → Settings, or press `Cmd + ,`):

| Section | Settings |
|----------|---------|
| **Local ASR** | Model load status, language (Auto / 中文 / English) |
| **LLM** | Provider, Base URL, API Key, Model ID |
| **Trigger Key** | Fn / Control / Option / Command |
| **History** | Dictation history with JSON/CSV export |
| **Dictionary** | Personal vocabulary & auto-detected corrections |

Settings are persisted to `UserDefaults` automatically. An existing `.env` file will be **migrated once** on first launch, after which the GUI settings take precedence.

### ASR fallback behavior

| Scenario | Behavior |
|----------|----------|
| Qwen3-ASR model loaded | Qwen3-ASR serves final transcription |
| Qwen3-ASR not loaded / crashed | AppleSpeech provides final transcription |
| Real-time preview | AppleSpeech streams live transcription during recording |

## Continuing development on another machine

When cloning this repo on a new Mac, here's what's **not included** and what you need to do:

1. **Clone & build**
   ```bash
   git clone -b flowtype-local https://github.com/Ethanz11-creat/Flowtype.git
   cd Flowtype
   swift build
   ```

2. **Install Python `mlx`** to get `mlx.metallib`:
   ```bash
   pip install mlx
   ```

3. **Copy `mlx.metallib`** next to the debug binary:
   ```bash
   python3 -c "import mlx, pathlib; print(pathlib.Path(mlx.__file__).parent / 'lib' / 'mlx.metallib')"
   cp <path-from-above> .build/debug/
   ```

4. **Run**
   ```bash
   swift run FlowType
   ```

The `.gitignore` excludes: `build/`, `FlowType.app/`, `FlowType` binary, `*.dmg`, and `.build/` (SPM build directory). Only source code and resources are tracked in git.

## License

MIT
