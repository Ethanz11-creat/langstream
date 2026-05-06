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
3. **Transcribe** — Audio is sent to ASR providers (parallel routing with scoring) when recording stops
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
│   └── AsyncRefiner.swift             # Parallel ASR + LLM refinement
├── Services/
│   ├── AudioRecorder.swift            # macOS audio capture (segmented)
│   ├── KeyboardInjector.swift         # Text insertion via clipboard / HID
│   ├── LLMService.swift               # SiliconFlow SSE streaming client
│   └── Speech/
│       ├── SpeechRouter.swift         # Multi-provider routing & scoring
│       ├── SpeechProvider.swift       # Protocol
│       ├── ASRPostProcessor.swift     # Filler stripping, term correction
│       ├── ASRResultScorer.swift      # 7-dimension quality scoring
│       ├── AppleSpeechProvider.swift  # On-device speech recognition (preview + fallback)
│       ├── TeleSpeechProvider.swift
│       ├── SenseVoiceProvider.swift
│       └── SiliconFlowSpeechProvider.swift
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

## Requirements

- macOS 14+
- Swift 6.2+
- [SiliconFlow API key](https://cloud.siliconflow.cn/account/ak) (for LLM refinement and ASR)

## Setup

```bash
# 1. Clone
git clone <repo-url>
cd Flowtype

# 2. Build
swift build

# 3. Run
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
| **ASR Primary** | Provider, Base URL, API Key, Model ID |
| **ASR Fallback** | Provider, Base URL, API Key, Model ID |
| **LLM** | Provider, Base URL, API Key, Model ID |
| **Trigger Key** | Fn / Control / Option / Command |
| **ASR Strategy** | Parallel (run both, pick best) or Fallback (primary first) |

Settings are persisted to `UserDefaults` automatically. An existing `.env` file will be **migrated once** on first launch, after which the GUI settings take precedence.

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
