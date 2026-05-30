# FlowType 模块 1 + 模块 2 设计文档

**Date:** 2026-05-30  
**Scope:** 多 Provider LLM 稳定性完善 + 待完善功能（麦克风设备选择、首次引导、Prompt 动态化）  
**Status:** Draft (Pending Review)

---

## 1. 背景

FlowType 是一个 macOS 语音输入应用。当前已实现多 Provider LLM 配置、自定义热键、交互模式等 P0 功能，但在稳定性、设备支持和用户体验上仍有完善空间。

本次设计覆盖：
- **模块 1：** 多 Provider LLM 配置的稳定性加固
- **模块 2a：** 麦克风设备选择
- **模块 2b：** 首次使用引导（Onboarding）
- **模块 2c：** Capsule 提示词动态化

---

## 2. 模块 1：多 Provider LLM 稳定性完善

### 2.1 连接测试增强

**当前问题：**
Provider 可以保存但配置可能无效（错误的 baseURL、过期 API Key），用户只有在实际使用时才发现。

**设计：**
1. **保存前强制测试：** `ProviderEditSheet` 点击"保存"时，先执行 `LLMService.testConnection()`，只有成功才允许保存。
2. **失败提示优化：** 连接失败时显示具体错误信息：
   - HTTP 401/403 → "API Key 无效或已过期"
   - HTTP 404 → "模型 ID 不存在"
   - HTTP 5xx → "服务商接口异常"
   - 网络超时 → "连接超时，请检查网络或 Base URL"
   - DNS 失败 → "无法解析 Base URL"
3. **跳过测试选项：** 高级用户可以通过按住 Option 键点击保存来跳过测试（防止服务商临时不可用导致无法保存）。

**UI 改动：**
- `ProviderEditSheet` 保存按钮在测试期间显示加载状态
- 测试失败时在表单底部显示红色错误提示卡片
- 成功时显示绿色"连接成功"提示

### 2.2 运行时 Provider 降级

**当前问题：**
LLM polish 时只使用 active Provider，如果该 Provider 失败则整个 polish 流程失败。

**设计：**
1. **Fallback 链：** `LLMService.resolveActiveProvider()` 扩展为返回按优先级排序的 Provider 列表（active 优先，其次是列表中第一个有效 Provider）。
2. **自动切换：** 当 active Provider 调用失败时，自动尝试列表中的下一个有效 Provider。
3. **失败上限：** 最多尝试 2 个 Provider（避免无限重试导致用户等待过久）。
4. **日志记录：** 每次降级都在 diagnostic.log 中记录原因和切换目标。

**实现位置：**
- `LLMService.makeStream()` 中的 `resolveActiveProvider` 逻辑
- `LLMService.polishText()` 添加重试循环

### 2.3 配置校验

**设计：**
1. **Base URL 规范化：**
   - 必须以 `https://` 开头（不允许 http）
   - 不能以 `/` 结尾（自动 trim）
   - 必须包含 `/v1` 或 `/openai/deployments`（OpenAI/Azure 标准路径）
2. **模型 ID 校验：**
   - 非空
   - 不能包含空格（trim 后检查）
3. **名称唯一性：**
   - 同一列表内 Provider `name` 不能重复

**实现位置：**
- `ProviderEditSheet.onSave` 中执行校验，失败时阻止保存并提示

### 2.4 热键稳定性完善

**当前问题：**
非修饰键（F13/F14/F15/Caps Lock/Right Command）在 `tapToStart` 模式下，单次按键就可能误触发（没有修饰键的"按住"语义）。

**设计：**
1. **非修饰键防误触：** 对于非修饰键触发器，要求按键持续时间 ≥ 0.2 秒才算有效触发。
2. **按键时间追踪：** 在 `eventTapCallback` 的 `keyDown` 时记录时间戳，`keyUp` 时计算持续时间，只有 ≥ 0.2s 才调用 `OptionTapDetector.recordTap()`。
3. **修饰键保持现状：** 修饰键（Command/Option/Control/Fn）通过 `flagsChanged` 检测，保持现有的 0.35s 双击窗口逻辑。

**实现位置：**
- `WindowManager.eventTapCallback` 中的 `keyDown` / `keyUp` 处理

---

## 3. 模块 2a：麦克风设备选择

### 3.1 设备枚举

**设计：**
1. 使用 `AVAudioEngine.inputNode` 和 `AVAudioSession` 或 CoreAudio `AudioObject` API 枚举所有可用输入设备。
2. 获取设备名称和唯一标识符（`deviceID`）。
3. 在 `AudioRecorder` 中新增静态方法 `availableInputDevices()` → `[AudioDevice]`。

```swift
struct AudioDevice: Identifiable, Equatable {
    let id: String      // 唯一标识符（如 CoreAudio 的 UID）
    let name: String    // 显示名称（如 "MacBook Pro 麦克风"）
    let isDefault: Bool // 是否为系统默认
}
```

### 3.2 设备选择

**设计：**
1. `Configuration` 新增 `microphoneDeviceID: String? = nil`（nil 表示系统默认）。
2. `SettingsView` 在 ASR Section 添加"麦克风设备"下拉选择器：
   - 首选项："系统默认"
   - 其余：按名称字母排序的设备列表
3. 已选择但当前不可用的设备显示橙色警告标记。

### 3.3 录音路由

**设计：**
1. `AudioRecorder.startRecording(deviceID: String? = nil)` 接受可选设备 ID。
2. 如果指定了设备 ID，通过 `AVAudioEngine` 的 `inputNode` + `AudioUnit` 设置或 CoreAudio 路由到指定设备。
3. 如果设备不存在（被拔出），回退到系统默认设备，并在 diagnostic.log 中记录。

### 3.4 热插拔处理

**设计：**
1. 在录音过程中，如果当前设备被断开（音频引擎报错或采样率变化）， gracefully 停止录音。
2. 通过 `SessionController.showError()` 显示："麦克风已断开，录音已停止。"
3. 下次录音自动回退到默认设备。

**实现位置：**
- `AudioRecorder` 新增设备枚举和选择逻辑
- `SettingsView` ASR Section 添加设备选择器
- `SessionController.runRecordingSession()` 传递设备 ID

---

## 4. 模块 2b：首次引导（Onboarding）

### 4.1 触发条件

**设计：**
1. `UserDefaults` 键 `hasCompletedOnboarding`（Bool，默认 false）。
2. `FlowTypeApp` 启动时检查：如果为 false，自动弹出 `OnboardingWindowController`。
3. Onboarding 完成后设置为 true。

### 4.2 引导步骤

参考现有 `OnboardingView`，设计 3 步引导：

**Step 1: 欢迎使用**
- 标题："欢迎使用 FlowType"
- 内容：简要介绍应用用途（语音输入 → AI 润色 → 自动注入）
- 按钮："下一步"

**Step 2: 权限申请**
- 辅助功能权限：解释为什么需要（监听全局触发键）
  - 显示当前权限状态（已开启 / 未开启）
  - 未开启时显示"打开系统设置"按钮
- 麦克风权限：解释为什么需要（语音识别）
  - 显示当前权限状态
  - 未开启时显示"申请权限"按钮
- 两个权限都开启后，"下一步"按钮变为可用

**Step 3: 快速配置**
- 触发键选择（复用现有的 Picker）
- 交互模式说明（根据选择动态显示操作图示）
- LLM Provider 快速配置（可选，可以跳过）
- 按钮："开始使用"

### 4.3 跳过机制

**设计：**
- 每一步都可以点击"跳过引导"，直接设置 `hasCompletedOnboarding = true`。
- 引导窗口可以通过左上角关闭按钮关闭，关闭时视为跳过。

### 4.4 后续重新打开

**设计：**
- 状态栏菜单添加"重新打开引导"选项，方便用户随时回顾。

**实现位置：**
- `FlowTypeApp` 启动逻辑
- `OnboardingView` 内容更新
- `StatusBarController` 添加菜单项

---

## 5. 模块 2c：Prompt 动态化

### 5.1 问题

`CapsuleView` idle 状态硬编码显示"双击 Option 开始"，不反映用户实际配置的触发键和交互模式。

### 5.2 设计

**动态提示生成规则：**

| triggerKey | interactionMode | 提示文案 |
|-----------|----------------|---------|
| Command | tapToStart | 双击 ⌘ 开始语音输入 |
| Option | tapToStart | 双击 ⌥ 开始语音输入 |
| Control | tapToStart | 双击 ⌃ 开始语音输入 |
| Fn | tapToStart | 双击 Fn 开始语音输入 |
| F13 | tapToStart | 双击 F13 开始语音输入 |
| F14 | tapToStart | 双击 F14 开始语音输入 |
| F15 | tapToStart | 双击 F15 开始语音输入 |
| Caps Lock | tapToStart | 双击 Caps Lock 开始语音输入 |
| Right Command | tapToStart | 双击 Right ⌘ 开始语音输入 |
| 任意 | toggle | 按 {key} 切换语音输入 |

**非修饰键补充说明：**
- 非修饰键在 `tapToStart` 模式下，由于有 press-and-hold 防误触，提示文案应增加"按住 0.2 秒"：
  - "按住 F13 0.2 秒后松开，开始语音输入"

**实现位置：**
- `CapsuleView` 添加计算属性 `idleHintText`
- 根据 `ConfigurationStore.shared.current.triggerKey` 和 `interactionMode` 动态生成
- 监听配置变化，实时更新

---

## 6. 数据模型变更

### 6.1 Configuration 新增字段

```swift
struct Configuration: Codable, Equatable {
    // ... existing fields ...

    // Module 2a: Microphone device selection
    var microphoneDeviceID: String? = nil

    // Module 2b: Onboarding
    var hasCompletedOnboarding: Bool = false
}
```

### 6.2 向后兼容

- `microphoneDeviceID` 和 `hasCompletedOnboarding` 在 `init(from decoder:)` 中使用默认值，不影响旧配置。

---

## 7. UI 变更汇总

| 页面 | 变更 |
|------|------|
| `ProviderEditSheet` | 保存前强制连接测试；失败提示；Base URL / 模型 ID 校验 |
| `ProviderRow` | 显示 Provider 有效性状态（绿色/红色圆点） |
| `SettingsView` ASR Section | 新增"麦克风设备"下拉选择器 |
| `CapsuleView` | idle 状态提示动态化 |
| `OnboardingView` | 3 步引导：欢迎 → 权限 → 快速配置 |
| 状态栏菜单 | 新增"重新打开引导"选项 |

---

## 8. 错误处理

| 场景 | 行为 |
|------|------|
| Provider 连接测试失败 | 阻止保存，显示具体错误 |
| LLM polish 时 active Provider 失败 | 自动尝试下一个有效 Provider，最多 2 次 |
| 所有 Provider 都无效 | Capsule 显示 "LLM 配置无效，使用原始文本" |
| 麦克风设备被拔出 | 停止录音，显示 "麦克风已断开" |
| 指定麦克风不存在 | 回退到默认设备，记录日志 |
| Onboarding 中用户拒绝权限 | 显示权限说明，允许继续但提示功能受限 |

---

## 9. 日志要求

所有关键操作记录到 diagnostic.log：
- Provider 连接测试结果（成功/失败及原因）
- LLM Provider 降级切换记录
- 麦克风设备切换和回退
- Onboarding 完成/跳过

---

## 10. 验收标准

- [ ] 保存 Provider 前必须测试连接，失败时阻止保存
- [ ] LLM polish 时 active Provider 失败自动降级到下一个有效 Provider
- [ ] Base URL 自动规范化（去除尾部斜杠，强制 https）
- [ ] 非修饰键触发器需要按住 0.2 秒才生效
- [ ] 设置页可以查看和选择可用麦克风设备
- [ ] 麦克风断开时录音自动停止并提示用户
- [ ] 首次启动自动弹出 Onboarding，完成后不再弹出
- [ ] Capsule idle 提示根据 triggerKey 和 interactionMode 动态显示
- [ ] 状态栏菜单可以重新打开 Onboarding
