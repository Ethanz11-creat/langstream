# FlowType Security Fix Plan

**Generated from:** STRIDE + OWASP audit (2026-05-31)
**Total findings:** 36 (4 Critical, 10 High, 14 Medium, 8 Low)

---

## Tier 1: Fix Immediately (Critical + High Exploitability)

### T1.1: Sanitize Error Response Logging (H1)
**File:** `Sources/flowtype/Services/LLMService.swift`
**Risk:** API keys may appear in LLM API error responses and get logged to plaintext file.
**Change:**
- Replace `AppLogger.log("... \(errorBody.prefix(500))")` with sanitized logging
- Strip patterns matching API key formats (`sk-`, `sf-`, `Bearer`)
- Log only status code + generic message

### T1.2: Remove Transcript Content from Logs (H2)
**File:** `Sources/flowtype/Core/PipelineOrchestrator.swift`
**Risk:** ASR text and polished output logged to `~/Library/Logs/flowtype/diagnostic.log` forever.
**Change:**
- Replace transcript content in logs with length metadata only
- e.g., `Qwen3-ASR completed: 145 chars` instead of `Qwen3-ASR completed: 'actual text...'`
- Apply to all log lines that include `.prefix()` of transcript text

### T1.3: Validate baseURL to Prevent SSRF (C1)
**File:** `Sources/flowtype/Services/LLMService.swift`, `Sources/flowtype/Settings/SettingsView.swift`
**Risk:** Attacker-controlled baseURL receives API keys + transcripts.
**Change:**
- In `SettingsView.normalizeBaseURL()`: validate with `URLComponents`
- Ensure scheme is `https`, host is non-empty, no userinfo component
- In `LLMService`: validate resolved URL before request
- Consider allowlist for known providers with warning for custom URLs

### T1.4: Protect CSV Export from Formula Injection (H3)
**File:** `Sources/flowtype/Settings/HistoryPage.swift`
**Risk:** Exported CSV can execute Excel formulas.
**Change:**
- Sanitize cell values before CSV export
- Prefix values starting with `=`, `+`, `-`, `@`, tab, or newline with `'`
- Replace newlines within cell values with spaces

### T1.5: Sanitize Dictionary Phrases Before Prompt Injection (H4)
**File:** `Sources/flowtype/Core/Dictionary.swift`, `Sources/flowtype/Services/LLMService.swift`
**Risk:** Auto-detected dictionary phrases injected into LLM system prompts unsanitized.
**Change:**
- In `DictionaryStore.addAutoDetected()`: cap phrase length (max 50 chars)
- In `LLMService.composeSystemPrompt()`: sanitize phrases before injection
- Strip/reject phrases matching injection patterns ("ignore previous instructions", `</system>`, markdown blocks)
- Reject phrases with URLs or shell metacharacters

### T1.6: Add Defer-Based Clipboard Restoration (H5)
**File:** `Sources/flowtype/Services/KeyboardInjector.swift`
**Risk:** Crash between clipboard clear and restore = permanent data loss.
**Change:**
- Move clipboard restoration into `defer` block immediately after saving clipboard
- Ensure restoration runs on all exit paths (normal return, throw, crash via signal is unavoidable)

### T1.7: Cap Audio Sample Buffer (H6)
**File:** `Sources/flowtype/Services/AudioRecorder.swift`
**Risk:** Unbounded memory growth during recording.
**Change:**
- Add hard cap on `rawSamples` array (max 30 min = ~112 MB at 16kHz Float32)
- Auto-stop recording when cap reached
- Validate `maxRecordingDuration` at Configuration load time (10-600 seconds)

### T1.8: Cap Text Injection Length (H7)
**File:** `Sources/flowtype/Services/KeyboardInjector.swift`, `Sources/flowtype/Core/PipelineOrchestrator.swift`
**Risk:** Unbounded keystroke injection blocks app for minutes.
**Change:**
- In `typeText()`: hard cap at 100 characters, force `pasteText` for longer
- In `SessionController.injectText()`: add 30-second overall injection timeout

---

## Tier 2: Fix Next (Medium Impact)

### T2.1: Add Log Rotation to AppLogger (M5)
**File:** `Sources/flowtype/Utilities/AppLogger.swift`
**Risk:** Log file grows unbounded with sensitive data.
**Change:**
- Implement 7-day log rotation
- Delete logs older than 7 days on startup
- Consider migrating to `os_log` with `.private` privacy level

### T2.2: Add Target App Validation Before Injection (H9)
**File:** `Sources/flowtype/Services/KeyboardInjector.swift`, `Sources/flowtype/Core/PipelineOrchestrator.swift`
**Risk:** Text injected into wrong application (e.g., terminal).
**Change:**
- Capture `NSWorkspace.shared.frontmostApplication` before injection
- After injection delay, verify same app is still frontmost
- Cancel injection if app changed

### T2.3: Fix UnsafeCell Synchronization (M3)
**File:** `Sources/flowtype/Utilities/UnsafeCell.swift`, `Sources/flowtype/WindowManager.swift`
**Risk:** Race conditions in event tap callback.
**Change:**
- Replace `UnsafeCell` with `OSAllocatedUnfairLock<T>`
- Or migrate to `@MainActor`-isolated design
- Add `dispatchPrecondition` assertion in C callback

### T2.4: Add Keychain Access Group Restrictions (M4)
**File:** `Sources/flowtype/Utilities/KeychainHelper.swift`
**Risk:** Other apps from same team can read API keys.
**Change:**
- Add `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Add `kSecAttrAccessGroup` with app group identifier
- Add `kSecUseDataProtectionKeychain: true`

### T2.5: Validate Configuration Bounds (M11)
**File:** `Sources/flowtype/Core/Configuration.swift`, `Sources/flowtype/Core/ConfigurationStore.swift`
**Risk:** Malformed config values cause crashes or DoS.
**Change:**
- Validate `maxRecordingDuration` (10-600)
- Validate `maxTokens` (1-8192)
- Validate `temperature` (0.0-2.0)
- Validate `baseURL` is valid HTTPS URL

### T2.6: Add Rate Limiting Between Sessions (L4)
**File:** `Sources/flowtype/Core/PipelineOrchestrator.swift`
**Risk:** Stuck key or malicious script generates unlimited API requests.
**Change:**
- Add 2-second minimum between session starts
- Log and warn on rapid triggering

### T2.7: System Default Audio Device Mutation (H10)
**File:** `Sources/flowtype/Services/AudioRecorder.swift`
**Risk:** Changing system default affects all apps.
**Change:**
- Already partially fixed: save/restore original device in `stopRecording()`
- Add validation: ensure requested device is in `availableInputDevices()`
- Consider routing AVAudioEngine to specific device without changing system default

### T2.8: PersistentStore Integrity (M1)
**File:** `Sources/flowtype/Core/Persistence.swift`
**Risk:** JSON files can be tampered with offline.
**Change:**
- Add HMAC-SHA256 signature companion file (`.sig`)
- Store HMAC key in Keychain
- On load, verify signature before decoding

---

## Tier 3: Document / Defer (Build System / Architectural)

### T3.1: Hardened Runtime + Code Signing (C2)
**File:** Build scripts, new `FlowType.entitlements`
**Risk:** DYLD injection possible without hardened runtime.
**Action:**
- Create `FlowType.entitlements` with hardened runtime flags
- Enable `com.apple.security.cs.require-library-validation`
- Sign with Developer ID in release builds
- Document that sandbox is intentionally disabled (Accessibility requirement)

### T3.2: Certificate Pinning (H8)
**File:** `Sources/flowtype/Services/LLMService.swift`
**Risk:** MITM with rogue CA certificate.
**Action:**
- Implement custom `URLSessionDelegate` for known providers
- Pin certificates or public keys for SiliconFlow, OpenAI, Azure
- Document risk for custom providers

### T3.3: Remove .env File Loading (M7)
**File:** `Sources/flowtype/Core/DotEnv.swift`, `Sources/flowtype/Core/EnvMigration.swift`
**Risk:** Arbitrary `.env` files loaded from CWD.
**Action:**
- Remove `.env` loading for production builds
- Keep migration code for one-time upgrade only
- Document that `.env` is not supported in distributed app

### T3.4: Encrypt Persisted Files (M6)
**File:** `Sources/flowtype/Core/Persistence.swift`
**Risk:** Dictation history stored in plaintext.
**Action:**
- Encrypt JSON data with AES-256-GCM before writing
- Key derived from Keychain
- Document plaintext storage risk for users

### T3.5: Audit Trail for History (M2)
**File:** `Sources/flowtype/Core/DictationHistory.swift`
**Risk:** Deletions leave no trace.
**Action:**
- Use `os_log` with `.persist` for deletion events
- Log session outcomes (success/cancelled/error)

### T3.6: Model Download Integrity (M8)
**File:** `Sources/flowtype/Services/Speech/QwenASRProvider.swift`
**Risk:** Model weights downloaded without verification.
**Action:**
- Pin to specific commit hash
- Verify SHA-256 checksum after download

---

## Implementation Priority Matrix

| Priority | Tasks | Effort | Impact |
|----------|-------|--------|--------|
| P0 | T1.1, T1.2, T1.3, T1.4, T1.5 | Low-Medium | Critical |
| P1 | T1.6, T1.7, T1.8 | Low | High |
| P2 | T2.1, T2.2, T2.3, T2.4, T2.5 | Medium | Medium |
| P3 | T2.6, T2.7, T2.8 | Low-Medium | Medium |
| P4 | T3.1 - T3.6 | High | Medium-High |

**Recommended approach:** Implement P0 + P1 (11 tasks) first — all are code-only changes with high security impact. P2 can follow. P3/Tier 3 items require build system changes or architectural decisions and should be planned separately.
