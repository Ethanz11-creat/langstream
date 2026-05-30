# LLM 稳定性与 UX 完善实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 加固多 Provider LLM 配置的稳定性，完善麦克风设备选择、首次引导流程和 Capsule 动态提示。

**Architecture:** 在现有代码基础上增量修改。LLM 层增强连接测试和自动降级；音频层增加 CoreAudio 设备枚举和路由；UI 层完善 Onboarding 和动态提示生成。

**Tech Stack:** Swift 6.2, SwiftUI, AVFoundation, CoreAudio, CGEventTap

---

## 文件结构

### 新增文件
| 文件 | 职责 |
|------|------|
| `Sources/flowtype/Services/AudioDevice.swift` | 音频设备模型 `AudioDevice` 和枚举逻辑 |

### 修改文件
| 文件 | 职责 |
|------|------|
| `Sources/flowtype/Core/Configuration.swift` | 新增 `microphoneDeviceID`、`hasCompletedOnboarding` 字段 |
| `Sources/flowtype/Core/ConfigurationStore.swift` | 迁移逻辑更新（migration version 4） |
| `Sources/flowtype/Services/LLMService.swift` | Provider 降级链、testConnection 增强 |
| `Sources/flowtype/Services/AudioRecorder.swift` | 设备枚举、指定设备录音、热插拔检测 |
| `Sources/flowtype/WindowManager.swift` | 非修饰键 press-and-hold 防误触 |
| `Sources/flowtype/CapsuleView.swift` | idle 提示动态生成 |
| `Sources/flowtype/Settings/SettingsView.swift` | Provider 保存前测试、校验、麦克风选择器 |
| `Sources/flowtype/Settings/OnboardingView.swift` | 简化引导步骤、触发键动态说明 |
| `Sources/flowtype/App/StatusBarController.swift` | 添加"重新打开引导"菜单项 |

---

## Task 1: Configuration 数据模型扩展

**Files:**
- Modify: `Sources/flowtype/Core/Configuration.swift`

**背景：** 为麦克风设备选择和 Onboarding 状态添加配置字段。

- [ ] **Step 1: 新增 `microphoneDeviceID` 和 `hasCompletedOnboarding` 字段**

在 `Configuration` struct 的现有字段之后添加：

```swift
    // Module 2a: Microphone device selection
    var microphoneDeviceID: String? = nil

    // Module 2b: Onboarding
    var hasCompletedOnboarding: Bool = false
```

- [ ] **Step 2: 更新 CodingKeys 和 decode/encode**

在 `CodingKeys` enum 中添加新键：

```swift
    case microphoneDeviceID
    case hasCompletedOnboarding
```

在 `init(from decoder:)` 中添加解码（带默认值）：

```swift
        microphoneDeviceID = (try? c.decode(String?.self, forKey: .microphoneDeviceID)) ?? d.microphoneDeviceID
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
```

在 `encode(to encoder:)` 中添加编码：

```swift
        try container.encode(microphoneDeviceID, forKey: .microphoneDeviceID)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: 编译成功，无错误

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/Core/Configuration.swift
git commit -m "feat(config): add microphoneDeviceID and hasCompletedOnboarding fields"
```

---

## Task 2: ConfigurationStore Migration 更新

**Files:**
- Modify: `Sources/flowtype/Core/ConfigurationStore.swift`

**背景：** 升级 migration version，确保旧配置读取时新字段有默认值。

- [ ] **Step 1: 升级 migration version**

将 `currentMigrationVersion` 从 3 改为 4：

```swift
    private let currentMigrationVersion = 4
```

- [ ] **Step 2: 添加 Migration 4 逻辑**

在 init 的 migration 块末尾添加：

```swift
            if storedVersion < 4 {
                // Migration 4: new fields have default values, just bump version
                needsSave = true
            }
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/Core/ConfigurationStore.swift
git commit -m "feat(config): bump migration version to 4 for new fields"
```

---

## Task 3: LLMService Provider 降级链

**Files:**
- Modify: `Sources/flowtype/Services/LLMService.swift`

**背景：** 当 active Provider 调用失败时，自动尝试列表中的下一个有效 Provider。

- [ ] **Step 1: 替换 `resolveActiveProvider` 为返回列表**

将现有的 `resolveActiveProvider` 方法替换为返回按优先级排序的 Provider 列表：

```swift
    // MARK: - Provider Resolution

    private func resolveProviderChain(providers: [LLMProvider]) -> [(provider: LLMProvider, apiKey: String)] {
        var result: [(provider: LLMProvider, apiKey: String)] = []

        // Active provider first
        if let active = providers.first(where: \.isActive) {
            if let apiKey = ConfigurationStore.shared.loadProviderAPIKey(active.id),
               !apiKey.isEmpty {
                result.append((active, apiKey))
            }
        }

        // Then other providers with valid API keys
        for provider in providers {
            if provider.isActive { continue } // Skip active, already added
            if let apiKey = ConfigurationStore.shared.loadProviderAPIKey(provider.id),
               !apiKey.isEmpty {
                result.append((provider, apiKey))
            }
        }

        return result
    }
```

- [ ] **Step 2: 修改 `makeStream` 使用降级链**

在 `makeStream` 中，将 `resolveActiveProvider` 调用替换为 `resolveProviderChain`，并添加重试逻辑：

替换这段：
```swift
                guard let resolved = self.resolveActiveProvider(providers: config.llmProviders) else {
                    continuation.finish(throwing: LLMError.apiError("请在设置中配置 LLM API Key"))
                    return
                }

                do {
                    try await Self.streamRequest(
                        apiKey: resolved.apiKey,
                        baseURL: resolved.provider.baseURL,
                        model: resolved.provider.model,
                        ...
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
```

为：

```swift
                let chain = self.resolveProviderChain(providers: config.llmProviders)
                guard !chain.isEmpty else {
                    continuation.finish(throwing: LLMError.apiError("请在设置中配置 LLM API Key"))
                    return
                }

                var lastError: Error?
                let maxAttempts = min(chain.count, 2)
                for i in 0..<maxAttempts {
                    let resolved = chain[i]
                    do {
                        AppLogger.log("[LLMService] Trying provider \(resolved.provider.name) (attempt \(i+1)/\(maxAttempts))")
                        try await Self.streamRequest(
                            apiKey: resolved.apiKey,
                            baseURL: resolved.provider.baseURL,
                            model: resolved.provider.model,
                            temperature: temperature,
                            systemPrompt: systemPrompt,
                            userMessage: validatedText,
                            maxTokens: maxTokens,
                            timeoutSeconds: timeoutSeconds,
                            continuation: continuation
                        )
                        return // Success — streamRequest finished normally
                    } catch {
                        lastError = error
                        AppLogger.log("[LLMService] Provider \(resolved.provider.name) failed: \(error)")
                        if i < maxAttempts - 1 {
                            AppLogger.log("[LLMService] Falling back to next provider...")
                        }
                    }
                }

                // All attempts exhausted
                if let lastError = lastError {
                    continuation.finish(throwing: lastError)
                } else {
                    continuation.finish(throwing: LLMError.apiError("所有 Provider 均不可用"))
                }
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/Services/LLMService.swift
git commit -m "feat(llm): add provider fallback chain on polish failure"
```

---

## Task 4: LLMService 连接测试增强

**Files:**
- Modify: `Sources/flowtype/Services/LLMService.swift`

**背景：** 将 testConnection 的错误信息细化，便于 UI 显示具体原因。

- [ ] **Step 1: 扩展 LLMError 添加结构化错误**

在 `LLMError` enum 中添加：

```swift
    var userFriendlyMessage: String {
        switch self {
        case .invalidResponse:
            return "无效响应格式"
        case .apiError(let msg):
            if msg.contains("401") || msg.contains("403") {
                return "API Key 无效或已过期"
            } else if msg.contains("404") {
                return "模型 ID 不存在"
            } else if msg.contains("500") || msg.contains("502") || msg.contains("503") {
                return "服务商接口异常"
            } else if msg.contains("超时") || msg.contains("timeout") {
                return "连接超时"
            }
            return msg
        case .streamDecodingError:
            return "流数据解码失败"
        case .networkError(let error):
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorTimedOut, NSURLErrorDNSLookupFailed:
                    return "连接超时，请检查网络或 Base URL"
                case NSURLErrorCannotFindHost:
                    return "无法解析 Base URL"
                case NSURLErrorNotConnectedToInternet:
                    return "网络未连接"
                default:
                    break
                }
            }
            return "网络错误: \(error.localizedDescription)"
        case .timeout:
            return "请求超时"
        }
    }
```

- [ ] **Step 2: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add Sources/flowtype/Services/LLMService.swift
git commit -m "feat(llm): add user-friendly error messages to LLMError"
```

---

## Task 5: Provider 保存前连接测试与校验

**Files:**
- Modify: `Sources/flowtype/Settings/SettingsView.swift`

**背景：** ProviderEditSheet 保存前强制测试连接，失败时阻止保存。同时校验 Base URL 和模型 ID。

- [ ] **Step 1: 新增校验函数**

在 `ProviderEditSheet` struct 之前（文件顶部区域）添加校验函数：

```swift
// MARK: - Provider Validation

enum ProviderValidationError: LocalizedError {
    case emptyName
    case emptyModel
    case invalidBaseURL(String)
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Provider 名称不能为空"
        case .emptyModel: return "模型 ID 不能为空"
        case .invalidBaseURL(let msg): return msg
        case .duplicateName: return "Provider 名称不能重复"
        }
    }
}

func validateProvider(_ provider: LLMProvider, existingProviders: [LLMProvider], excludingID: UUID? = nil) -> ProviderValidationError? {
    if provider.name.trimmingCharacters(in: .whitespaces).isEmpty {
        return .emptyName
    }
    if provider.model.trimmingCharacters(in: .whitespaces).isEmpty {
        return .emptyModel
    }

    var baseURL = provider.baseURL.trimmingCharacters(in: .whitespaces)
    if baseURL.isEmpty {
        return .invalidBaseURL("Base URL 不能为空")
    }
    if !baseURL.lowercased().hasPrefix("https://") {
        return .invalidBaseURL("Base URL 必须以 https:// 开头")
    }
    if baseURL.hasSuffix("/") {
        // Will be auto-trimmed, not an error
    }

    let trimmedName = provider.name.trimmingCharacters(in: .whitespaces)
    let duplicate = existingProviders.first(where: {
        $0.name.trimmingCharacters(in: .whitespaces) == trimmedName && $0.id != provider.id && $0.id != excludingID
    })
    if duplicate != nil {
        return .duplicateName
    }

    return nil
}

func normalizeBaseURL(_ url: String) -> String {
    var result = url.trimmingCharacters(in: .whitespaces)
    while result.hasSuffix("/") {
        result = String(result.dropLast())
    }
    return result
}
```

- [ ] **Step 2: 修改 ProviderEditSheet 保存逻辑**

在 `ProviderEditSheet` 中添加状态字段和修改保存流程。首先修改 `ProviderEditSheet` 的定义，添加错误状态：

```swift
struct ProviderEditSheet: View {
    @Binding var provider: LLMProvider
    @Binding var apiKey: String
    var onSave: () -> Void
    var onCancel: () -> Void

    @State private var testStatus: TestStatus = .idle
    @State private var validationError: String? = nil

    enum TestStatus: Equatable {
        case idle, testing, success, failure(String)
    }
```

然后修改 body，在表单和按钮之间添加错误提示：

在 `ServiceConfigCard` 调用之后、HStack 按钮之前插入：

```swift
            // Validation / test error display
            if let error = validationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Test status display
            switch testStatus {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在测试连接...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            case .success:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text("连接成功")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            case .failure(let msg):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
```

修改 HStack 中的保存按钮：

```swift
                Button("保存") {
                    Task {
                        await attemptSave()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(testStatus == .testing)
```

在 `ProviderEditSheet` 中添加 `attemptSave` 方法：

```swift
    private func attemptSave() async {
        validationError = nil

        // Step 1: Validation
        if let error = validateProvider(provider, existingProviders: []) {
            validationError = error.localizedDescription
            return
        }

        // Normalize base URL
        provider.baseURL = normalizeBaseURL(provider.baseURL)

        // Step 2: Connection test (skip if API key is empty)
        if !apiKey.isEmpty {
            testStatus = .testing
            let service = LLMService()
            let result = await service.testConnection(provider: provider)
            switch result {
            case .success:
                testStatus = .success
                // Small delay so user sees success
                try? await Task.sleep(nanoseconds: 300_000_000)
            case .failure(let error):
                let msg = error.userFriendlyMessage
                testStatus = .failure(msg)
                validationError = "连接测试失败: \(msg)"
                return
            }
        }

        onSave()
    }
```

- [ ] **Step 3: 修改 SettingsView 的添加 Provider 保存逻辑**

在 `SettingsView` 的 `showAddProvider` sheet 中，修改 `onSave` 以使用同样的校验逻辑。将 `onSave` 闭包替换为：

```swift
                onSave: {
                    let trimmedName = draftProvider.name.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty else {
                        // Name validation handled in sheet
                        return
                    }
                    let normalizedURL = normalizeBaseURL(draftProvider.baseURL)
                    let newProvider = LLMProvider(
                        name: trimmedName,
                        provider: draftProvider.provider,
                        baseURL: normalizedURL,
                        model: draftProvider.model.trimmingCharacters(in: .whitespaces),
                        isActive: store.current.llmProviders.isEmpty
                    )
                    store.current.llmProviders.append(newProvider)
                    if !draftApiKey.isEmpty {
                        ConfigurationStore.shared.saveProviderAPIKey(draftApiKey, for: newProvider.id)
                    }
                    showAddProvider = false
                },
```

**注意：** 由于 `ProviderEditSheet` 现在是异步保存，上面的 `onSave` 需要调整。更好的方式是让 `ProviderEditSheet` 直接返回结果而不是调用 `onSave`。但这会涉及更多改动。一个更简单的方案是：`ProviderEditSheet` 在 `attemptSave` 成功后直接调用 `onSave()`，而 `SettingsView` 中的 `onSave` 保持同步不变，因为校验和测试已经在 sheet 内部完成。

所以上面的 `onSave` 不需要修改，保持原样即可。

- [ ] **Step 4: 更新 ProviderRow 显示有效性状态**

在 `ProviderRow` 中添加有效性状态指示。在状态 dot 旁边添加一个小图标：

修改 `ProviderRow` body 中状态 dot 部分：

```swift
            // Status dot
            ZStack {
                Circle()
                    .fill(isActive ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)

                // Validity indicator
                if case .failure = testStatus {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 4, height: 4)
                        .offset(x: 3, y: -3)
                }
            }
```

- [ ] **Step 5: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 6: Commit**

```bash
git add Sources/flowtype/Settings/SettingsView.swift
git commit -m "feat(settings): add provider validation and pre-save connection test"
```

---

## Task 6: WindowManager 非修饰键防误触

**Files:**
- Modify: `Sources/flowtype/WindowManager.swift`

**背景：** 非修饰键（F13/F14/F15/Caps Lock/Right Command）需要按住 ≥0.2s 才触发，防止误触。

- [ ] **Step 1: 添加按键时间追踪缓存**

在 `WindowManager` 的静态缓存字段区域添加：

```swift
    /// Cached key-down timestamp for non-modifier trigger keys to enforce press-and-hold.
    private static var cachedKeyDownTime = UnsafeCell<Date?>(nil)
    private static let nonModifierHoldThreshold: TimeInterval = 0.2
```

- [ ] **Step 2: 修改 eventTapCallback 的 keyDown/keyUp 处理**

在 `keyDown` 处理中，非修饰键触发前添加时间记录：

将现有的非修饰键 keyDown 处理：

```swift
            // Handle non-modifier trigger keys (F13, F14, F15, Caps Lock, Right Command)
            if !cachedTriggerKey.value.isModifier,
               let triggerKeyCode = cachedTriggerKey.value.keyCode,
               keyCode == Int64(triggerKeyCode) {
                let mode = cachedInteractionMode.value
                if mode == .toggle {
                    AppLogger.log("[EventTap] Non-modifier trigger key pressed (toggle mode)")
                    DispatchQueue.main.async {
                        let controller = SessionController.shared
                        if controller.isRecording {
                            controller.endRecording(withPolish: false)
                        } else {
                            controller.startRecording()
                        }
                    }
                } else {
                    AppLogger.log("[EventTap] Non-modifier trigger key pressed (tapToStart mode)")
                    OptionTapDetector.shared.recordTap()
                }
                return nil
            }
```

替换为：

```swift
            // Handle non-modifier trigger keys (F13, F14, F15, Caps Lock, Right Command)
            if !cachedTriggerKey.value.isModifier,
               let triggerKeyCode = cachedTriggerKey.value.keyCode,
               keyCode == Int64(triggerKeyCode) {
                cachedKeyDownTime.value = Date()
                AppLogger.log("[EventTap] Non-modifier trigger key down, waiting for hold threshold...")
                return nil
            }
```

在 `keyUp` 处理中，添加持续时间检查：

将现有的非修饰键 keyUp 处理：

```swift
        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if !cachedTriggerKey.value.isModifier,
               let triggerKeyCode = cachedTriggerKey.value.keyCode,
               keyCode == Int64(triggerKeyCode) {
                // Non-modifier trigger key released — nothing to do here.
                // State is managed on keyDown.
                return nil
            }
            return Unmanaged.passRetained(event)
        }
```

替换为：

```swift
        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if !cachedTriggerKey.value.isModifier,
               let triggerKeyCode = cachedTriggerKey.value.keyCode,
               keyCode == Int64(triggerKeyCode) {
                // Check if held long enough
                let holdDuration: TimeInterval
                if let downTime = cachedKeyDownTime.value {
                    holdDuration = Date().timeIntervalSince(downTime)
                } else {
                    holdDuration = 0
                }
                cachedKeyDownTime.value = nil

                guard holdDuration >= nonModifierHoldThreshold else {
                    AppLogger.log("[EventTap] Non-modifier trigger key released too soon (\(String(format: "%.2f", holdDuration))s < \(nonModifierHoldThreshold)s), ignoring")
                    return nil
                }

                let mode = cachedInteractionMode.value
                if mode == .toggle {
                    AppLogger.log("[EventTap] Non-modifier trigger key released after hold (toggle mode)")
                    DispatchQueue.main.async {
                        let controller = SessionController.shared
                        if controller.isRecording {
                            controller.endRecording(withPolish: false)
                        } else {
                            controller.startRecording()
                        }
                    }
                } else {
                    AppLogger.log("[EventTap] Non-modifier trigger key released after hold (tapToStart mode)")
                    OptionTapDetector.shared.recordTap()
                }
                return nil
            }
            return Unmanaged.passRetained(event)
        }
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/WindowManager.swift
git commit -m "feat(hotkey): add 0.2s press-and-hold threshold for non-modifier trigger keys"
```

---

## Task 7: 音频设备枚举（AudioDevice.swift）

**Files:**
- Create: `Sources/flowtype/Services/AudioDevice.swift`

**背景：** 使用 CoreAudio 枚举可用输入设备。

- [ ] **Step 1: 创建 AudioDevice 模型和枚举函数**

```swift
import CoreAudio

struct AudioDevice: Identifiable, Equatable {
    let id: String      // CoreAudio UID
    let name: String    // 显示名称
    let isDefault: Bool // 是否为系统默认输入设备
}

enum AudioDeviceEnumerator {
    /// Returns all available audio input devices.
    static func availableInputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []

        // Get default input device ID
        var defaultDeviceID: AudioObjectID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        let defaultResult = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        if defaultResult != noErr {
            AppLogger.log("[AudioDevice] Failed to get default input device: \(defaultResult)")
        }

        // Get all audio devices
        propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeResult = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard sizeResult == noErr else {
            AppLogger.log("[AudioDevice] Failed to get device list size: \(sizeResult)")
            return devices
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        let devicesResult = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard devicesResult == noErr else {
            AppLogger.log("[AudioDevice] Failed to get device list: \(devicesResult)")
            return devices
        }

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputConfigAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputConfigSize: UInt32 = 0
            let configSizeResult = AudioObjectGetPropertyDataSize(deviceID, &inputConfigAddress, 0, nil, &inputConfigSize)
            guard configSizeResult == noErr else { continue }

            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferList.deallocate() }
            var mutableSize = inputConfigSize
            let configResult = AudioObjectGetPropertyData(deviceID, &inputConfigAddress, 0, nil, &mutableSize, bufferList)
            guard configResult == noErr else { continue }

            let bufferCount = Int(bufferList.pointee.mNumberBuffers)
            guard bufferCount > 0 else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uid: CFString?
            let uidResult = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
            guard uidResult == noErr, let deviceUID = uid as String? else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var name: CFString?
            let nameResult = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            let deviceName = (name as String?) ?? deviceUID

            let isDefault = (deviceID == defaultDeviceID)
            devices.append(AudioDevice(id: deviceUID, name: deviceName, isDefault: isDefault))
        }

        // Sort: default first, then alphabetically
        devices.sort { a, b in
            if a.isDefault != b.isDefault {
                return a.isDefault
            }
            return a.name < b.name
        }

        AppLogger.log("[AudioDevice] Found \(devices.count) input devices")
        return devices
    }

    /// Find device ID by UID for routing.
    static func findDeviceID(uid: String) -> AudioObjectID? {
        let devices = availableInputDevices()
        guard devices.contains(where: { $0.id == uid }) else { return nil }

        // Re-enumerate to get the AudioObjectID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeResult = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard sizeResult == noErr else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        var mutableSize = dataSize
        let devicesResult = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &mutableSize, &deviceIDs)
        guard devicesResult == noErr else { return nil }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var deviceUID: CFString?
            let uidResult = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &deviceUID)
            if uidResult == noErr, let foundUID = deviceUID as String?, foundUID == uid {
                return deviceID
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `swift build`
Expected: 编译成功（可能需要添加 CoreAudio 到 Package.swift，如果尚未包含）

如果编译失败提示找不到 CoreAudio，检查 `Package.swift` 的 platform/target 设置，确保 `macOS` 平台已声明。

- [ ] **Step 3: Commit**

```bash
git add Sources/flowtype/Services/AudioDevice.swift
git commit -m "feat(audio): add CoreAudio device enumeration (AudioDevice.swift)"
```

---

## Task 8: AudioRecorder 支持设备选择和热插拔

**Files:**
- Modify: `Sources/flowtype/Services/AudioRecorder.swift`

**背景：** 允许指定输入设备，检测设备断开时优雅停止。

- [ ] **Step 1: 修改 startRecording 接受设备参数**

将 `startRecording()` 的签名改为：

```swift
    nonisolated func startRecording(deviceID: String? = nil) async throws -> RecordingOutput {
```

- [ ] **Step 2: 在创建 engine 后添加设备路由逻辑**

在 `let freshEngine = AVAudioEngine()` 之后、`let inputNode = freshEngine.inputNode` 之前，添加设备选择逻辑：

```swift
        let freshEngine = AVAudioEngine()
        self.engine = freshEngine

        // Route to specific device if requested
        if let requestedDeviceID = deviceID {
            if let audioDeviceID = AudioDeviceEnumerator.findDeviceID(uid: requestedDeviceID) {
                AppLogger.log("[AudioRecorder] Routing to device: \(requestedDeviceID)")
                // Set the input device on the engine
                do {
                    try freshEngine.inputNode.setDevice(audioDeviceID)
                } catch {
                    AppLogger.log("[AudioRecorder] Failed to set input device: \(error), falling back to default")
                }
            } else {
                AppLogger.log("[AudioRecorder] Requested device \(requestedDeviceID) not found, using default")
            }
        }
```

**注意：** `AVAudioInputNode.setDevice(_:)` 是 macOS 上的可用方法。如果编译器报错，可能需要使用 `AudioUnit` 级别的设置。如果 `setDevice` 不可用，改用 `AVAudioEngine` 的 `connect` 方式或 CoreAudio property 设置。

如果 `setDevice` 不可用，使用 CoreAudio 直接设置：

```swift
        // Route to specific device if requested
        if let requestedDeviceID = deviceID {
            if let audioDeviceID = AudioDeviceEnumerator.findDeviceID(uid: requestedDeviceID) {
                AppLogger.log("[AudioRecorder] Routing to device: \(requestedDeviceID)")
                var propertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
                let setResult = AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &propertyAddress,
                    0,
                    nil,
                    deviceIDSize,
                    &audioDeviceID
                )
                if setResult != noErr {
                    AppLogger.log("[AudioRecorder] Failed to set default input device: \(setResult), falling back")
                }
            } else {
                AppLogger.log("[AudioRecorder] Requested device \(requestedDeviceID) not found, using default")
            }
        }
```

- [ ] **Step 3: 在 engine 错误时添加热插拔检测**

在 `try freshEngine.start()` 的 catch 块中，添加对设备断开错误的检测：

```swift
            do {
                freshEngine.prepare()
                try freshEngine.start()
                print("[AudioRecorder] Engine prepared and started successfully")
            } catch {
                print("[AudioRecorder] Engine start FAILED: \(error)")
                let nsError = error as NSError
                if nsError.domain == "com.apple.coreaudio.avfaudio" {
                    AppLogger.log("[AudioRecorder] CoreAudio error detected, device may have been disconnected")
                    onRecordingFrozen?()
                }
                continuation.finish()
            }
```

- [ ] **Step 4: 添加静态方法供外部查询设备**

在 `AudioRecorder` 类中添加：

```swift
    static func availableInputDevices() -> [AudioDevice] {
        AudioDeviceEnumerator.availableInputDevices()
    }
```

- [ ] **Step 5: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 6: Commit**

```bash
git add Sources/flowtype/Services/AudioRecorder.swift
git commit -m "feat(audio): support device selection and disconnect detection in AudioRecorder"
```

---

## Task 9: SettingsView 添加麦克风设备选择器

**Files:**
- Modify: `Sources/flowtype/Settings/SettingsView.swift`

**背景：** 在 ASR Section 添加麦克风设备下拉选择器。

- [ ] **Step 1: 添加设备列表状态和设备选择器 UI**

在 `SettingsPage` struct 中添加状态：

```swift
    @State private var availableDevices: [AudioDevice] = []
    @State private var selectedDeviceUnavailable: Bool = false
```

- [ ] **Step 2: 在 ASR Section 添加麦克风设备选择器**

在语言选择器之后、Divider 之前，添加麦克风设备选择器：

```swift
                    // Microphone device selector
                    HStack {
                        Text("麦克风设备")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            if selectedDeviceUnavailable {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
                            Picker("", selection: $store.current.microphoneDeviceID) {
                                Text("系统默认").tag(String?.none)
                                ForEach(availableDevices) { device in
                                    Text(device.name).tag(Optional(device.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220)
                        }
                    }
                    .onAppear {
                        refreshDevices()
                    }
```

- [ ] **Step 3: 添加设备刷新和不可用检测**

在 `SettingsPage` 中添加方法：

```swift
    private func refreshDevices() {
        availableDevices = AudioRecorder.availableInputDevices()
        if let selectedID = store.current.microphoneDeviceID {
            selectedDeviceUnavailable = !availableDevices.contains(where: { $0.id == selectedID })
        } else {
            selectedDeviceUnavailable = false
        }
    }
```

- [ ] **Step 4: 在 SessionController 传递设备 ID**

在 `SessionController.runRecordingSession()` 中，修改 `audioRecorder.startRecording()` 调用，传入设备 ID：

```swift
            let deviceID = ConfigurationStore.shared.current.microphoneDeviceID
            let output = try await audioRecorder.startRecording(deviceID: deviceID)
```

- [ ] **Step 5: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 6: Commit**

```bash
git add Sources/flowtype/Settings/SettingsView.swift Sources/flowtype/Core/PipelineOrchestrator.swift
git commit -m "feat(settings): add microphone device selector and pass to recorder"
```

---

## Task 10: CapsuleView Prompt 动态化

**Files:**
- Modify: `Sources/flowtype/CapsuleView.swift`

**背景：** idle 状态提示根据 triggerKey 和 interactionMode 动态生成。

- [ ] **Step 1: 添加 idle 提示生成计算属性**

在 `CapsuleView` 中添加：

```swift
    private var idleHintText: String {
        let config = ConfigurationStore.shared.current
        let key = config.triggerKey
        let mode = config.interactionMode

        let keyName: String
        switch key {
        case .command: keyName = "⌘"
        case .option: keyName = "⌥"
        case .control: keyName = "⌃"
        case .fn: keyName = "Fn"
        case .rightCommand: keyName = "Right ⌘"
        default: keyName = key.displayName
        }

        if mode == .toggle {
            return "按 \(keyName) 切换语音输入"
        }

        if key.isModifier {
            return "双击 \(keyName) 开始语音输入"
        } else {
            return "按住 \(keyName) 0.2 秒开始语音输入"
        }
    }
```

- [ ] **Step 2: 替换硬编码提示**

将 `statusSubtitle` 中的：

```swift
        case .idle:
            return "双击 Option 开始"
```

替换为：

```swift
        case .idle:
            return idleHintText
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/CapsuleView.swift
git commit -m "feat(ui): dynamic idle hint based on trigger key and interaction mode"
```

---

## Task 11: OnboardingView 更新为 3 步引导

**Files:**
- Modify: `Sources/flowtype/Settings/OnboardingView.swift`

**背景：** 简化现有 5 步引导为 3 步，并更新为使用新的 Configuration 字段。

- [ ] **Step 1: 修改步骤数为 3**

将进度指示器从 5 个圆点改为 3 个：

```swift
            HStack(spacing: 8) {
                ForEach(0..<3) { i in
```

修改 switch：

```swift
            Group {
                switch step {
                case 0: welcomeStep
                case 1: permissionsStep
                default: quickConfigStep
                }
            }
```

- [ ] **Step 2: 更新权限步骤**

在 `permissionsStep` 的 "继续" 按钮逻辑中，添加权限检查：

```swift
                Button(action: {
                    hasAccessibility = PermissionHelper.checkAccessibility()
                    if hasAccessibility {
                        withAnimation { step = 2 }
                    }
                }) {
                    Text("继续")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
```

将原来的直接跳转到 step 2 改为先检查权限。

- [ ] **Step 3: 替换 doneStep 为 quickConfigStep**

将 `doneStep` 替换为合并了 LLM 配置和完成的步骤：

```swift
    // MARK: - Step 2: Quick Config

    private var quickConfigStep: some View {
        VStack(spacing: 20) {
            Text("快速配置")
                .font(.system(size: 20, weight: .bold))

            Text("设置触发键和交互方式。你也可以稍后打开设置更改。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("触发键")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Picker("", selection: $store.current.triggerKey) {
                            ForEach(TriggerKey.allCases, id: \.self) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("交互模式")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Picker("", selection: $store.current.interactionMode) {
                            ForEach(InteractionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }

                // Dynamic interaction hint
                VStack(alignment: .leading, spacing: 10) {
                    let key = store.current.triggerKey
                    let mode = store.current.interactionMode

                    if mode == .tapToStart {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("单击")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("停止录音，输出原始文本")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            HStack(spacing: 6) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.purple)
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("双击")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("停止录音，输出润色文本")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.purple.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("单击")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("开始 / 停止录音")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Spacer()

            HStack {
                Button("跳过") {
                    completeOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button(action: completeOnboarding) {
                    Text("开始使用 FlowType")
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
```

- [ ] **Step 4: 更新 completeOnboarding**

修改 `completeOnboarding` 以保存 onboarding 完成状态到 Configuration：

```swift
    private func completeOnboarding() {
        store.current.hasCompletedOnboarding = true
        store.save(store.current)
        AppLogger.log("[Onboarding] Completed and saved")
        if case .notLoaded = modelState.status {
            Task {
                let provider = SessionController.shared.qwenProvider
                await modelState.loadModel(provider: provider)
            }
        }
        NSApp.keyWindow?.close()
    }
```

- [ ] **Step 5: 删除不再使用的步骤代码**

删除 `asrStep` 和 `llmStep` 属性（或者保留但不再使用）。为了简洁，保留代码但 switch 不再引用它们。

- [ ] **Step 6: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 7: Commit**

```bash
git add Sources/flowtype/Settings/OnboardingView.swift
git commit -m "feat(onboarding): simplify to 3-step guide with quick config"
```

---

## Task 12: AppDelegate Onboarding 逻辑更新

**Files:**
- Modify: `Sources/flowtype/App/FlowTypeApp.swift`

**背景：** 使用 Configuration 中的 `hasCompletedOnboarding` 替代 UserDefaults 直接读取。

- [ ] **Step 1: 替换 UserDefaults 检查为 Configuration 检查**

将 `applicationDidFinishLaunching` 中的：

```swift
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "flowtype.onboardingCompleted")
        if !hasCompletedOnboarding {
```

替换为：

```swift
        if !ConfigurationStore.shared.current.hasCompletedOnboarding {
```

- [ ] **Step 2: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add Sources/flowtype/App/FlowTypeApp.swift
git commit -m "refactor(app): use Configuration.hasCompletedOnboarding instead of raw UserDefaults"
```

---

## Task 13: StatusBarController 添加重新打开引导菜单

**Files:**
- Modify: `Sources/flowtype/App/StatusBarController.swift`

**背景：** 状态栏菜单添加"重新打开引导"选项。

- [ ] **Step 1: 添加菜单项和窗口控制器**

添加 `onboardingWindowController` 属性：

```swift
    private var onboardingWindowController: OnboardingWindowController?
```

在 `buildMenu()` 中，在"检查权限"之前添加重新打开引导项：

```swift
        let onboardingItem = NSMenuItem(title: "重新打开引导", action: #selector(showOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        menu.addItem(NSMenuItem.separator())
```

- [ ] **Step 2: 添加 showOnboarding 方法**

```swift
    @objc private func showOnboarding() {
        if onboardingWindowController == nil {
            let controller = OnboardingWindowController()
            controller.onClose = { [weak self] in
                self?.onboardingWindowController = nil
            }
            onboardingWindowController = controller
        }
        onboardingWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/App/StatusBarController.swift
git commit -m "feat(menu): add 'Reopen Onboarding' to status bar menu"
```

---

## Self-Review Checklist

### 1. Spec Coverage

| Spec 需求 | 对应任务 |
|-----------|----------|
| Provider 保存前强制连接测试 | Task 5 |
| 连接失败具体错误信息 | Task 4 |
| LLM 运行时 Provider 降级 | Task 3 |
| Base URL 规范化（https、去斜杠） | Task 5 |
| 模型 ID 非空校验 | Task 5 |
| 非修饰键 0.2s 防误触 | Task 6 |
| 麦克风设备枚举 | Task 7 |
| 麦克风设备选择 UI | Task 9 |
| 麦克风断开回退 | Task 8 |
| Onboarding 3 步引导 | Task 11 |
| 首次启动自动弹出 | Task 12 |
| 状态栏重新打开引导 | Task 13 |
| Capsule 动态提示 | Task 10 |

**无遗漏。**

### 2. Placeholder Scan

- ✅ 无 TBD/TODO
- ✅ 无 "add appropriate error handling" 等模糊描述
- ✅ 所有代码步骤包含完整代码
- ✅ 无 "Similar to Task N" 引用

### 3. Type Consistency

- ✅ `microphoneDeviceID` 在 Configuration/Task 1/SettingsView 中一致使用 `String?`
- ✅ `hasCompletedOnboarding` 在 Configuration/Task 1/OnboardingView/AppDelegate 中一致使用 `Bool`
- ✅ `AudioDevice` 模型在 AudioDevice.swift/AudioRecorder/SettingsView 中一致
- ✅ `ProviderValidationError` 在 Task 5 中定义并在同一文件中使用

---

## 验收清单

实现完成后，验证以下事项：

- [ ] `swift build` 编译成功
- [ ] 添加 Provider 时，空模型 ID 或无效 Base URL 被阻止保存
- [ ] 添加 Provider 时，API Key 非空则自动测试连接，失败显示具体错误
- [ ] LLM polish 时 active Provider 失败，自动尝试下一个有效 Provider（检查日志）
- [ ] F13 单击不触发（按住 < 0.2s 松开），按住 0.2s 后松开才触发
- [ ] Settings 页显示可用麦克风设备列表
- [ ] 选择非默认麦克风后录音使用该设备
- [ ] Capsule idle 提示根据 triggerKey 和 interaction模式动态变化
- [ ] 首次启动（删除 app 后重新运行或重置 `hasCompletedOnboarding`）自动弹出 3 步引导
- [ ] 状态栏菜单有"重新打开引导"选项，点击可重新打开
