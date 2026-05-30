# FlowType Feature Roadmap PRD

**Version:** 1.0  
**Date:** 2026-05-25  
**Status:** Draft (Pending Review)  

---

## 1. Background & Context

FlowType is a macOS-native voice input app for AI coding workflows. It captures speech via local Qwen3-ASR, optionally refines with an LLM, and injects the result at the cursor.

This PRD defines the features needed to close the gap with OpenLess (our primary open-source benchmark) while maintaining FlowType's macOS-native Swift/SwiftUI architecture and focusing on simplicity over configuration overload.

**Current Tech Stack:**
- Swift 6.2, SwiftUI, SPM
- macOS 15+ (single platform, no Windows/Linux)
- Qwen3-ASR (MLX, local) + Apple Speech (preview/fallback)
- OpenAI-compatible LLM API for polish
- CGEventTap for global hotkey
- UserDefaults + Keychain for persistence

---

## 2. Goals

1. **Match OpenLess core UX** for hotkey flexibility and provider configuration.
2. **Add translation mode** as a differentiated feature for bilingual developers.
3. **Improve device control** with microphone selection.
4. **Ensure frontend-backend consistency** — every UI control must have a working backend path.

---

## 3. Out of Scope (Explicitly Excluded)

Per product decision, the following are **not** in this roadmap:

| Feature | Reason |
|---------|--------|
| Push-to-Talk mode | Product decision: keep tap-based interaction only |
| 4 output modes (Raw/Light/Structured/Formal) | Product decision: keep current 2 modes (raw + polish) |
| Selection QA panel | Product decision: defer to later phase |
| Cloud streaming ASR (Volcengine, Whisper, etc.) | Product decision: local-first, Apple Speech as fallback only |
| Multi-language UI | Product decision: Chinese UI only for now |
| In-app auto-update | Defer to distribution phase |
| Windows/Linux port | macOS-only product |
| Vocab Presets / Marketplace | Defer |
| Correction Rules | Defer |
| Audio WAV debug archive | Defer |
| Single-instance lock | macOS `.accessory` app already behaves this way |

---

## 4. Feature Specifications

### 4.1 Custom Hotkey Configuration (P0)

**Current State:**
- Fixed modifier keys: `Command` (default), `Fn`, `Control`, `Option`
- Interaction: Double-tap to start recording, single-tap to stop (raw), double-tap to stop (polish)
- Anti-misfire: 0.35s tap detection window

**Problems:**
1. Users cannot use non-modifier keys (e.g., `F13`, `Caps Lock`, `Right Command`).
2. Users cannot change the interaction pattern (e.g., some want single-tap to start, single-tap to stop).
3. Previous attempts at custom hotkey integration caused intermittent crashes (likely due to `CGEventTap` callback re-entrancy or unsafe `Unmanaged` pointer access).

**Requirements:**

#### 4.1.1 Trigger Key Selection
- Support **modifier-only** keys: `Command`, `Option`, `Control`, `Fn` (existing)
- Support **single key** triggers: `F13`, `F14`, `F15`, `Caps Lock`, `Right Command` (new)
- Store the selection in `Configuration.triggerKey` with backward-compatible decoding

#### 4.1.2 Interaction Mode
- **Mode A (Current/Default):** Double-tap to start, single-tap to stop (raw), double-tap to stop (polish)
- **Mode B (Toggle):** Single-tap to start, single-tap to stop. On stop, prompt user (or use last-used mode) for raw vs polish.
- Store in `Configuration.interactionMode`

#### 4.1.3 Anti-Misfire
- Keep the 0.35s debounce window for modifier keys.
- For single-key triggers, require a **press-and-hold** (≥0.2s) to start, or use key-down + key-up timing.

#### 4.1.4 Safety Requirements
- The `CGEventTap` callback must not access `@MainActor` state directly.
- All cached values (`cachedTriggerKey`, `cachedSessionActive`) must use `UnsafeCell` with proper memory ordering.
- The `eventTapPort` must be invalidated and nulled on `reloadHotkey()` to prevent dangling ports.
- `Unmanaged.passUnretained(self).toOpaque()` is safe only because `WindowManager` is a singleton; add a runtime assertion.

**Data Model Changes:**

```swift
// Configuration.swift
enum TriggerKey: String, Codable, CaseIterable {
    case fn, control, option, command
    case f13, f14, f15
    case capsLock
    case rightCommand

    var isModifier: Bool { ... }
    var cgEventFlag: CGEventFlags? { ... } // nil for non-modifier
    var keyCode: CGKeyCode? { ... } // nil for modifier-only
}

enum InteractionMode: String, Codable, CaseIterable {
    case tapToStart    // Double-tap start, single/double stop
    case toggle        // Single-tap toggle
}

struct Configuration: Codable, Equatable {
    var triggerKey: TriggerKey = .command
    var interactionMode: InteractionMode = .tapToStart
    // ...
}
```

**UI Changes:**
- Settings → Trigger Key & Interaction: Replace current segmented picker with a two-row layout:
  - Row 1: "触发键" picker (dropdown with all supported keys)
  - Row 2: "交互模式" picker ("双击开始 / 单击停止" vs "单击切换")
  - Visual hint showing the current shortcut and what each tap does.

---

### 4.2 Multi-Provider LLM Configuration (P0)

**Current State:**
- Single provider config: `llmProvider`, `llmBaseURL`, `llmApiKey`, `llmModel`
- Presets: SiliconFlow, OpenAI, Azure, Custom
- LLMService reads from `ConfigurationStore.shared.current` directly

**Problems:**
- Users who have multiple API keys (e.g., SiliconFlow for daily use, OpenAI for backup) must manually swap credentials.
- No way to quickly switch between providers without retyping.

**Requirements:**

#### 4.2.1 Provider List
- Store an **array** of `ServiceConfig` (max 5 entries).
- One entry is marked as `isActive`.
- Presets fill default `baseURL` when selected.

#### 4.2.2 Provider Structure
Each provider entry contains:
- `id: UUID` (internal)
- `name: String` (display name, e.g., "SiliconFlow-主账号")
- `provider: String` (preset identifier: "SiliconFlow", "OpenAI", "Azure", "Custom")
- `baseURL: String`
- `apiKey: String` (stored in Keychain, keyed by `id.uuidString`)
- `model: String`
- `isActive: Bool`

#### 4.2.3 Keychain Storage
- API keys are stored in Keychain using `id.uuidString` as the account identifier.
- On deletion of a provider, the corresponding Keychain entry is removed.
- Migration: on first launch with new schema, migrate the old single-key to a provider entry named "默认配置".

#### 4.2.4 Active Provider Resolution
- `LLMService` resolves the active provider at call time (not cached).
- If the active provider is invalid (empty API key), fall back to the first valid provider in the list.
- If no providers are valid, show an error in the capsule: "请在设置中配置 LLM API Key"。

**Data Model Changes:**

```swift
// Configuration.swift
struct LLMProvider: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var provider: String       // preset name
    var baseURL: String
    var model: String
    var isActive: Bool
}

struct Configuration: Codable, Equatable {
    var llmProviders: [LLMProvider] = []
    // ... remove old llmProvider/llmBaseURL/llmModel/llmApiKey fields ...
}
```

**UI Changes:**
- Settings → LLM Section: Replace single `ServiceConfigCard` with a list of provider cards.
- Each card: name, provider, model, status indicator (active/inactive).
- Actions per card: "设为默认" / "编辑" / "删除".
- "添加 Provider" button opens a modal with the existing `ServiceConfigCard` layout.
- Active provider gets a green border/checkmark.

**Migration:**
- `ConfigurationStore` detects old schema (presence of `llmApiKey`) and auto-migrates to new `llmProviders` array.
- Old Keychain key (`llmApiKey`) is read, inserted into a new `LLMProvider(id: ..., name: "默认配置", ...)`.

---

### 4.3 Translation Mode (P1)

**Current State:**
- Two modes: raw ASR (single-tap stop) and LLM polish (double-tap stop).

**Requirements:**

#### 4.3.1 Translation Entry Point
- Add a **third stop action**: Triple-tap (or a dedicated translation hotkey) stops recording and enters translation mode.
- Alternatively: In Settings, users can bind a separate translation trigger (e.g., `Option` key). Product decision needed.

**Decision:** Use a separate translation trigger key (default: `Option` double-tap) to avoid overloading the primary trigger with too many tap patterns.

#### 4.3.2 Translation Flow
1. User double-taps translation trigger key → starts recording (same as normal).
2. User speaks in source language.
3. User single-taps translation trigger key → stops recording.
4. ASR transcribes (same pipeline).
5. LLM receives a **translation prompt** instead of the polish prompt.
6. Translated text is injected at cursor.

#### 4.3.3 Translation Prompt

```
你是一位专业的翻译助手。请将以下文本翻译成 {targetLanguage}。
要求：
1. 保持原意准确，不要添加或删减内容。
2. 口语化表达转为对应语言的自然表达。
3. 技术术语保留英文或根据上下文翻译。
4. 只输出翻译结果，不添加任何解释、前缀或后缀。
```

#### 4.3.4 Language Pair Configuration
- Source language: Auto-detect (from ASR language setting) or explicit.
- Target language: `zh`, `en`, `ja`, `ko` (picker in Settings).
- Store in `Configuration.translationConfig`.

**Data Model Changes:**

```swift
struct TranslationConfig: Codable, Equatable {
    var sourceLanguage: WhisperLanguage = .auto
    var targetLanguage: WhisperLanguage = .en
    var isEnabled: Bool = true
}

struct Configuration: Codable, Equatable {
    var translationConfig: TranslationConfig = .init()
    // ...
}
```

**UI Changes:**
- Settings → Translation Section (new card):
  - Toggle: "启用翻译模式"
  - Source language picker
  - Target language picker
  - Trigger key picker (default: Option)
- Capsule: When translation mode is active, show a different color/icon (e.g., blue globe instead of purple sparkles).

**Backend Changes:**
- `PipelineOrchestrator`: Add `endRecording(withTranslation: Bool)` path.
- `LLMService.composeSystemPrompt`: Add overload for translation mode.
- `WindowManager`: Add a second `OptionTapDetector` (or extend existing) for translation trigger.

---

### 4.4 Microphone Device Selection (P1)

**Current State:**
- `AudioRecorder` uses `AVAudioEngine.inputNode` (default device) with no selection.

**Requirements:**

#### 4.4.1 Device Enumeration
- Enumerate all available input devices using `AVAudioSession` (if applicable) or `AVAudioEngine` + `AVAudioUnit` APIs.
- Show device name and a "默认" marker for the system default.

#### 4.4.2 Device Selection
- User selects a device in Settings.
- Selection is persisted in `Configuration.microphoneDeviceName`.
- On recording start, `AudioRecorder` looks up the selected device by name; if not found, falls back to default.

#### 4.4.3 Hot-Plug Support
- If the selected device is unplugged during recording, gracefully stop recording and show an error: "麦克风已断开，录音已停止。"
- On next recording, fall back to default device.

**Data Model Changes:**

```swift
struct Configuration: Codable, Equatable {
    var microphoneDeviceName: String? = nil // nil = system default
    // ...
}
```

**UI Changes:**
- Settings → ASR Section: Add "麦克风设备" picker below the language selector.
- Picker options: "系统默认", then list of available devices.
- If the selected device is unavailable (unplugged), show an orange warning badge.

**Backend Changes:**
- `AudioRecorder.startRecording()`: Accept optional `microphoneDeviceName` parameter.
- Use `AVAudioSession` or `AVAudioEngine` to route to the named input device.

---

### 4.5 Experience & Consistency Fixes (P0)

These are not new features but fixes to ensure the existing UI always works end-to-end.

#### 4.5.1 Settings Save Consistency
- **Current:** `onChange(of: store.current)` triggers save + `reloadHotkey()` + toast.
- **Problem:** Rapid changes can cause concurrent `reloadHotkey()` calls, leading to multiple CGEventTaps or port leaks.
- **Fix:** Debounce `reloadHotkey()` by 0.5s. Cancel pending reload on new change.

#### 4.5.2 LLM Config Validation
- **Current:** Settings page shows input fields but doesn't validate the config.
- **Fix:** Add a "测试连接" button next to each provider card. On tap, send a minimal non-streaming request (e.g., `"hello"` with `max_tokens: 5`). Show green/red status.

#### 4.5.3 Capsule State Synchronization
- **Current:** Capsule shows state from `SessionController.sessionState`, but there are edge cases where the capsule doesn't hide after injection failure.
- **Fix:** Ensure `resetToIdle()` is called in all error paths. Add a `guard case .injecting = sessionState` check before hiding the panel.

#### 4.5.4 Onboarding Flow Completion
- **Current:** `OnboardingView` exists but may not be wired to show on first launch.
- **Fix:** Check `UserDefaults` for `hasCompletedOnboarding`. If false, show `OnboardingWindowController` on app launch.

#### 4.5.5 Accessibility Permission State
- **Current:** Settings shows a static permission card that only updates on `onAppear`.
- **Fix:** Poll permission status every 2s while Settings is visible, or use KVO if possible.

---

## 5. Data Model Summary

### 5.1 New Types

```swift
enum InteractionMode: String, Codable, CaseIterable {
    case tapToStart, toggle
}

struct LLMProvider: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var provider: String
    var baseURL: String
    var model: String
    var isActive: Bool
}

struct TranslationConfig: Codable, Equatable {
    var sourceLanguage: WhisperLanguage = .auto
    var targetLanguage: WhisperLanguage = .en
    var isEnabled: Bool = true
}
```

### 5.2 Updated Configuration

```swift
struct Configuration: Codable, Equatable {
    // ASR
    var asrLanguage: WhisperLanguage = .zh
    var microphoneDeviceName: String? = nil

    // LLM (new multi-provider)
    var llmProviders: [LLMProvider] = []

    // Translation
    var translationConfig: TranslationConfig = .init()

    // Hotkey
    var triggerKey: TriggerKey = .command
    var interactionMode: InteractionMode = .tapToStart
    var translationTriggerKey: TriggerKey = .option

    // Toggles
    var dumpAudio: Bool = false
    var enableFillerStrip: Bool = true
    var enableTermCorrection: Bool = true

    // LLM Parameters
    let temperature: Double = 0.3
    let maxTokens: Int = 2048
    var systemPrompt: String = Configuration.defaultSystemPrompt
    var translationPrompt: String = Configuration.defaultTranslationPrompt
}
```

### 5.3 Backward Compatibility

- Old `llmProvider` / `llmBaseURL` / `llmModel` / `llmApiKey` fields are removed from `Configuration` but decoded gracefully via `LegacyKeys` enum.
- Migration happens in `ConfigurationStore.load()` on first read of old schema.

---

## 6. UI/UX Design

### 6.1 Settings Page Reorganization

```
设置
├── 语音转文字（ASR）
│   ├── Qwen3-ASR 状态卡片
│   ├── 识别语言 [自动/中文/English]
│   └── 麦克风设备 [系统默认 / 设备列表]
├── 文本润色（LLM）
│   ├── Provider 列表卡片 (可添加/编辑/删除)
│   │   ├── [激活] SiliconFlow — deepseek-ai/DeepSeek-V3
│   │   ├── [ ] OpenAI — gpt-4o
│   │   └── [+ 添加 Provider]
│   └── 系统提示词编辑器
├── 翻译模式
│   ├── [启用翻译模式] 开关
│   ├── 源语言 [自动]
│   ├── 目标语言 [English]
│   └── 翻译触发键 [Option]
├── 触发键与交互
│   ├── 触发键 [Command] (dropdown)
│   ├── 交互模式 [双击开始/单击停止]
│   └── 操作说明可视化
└── 权限与系统状态
    ├── 辅助功能权限状态
    └── 查看诊断日志
```

### 6.2 Provider Card (LLM Section)

Each provider card is a compact row:
- Left: Status dot (green = active, gray = inactive)
- Middle: Name, provider badge, model ID
- Right: "设为默认" (if inactive) / "编辑" / "删除"
- Bottom (expandable): Base URL (masked), API Key (masked)

---

## 7. Implementation Phases

### Phase 1: Foundation & Safety (P0)
- [ ] Refactor `Configuration` with backward-compatible migration
- [ ] Implement `LLMProvider` list + Keychain storage
- [ ] Update `LLMService` to resolve active provider dynamically
- [ ] Settings UI: Provider list, add/edit/delete
- [ ] Debounce `reloadHotkey()`

### Phase 2: Hotkey Flexibility (P0)
- [ ] Extend `TriggerKey` with non-modifier keys
- [ ] Implement `InteractionMode` (tapToStart / toggle)
- [ ] Update `WindowManager` + `OptionTapDetector` for new modes
- [ ] Settings UI: Trigger key picker + interaction mode

### Phase 3: Translation Mode (P1)
- [ ] Add `TranslationConfig` to `Configuration`
- [ ] Add translation prompt + `LLMService` path
- [ ] Add translation trigger to `WindowManager`
- [ ] Update `PipelineOrchestrator` for translation flow
- [ ] Settings UI: Translation section
- [ ] Capsule UI: Translation state indicator

### Phase 4: Microphone Selection (P1)
- [ ] Implement device enumeration in `AudioRecorder`
- [ ] Add device selection parameter to recording start
- [ ] Handle hot-plug disconnect gracefully
- [ ] Settings UI: Microphone picker

### Phase 5: Polish (P0)
- [ ] LLM connection test button
- [ ] Onboarding flow wiring
- [ ] Accessibility permission live polling
- [ ] Capsule state sync fixes

---

## 8. Risk & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Custom hotkey causes CGEventTap crashes (previous attempt) | Medium | High | Isolate all callback state in `UnsafeCell`; add runtime assertions; never access `@MainActor` from C callback |
| Configuration migration corrupts old user data | Low | High | Test migration with old JSON payloads; keep backup of old keys for one release |
| Keychain API key migration fails silently | Medium | Medium | Log all Keychain operations; show error if key cannot be read |
| Microphone device selection fails on some hardware | Medium | Low | Graceful fallback to default; log device enumeration errors |
| Translation prompt quality is poor | Medium | Medium | Iterate prompt with test cases; allow user to customize in Settings |

---

## 9. Success Criteria

- [ ] User can add, edit, delete, and switch between at least 2 LLM providers without restarting the app.
- [ ] User can change trigger key to `F13` or `Caps Lock` and recording starts/stops correctly.
- [ ] User can enable translation mode and dictate Chinese → English with one double-tap.
- [ ] User can select a non-default microphone and recording uses it.
- [ ] No UI button is unresponsive; every setting change is persisted and applied immediately.
- [ ] Old users' single-provider config migrates seamlessly to the new multi-provider list.

---

## 10. Appendix: OpenLess Feature Reference

For context, here are the OpenLess features we are **not** implementing in this phase:

- Push-to-Talk recording mode
- 4 output modes (Raw / Light / Structured / Formal)
- Selection QA panel
- Cloud streaming ASR (Volcengine, Whisper API, Bailian)
- Vocab Presets / Marketplace
- Correction Rules
- Multi-language UI
- In-app auto-update
- Beta channel
- Audio WAV debug archive
- Windows / Linux support
