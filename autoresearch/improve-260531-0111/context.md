# FlowType Current State (2026-05-31)

## Product
- macOS voice-input app for AI coding workflows
- Swift 6.2, SPM, macOS 15+, ~300MB MLX local ASR model
- Runs as .accessory app (no dock icon)

## Core Features Implemented
1. Voice Recording: 16kHz mono Float32, max 30min buffer cap
2. Local ASR: Qwen3-ASR MLX (4-bit, ~300MB) + Apple Speech fallback
3. LLM Polish: OpenAI-compatible API streaming with provider fallback
4. Text Injection: Keystroke simulation + clipboard paste with restoration
5. Global Hotkey: CGEventTap for trigger key
6. Floating UI: CapsuleView with real-time preview + audio visualizer
7. Settings Panel: Provider management with validation, microphone selection, duration slider
8. History Dashboard: Session list with search/filter, JSON/CSV export
9. Statistics: DailyStats aggregation (duration, word count, sessions, estimated time saved)
10. Smart Dictionary: Auto-detect corrections from raw vs polished text, grid tag UI
11. Onboarding: 3-step welcome flow
12. Style Packs: Predefined + custom polish modes

## Known Gaps
- No translation mode
- No microphone hot-plug handling
- No screen lock detection during recording
- No rate limiting on LLM requests
- Logs unencrypted with no rotation
- History stored in plaintext JSON
- No target app validation before injection
