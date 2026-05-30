# FlowType Improvement PRD

**Date:** 2026-05-31
**Methodology:** $autoresearch improve — 4 parallel research agents (Competitive, UX, Technical, AI)
**Scope:** Product improvements, feature expansion, technical debt, competitive positioning

---

## Executive Summary

Four research dimensions analyzed 36+ improvement opportunities. This PRD synthesizes the top recommendations into a prioritized roadmap.

### Key Insight
**FlowType occupies a unique niche:** the only macOS app combining local ASR privacy + streaming LLM polish + system-wide injection + developer-native UX (history, stats, dictionary). No competitor matches this exact combination. The battleground is not accuracy — it's workflow integration, pricing model, and AI-agent interoperability.

---

## Phase 1: Quick Wins (1-2 weeks)

### P1.1: Interactive Onboarding Demo
**Source:** UX Research #1 | **Impact:** High | **Effort:** Small
- Add a Step 4 "Try It Out" to onboarding with a fake text field
- User double-taps trigger, speaks, sees result injected into demo field
- Reduces first-activation friction from "guess and hope" to "learn by doing"

### P1.2: Audio Feedback Cues
**Source:** UX Research #4 | **Impact:** Medium | **Effort:** Small
- 80ms ascending tone on recording start, descending on stop
- Respects macOS "Play user interface sound effects" setting
- Helps users confirm trigger detection without looking at screen

### P1.3: Retryable Error Cards
**Source:** UX Research #3 | **Impact:** High | **Effort:** Small
- Replace 3-second auto-dismiss error with actionable card:
  - Error title + detail (e.g., "SiliconFlow: connection timeout")
  - Buttons: [Retry Polish] [Copy Raw] [Dismiss]
- Reduces user frustration when LLM fails

### P1.4: Settings Search
**Source:** UX Research #5 | **Impact:** High | **Effort:** Medium
- Search bar at top of Settings that filters all sections
- Search "mic" → highlights microphone picker
- Search "key" → highlights API key field

### P1.5: Lifetime Pricing Tier
**Source:** Competitive #5 | **Impact:** High | **Effort:** Low
- Add $99-149 one-time purchase alongside subscription
- Competitors (SuperWhisper $249, MacWhisper $69) all offer lifetime
- Users in this category strongly prefer ownership

### P1.6: Analytics Dashboard Expansion
**Source:** AI #12 | **Impact:** Medium | **Effort:** Small
- Add to OverviewPage: polish mode distribution pie chart, weekly trend line, accuracy proxy (raw vs polished edit distance)
- Gamifies usage and validates time-saved claims

---

## Phase 2: Core Differentiation (2-4 weeks)

### P2.1: App-Aware Polish Profiles
**Source:** AI #1, Competitive #1 | **Impact:** High | **Effort:** Medium
- Auto-detect frontmost app via `NSWorkspace.shared.frontmostApplication`
- Apply context-appropriate polish:
  - Xcode/VS Code: code comments, strip casual filler
  - Slack/Teams: casual tone, emoji-friendly
  - Terminal: shell commands, no punctuation
  - Mail/Notion: formal tone, proper structure
- Store mapping in Configuration: `[BundleID: StylePackID]`
- **Differentiation:** No competitor auto-adapts polish style to active app

### P2.2: Clipboard-Aware Polish
**Source:** AI #2 | **Impact:** High | **Effort:** Medium
- Read `NSPasteboard.general.string(forType: .string)` before processing
- Include clipboard as context in LLM prompt:
  "User said: [transcript]. Clipboard contains: [clipboard]. Polish accordingly."
- Enable: "rewrite this to be concise" (clipboard has function), "translate this" (clipboard has text)
- Toggle in Settings with privacy warning
- **Differentiation:** Voice-first clipboard context integration is unique

### P2.3: Voice-Triggered Snippets
**Source:** AI #10 | **Impact:** Medium | **Effort:** Medium
- User defines: trigger phrase → template
- "boilerplate React component" → injects full component template
- "today's date" → injects `2026-05-31`
- Variables: `{{DATE}}`, `{{CLIPBOARD}}`, `{{TIME}}`
- Check ASR output against snippet triggers before LLM polish
- **Differentiation:** Replaces text expanders with voice

### P2.4: Commit Message Generator
**Source:** AI #5 | **Impact:** Medium | **Effort:** Medium
- New Style Pack: "Git Commit"
- Capture `git diff --staged` via `Process`
- User says: "I refactored auth to use JWT"
- Output: `refactor(auth): migrate to JWT-based authentication`
- Follows conventional commits format
- **Differentiation:** No voice tool generates commits from diff + voice

### P2.5: Code Comment / Docstring Generation
**Source:** AI #6 | **Impact:** Medium | **Effort:** Medium
- New Style Pack that transforms voice into documentation
- Detects language from active app (Xcode→SwiftDoc, VS Code→JSDoc)
- "This function calculates factorial recursively, throws on negative input"
- → Generates properly formatted docstring
- **Differentiation:** Voice-to-documentation is rare in developer tools

---

## Phase 3: Deep Features (1-2 months)

### P3.1: Voice Command Mode
**Source:** AI #3, Competitive #4 | **Impact:** High | **Effort:** Medium-High
- Triple-tap or long-hold enters command mode (distinct from dictation)
- Commands: "delete last sentence", "capitalize that", "insert emoji thumbs up", "switch to formal mode"
- Lightweight keyword spotter or heuristic parser
- Action dispatcher calls existing `KeyboardInjector.deleteCharacters()` etc.
- **Differentiation:** Voice command systems are rare in developer tools

### P3.2: Selected Text as Context
**Source:** AI #4 | **Impact:** High | **Effort:** Medium
- Use `AXUIElement` to capture selected text before recording
- Include in LLM prompt: "Transform the selected code based on instruction"
- "Refactor this", "Add types", "Convert to async/await"
- Replaces selected text via Cmd+X + inject
- **Differentiation:** Combines voice + code-aware transformation

### P3.3: MCP Server Integration
**Source:** Competitive #2 | **Impact:** High | **Effort:** Medium-High
- Expose FlowType as MCP (Model Context Protocol) server
- Claude Code, Cursor, and AI agents can call `dictate()` programmatically
- Local HTTP endpoint accepting JSON-RPC
- Returns transcribed text to agent
- **Differentiation:** Spokenly is first mover; FlowType should follow quickly

### P3.4: File Transcription (Drag & Drop)
**Source:** Competitive #3 | **Impact:** Medium | **Effort:** Medium
- Drop audio/video files onto floating panel or status bar icon
- Reuse QwenASRProvider with file input instead of mic buffer
- Export to SRT/VTT/TXT
- **Differentiation:** MacWhisper dominates file transcription but has weak live dictation

### P3.5: Local LLM Polish (Offline Mode)
**Source:** AI #7 | **Impact:** High | **Effort:** Hard
- Run Qwen2.5-1.5B-Instruct 4-bit (~1GB) via MLX for offline polish
- Zero latency, zero API cost, complete privacy
- Fallback when network unavailable
- **Differentiation:** Offline polish is rare (most tools are cloud-only)

---

## Phase 4: Technical Foundation (Ongoing)

### T1: Add Test Targets
**Source:** Technical #1 | **Impact:** High | **Effort:** Small
- Add test target to Package.swift
- Start with pure logic: ASRPostProcessor, Configuration migration, SessionState transitions
- Mock URLSession for LLMService tests

### T2: Fix Swift Concurrency
**Source:** Technical #2 | **Impact:** High | **Effort:** Medium
- Replace `@unchecked Sendable` with proper actor isolation
- Replace `UnsafeCell` with `OSAllocatedUnfairLock`
- Remove `nonisolated(unsafe)` from QwenASRProvider

### T3: Extract PipelineOrchestrator
**Source:** Technical #3 | **Impact:** High | **Effort:** Medium
- Split 616-line file into: SessionStateMachine, RecordingCoordinator, ProcessingPipeline, InjectionCoordinator, SessionAnalytics

### T4: SQLite/GRDB Persistence
**Source:** Technical #4 | **Impact:** High | **Effort:** Medium
- Replace JSON files with GRDB.swift
- Indexed queries for history search/filter
- Atomic transactions, schema migrations

### T5: Structured Logging
**Source:** Technical #5 | **Impact:** Medium | **Effort:** Small
- Migrate to `os.log` with `.private` privacy levels
- Add `os_signpost` for performance tracing
- 10MB log rotation, 3 files max

### T6: Code Signing + Sparkle
**Source:** Technical #9 | **Impact:** High | **Effort:** Large
- Developer ID signing + Hardened Runtime entitlements
- Sparkle 2.x for delta updates
- `notarytool` automation in CI

---

## Competitive Positioning Matrix

| Dimension | FlowType (Current) | FlowType (Future) | Best Competitor |
|-----------|-------------------|-------------------|-----------------|
| Local ASR | ✅ Qwen3-ASR | ✅ + streaming | SuperWhisper |
| LLM Polish | ✅ Streaming | ✅ + offline | Wispr Flow |
| System-wide | ✅ | ✅ | Tie |
| History/Stats | ✅ | ✅ + analytics | Tie |
| Dictionary | ✅ Auto-detect | ✅ + NER | Tie |
| Per-app modes | ❌ | ✅ (Phase 2) | SuperWhisper |
| Voice commands | ❌ | ✅ (Phase 3) | Wispr Flow |
| File transcription | ❌ | ✅ (Phase 3) | MacWhisper |
| MCP integration | ❌ | ✅ (Phase 3) | Spokenly |
| Lifetime pricing | ❌ | ✅ (Phase 1) | SuperWhisper |
| IDE integration | ❌ | ✅ (Phase 3) | Cursor |
| Cross-platform | ❌ macOS | ❌ (stay focused) | Typeless |

---

## Recommended Roadmap

| Quarter | Focus | Deliverables |
|---------|-------|-------------|
| Q3 2026 | Quick Wins + Differentiation | Lifetime pricing, onboarding demo, audio cues, app-aware profiles, clipboard context, snippets |
| Q4 2026 | Deep Features | Voice commands, selected text, MCP server, file transcription, commit generator |
| Q1 2027 | Technical Foundation | Tests, GRDB, concurrency fixes, Sparkle updates, local LLM polish |
| Q2 2027 | Platform Expansion | iOS companion (watch trigger), team dictionaries, advanced analytics |

---

## Appendices

### A. Full Feature Scoring Matrix (AI Research)
| Rank | Feature | Score | Value | Diff | Complexity |
|------|---------|-------|-------|------|------------|
| 1 | App-Aware Profiles | 8.0 | 5 | 4 | Medium |
| 2 | Clipboard Context | 7.5 | 5 | 3 | Medium |
| 3 | Voice Commands | 7.2 | 5 | 4 | Med-Hard |
| 4 | Selected Text | 7.0 | 4 | 4 | Medium |
| 5 | Commit Messages | 6.7 | 4 | 4 | Medium |
| 6 | Code Comments | 6.4 | 4 | 3 | Medium |
| 7 | Local LLM | 6.0 | 5 | 3 | Hard |
| 8 | NER Dictionary | 5.8 | 4 | 4 | Med-Hard |
| 9 | Screenshot Context | 5.6 | 4 | 4 | Hard |
| 10 | Voice Snippets | 5.4 | 4 | 3 | Medium |
| 11 | Shell Commands | 5.3 | 4 | 3 | Medium |
| 12 | Analytics Dashboard | 5.0 | 3 | 3 | Easy |
| 13 | Raycast/Alfred | 4.8 | 4 | 3 | Medium |
| 14 | Team Dictionaries | 4.0 | 3 | 3 | Hard |
| 15 | Sentiment Polish | 3.6 | 3 | 3 | Med-Hard |

### B. UX Improvement Matrix
| Rank | Improvement | Impact | Effort |
|------|-------------|--------|--------|
| 1 | Interactive onboarding | High | Small |
| 2 | Persistent trigger hint | High | Small |
| 3 | Retryable error cards | High | Small |
| 4 | Settings search | High | Medium |
| 5 | Audio feedback | Medium | Small |
| 6 | Settings shortcuts | Medium | Small |
| 7 | Expandable capsule | Medium | Medium |
| 8 | Per-app triggers | Medium | Large |
| 9 | VoiceOver support | High | Medium |
| 10 | History re-inject | Medium | Medium |

### C. Technical Debt Matrix
| Rank | Improvement | Impact | Effort |
|------|-------------|--------|--------|
| 1 | Test targets | High | Small |
| 2 | Concurrency fixes | High | Medium |
| 3 | Extract orchestrator | High | Medium |
| 4 | GRDB persistence | High | Medium |
| 5 | Structured logging | Medium | Small |
| 6 | LLM retry | High | Medium |
| 7 | Split SettingsView | Medium | Small |
| 8 | Crash reporting | High | Medium |
| 9 | Code signing/Sparkle | High | Large |
| 10 | Streaming ASR | High | Large |
