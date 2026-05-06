# FlowType 项目文档

## 项目概述

Flowtype 是一款面向 AI 编码场景的智能语音输入法 macOS 应用。用户通过语音输入开发需求，应用将口语化的语音转换为结构化的文本指令，可直接发送给 AI 编码助手（如 Codex、Cursor、Claude Code 等）。

### 核心交互方式

| 操作 | 行为 |
|------|------|
| 双击 `Command` | 开始录音，底部出现悬浮胶囊窗口 |
| 单击 `Command`（录音中） | 结束录音，输出原始口语化文本 |
| 双击 `Command`（录音中） | 结束录音，输出 LLM 润色后的结构化文本 |

---

## 项目结构

```
Sources/flowtype/
├── App/
│   ├── FlowTypeApp.swift              # 应用入口，隐藏主窗口， accessory 模式
│   └── StatusBarController.swift      # 菜单栏图标与菜单管理
├── Core/
│   ├── AppState.swift                 # 录音状态机（idle/recording/processingASR/polishing/injecting）
│   ├── AsyncRefiner.swift             # 并行 ASR + 评分选择 + LLM 润色
│   ├── Configuration.swift            # 配置模型（API Key、Provider、触发键等）
│   ├── ConfigurationStore.swift       # 配置持久化（UserDefaults + debounce）
│   ├── EnvMigration.swift             # .env → GUI 配置的首次迁移
│   └── PipelineOrchestrator.swift     # 核心控制器：录音→ASR→润色→注入的完整流程
├── Services/
│   ├── AudioRecorder.swift            # AVAudioEngine 录音，分段 buffer 管理
│   ├── KeyboardInjector.swift         # 文本注入：粘贴模式（多行）/ 逐字模式（单行）
│   ├── LLMService.swift               # SiliconFlow SSE 流式 LLM 调用
│   └── Speech/
│       ├── ASRPostProcessor.swift     # ASR 后处理：去 filler、术语纠错、规范化
│       ├── ASRResultScorer.swift      # ASR 结果评分器（7 维度加权打分）
│       ├── AppleSpeechProvider.swift  # Apple 本地语音识别（离线，实时预览 + 兜底）
│       ├── SenseVoiceProvider.swift   # SenseVoice ASR Provider
│       ├── SiliconFlowSpeechProvider.swift # SiliconFlow API 通用 ASR 实现
│       ├── SpeechProvider.swift       # ASR Provider 协议
│       ├── SpeechRouter.swift         # Provider 路由（并行/兜底策略）
│       └── TeleSpeechProvider.swift   # TeleSpeech ASR Provider（主）
├── Settings/
│   ├── SettingsView.swift             # SwiftUI 设置面板（API Key、Provider、触发键等）
│   └── SettingsWindowController.swift # 设置窗口控制器（NSWindow）
├── UI/
│   └── AudioVisualizer.swift          # 录音时的音频波形动画
├── Utilities/
│   ├── AudioFormatConverter.swift     # PCM→WAV 转换、静音修剪、音量归一化
│   ├── DotEnv.swift                   # .env 文件解析（兼容旧版本）
│   ├── PermissionHelper.swift         # 辅助功能权限检测与引导弹窗
│   └── SegmentMerger.swift            # 多段 ASR 结果去重合并
├── CapsuleView.swift                  # 悬浮窗 UI（状态、图标、文字、实时预览）
├── FloatingPanel.swift                # 无边框悬浮面板
└── WindowManager.swift                # 全局热键监听（CGEventTap）+ 窗口管理
```

---

## 核心数据流

```
用户按下 Command
    ↓
WindowManager (CGEventTap) 检测单击/双击
    ↓
PipelineOrchestrator.toggleRecording()
    ↓
开始录音: AudioRecorder.startRecording() → RecordingOutput
    ├── amplitude stream → CapsuleView UI 动画
    ├── audio buffer → AppleSpeechProvider（实时预览文本）
    └── segment stream → 每满60s自动分段并行ASR
    ↓
用户再次按下 Command
    ↓
停止录音: AudioRecorder.stopRecording() → (segments, finalData)
    ↓
等待所有分段 ASR 完成 → AppleSpeech 本地结果兜底 → 拼接完整文本
    ↓
ASRPostProcessor.process() → 术语纠错 + filler 清洗 + 规范化
    ↓
[单击] 直接输出处理后的原始文本
[双击] LLMService.polishText() → 结构化文本 → 输出
    ↓
KeyboardInjector.insertText() → 粘贴到当前输入框
```

---

## 遇到的问题及解决方案

### 问题 1：双击 Command 无反应 / CGEventTap 创建失败

**现象**：应用启动后双击 `Command` 键没有任何反应，日志显示 `FAILED to create CGEvent tap`。

**根因**：辅助功能权限未授予，或 EventTap 被添加到 GCD 线程的 RunLoop 上导致不稳定。

**解决**：
1. 启动时通过 `PermissionHelper.checkAccessibility()` 检测权限，缺失时弹出引导对话框
2. 将 EventTap 的 RunLoop Source 添加到**主线程 RunLoop**（而非 GCD 线程），避免线程被回收：
   ```swift
   CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
   ```
3. 使用 `nonisolated(unsafe) static var cachedTriggerKey` 避免 C 回调中的 actor 隔离问题

---

### 问题 2：Swift 6 严格并发模式下的 C 回调隔离

**现象**：`CGEventTap` 的 `@convention(c)` 回调无法访问 `@MainActor` 隔离的属性。

**根因**：C 回调在非隔离线程运行，直接访问 `ConfigurationStore.shared.current.triggerKey` 会导致编译器报错或运行时静默丢弃。

**解决**：
1. 提取独立的 `OptionTapDetector` 类（`@unchecked Sendable`），专门处理双击检测逻辑
2. C 回调中使用 `Task { @MainActor in }` 显式声明在 MainActor 上执行
3. 使用 `cachedTriggerKey` 缓存触发键值，避免回调中跨 actor 访问

---

### 问题 3：macOS 麦克风权限 FourCC 枚举值陷阱

**现象**：麦克风权限请求始终被跳过，日志显示 `mic status = 1970168948`（不是预期的 0/1/2）。

**根因**：macOS 上 `AVAudioApplication.RecordPermission` 的枚举值是 **FourCC 字符码**（`undt` = 1970168948，`grnt` = 1735552628），而非 iOS 上的简单 `0/1/2`。代码中 `status.rawValue == 0` 的判断在 macOS 上永远为 false。

**解决**：直接比较枚举 case 而非 rawValue：
```swift
guard status == .undetermined else {
    return status == .granted
}
```

---

### 问题 4：TCC 隐私权限导致应用闪退

**现象**：用户授权麦克风权限后，应用秒闪退。崩溃报告显示 `SIGABRT`，`namespace=TCC`。

**根因**：`AppleSpeechProvider` 使用 `SFSpeechRecognizer` 进行本地语音识别。macOS TCC 系统在第一次访问语音识别服务时，会检查 `Info.plist` 中是否有 `NSSpeechRecognitionUsageDescription`。缺失该键会直接触发崩溃。

**解决**：在构建脚本的 `Info.plist` 模板中添加：
```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Flowtype 需要语音识别权限将语音转换为文字。</string>
```

---

### 问题 5：LLM 润色后的结构化文本注入后格式丢失

**现象**：日志中 LLM 返回了带换行、列表缩进的格式化文本，但注入到输入框后变成了一行连续文本。

**根因**：`KeyboardInjector.insertText()` 逐字符模拟键盘输入。换行符 `\n` 被当作普通 Unicode 字符发送，但多数输入框（尤其是聊天应用）将物理 Return 键识别为"发送"指令，而非插入换行。

**解决**：
- 文本含换行时，改用 **剪贴板粘贴**（Command+V）
- 粘贴保留所有格式（换行、缩进、列表符号）
- 粘贴前保存用户剪贴板内容，粘贴后自动恢复

---

### 问题 6：超过 60s 录音被强行截断

**现象**：用户长时间录音（如 46s 的测试），60s 后新数据被丢弃，只保留前 60s。

**根因**：`AudioRecorder` 使用单一 `AVAudioPCMBuffer`，容量固定为 `16000 * 60 = 960,000` 帧（60s @ 16kHz）。当 buffer 满时，后续数据直接丢弃。

**解决**：实现 **分段并发识别**：
1. 每满 60s 自动将当前 buffer 转换为 WAV，通过 `AsyncStream<Data>` 推送
2. `PipelineOrchestrator` 后台消费 segment stream，每段立即启动并行 ASR
3. 录音结束后，等待所有分段 ASR 完成，按顺序拼接结果 + 最后一段 ASR + AppleSpeech 本地兜底
4. 单击：拼接后直接输出；双击：拼接后统一润色输出

---

### 问题 7：ASR 识别结果总有重复字

**现象**：TeleSpeech 和 SenseVoice 返回的文本中频繁出现重复字，如"然然后"、"那个那个"。

**根因**：
1. 口语中确实存在重复词（"然后然后"、"那个那个"）
2. ASR 模型本身在处理连续重复音节时可能产生重复输出

**解决**（`ASRPostProcessor.swift`）：
- 连续重复字符去重（3+ 相同字符 → 1 个）
- 独立出现的 filler 词删除（"嗯"、"啊"、"那个"、"然后"）
- 基于 `tech_terms.json` 的术语大小写纠错

---

### 问题 8：ad-hoc 签名导致权限每次重建后失效

**现象**：每次 `./scripts/build-app.sh` 重新构建后，辅助功能权限失效，需要手动删除并重新添加。

**根因**：`codesign --force --deep --sign -` 是 ad-hoc 签名，每次签名会改变二进制哈希。macOS TCC 数据库以签名哈希为键，哈希变化后被视为全新应用。

**应对**：
1. 在构建脚本和 `FIRST_LAUNCH.md` 中明确提示用户
2. 在 `PermissionHelper` 中提供权限检测和一键打开系统设置的引导
3. 未来考虑接入 Apple Developer ID 证书签名

---

### 问题 9：音频链路首字/尾字截断

**现象**：录音开始的前 50-150ms 和结束前的最后一帧音频丢失，导致 ASR 首字/尾字缺失。

**根因**：
1. 缺少 `engine.prepare()`，启动到 first callback 有延迟
2. `stopRecording()` 先设 `isRecording = false` 再 `removeTap`，guard 语句丢弃了最后一帧

**解决**：
1. `installTap` 前调用 `try engine.prepare()`
2. `removeTap(onBus: 0)` 先于 `engine.stop()`，且移除 `isRecording` guard
3. `AVAudioConverter` 的 `outStatus` 从 `.haveData` 修正为 `.endOfStream`

---

## 关键设计决策

### 1. 为什么使用 CGEventTap 而不是 NSEvent 全局监视器？

`NSEvent.addGlobalMonitorForEvents` 无法捕获 modifier key（Option、Command 等）的 `flagsChanged` 事件。`CGEventTap` 是唯一能全局监听 `Command` 键状态变化的机制。

### 2. 为什么使用剪贴板粘贴而不是逐字输入？

- **保留格式**：换行、缩进、列表符号完整保留
- **避免副作用**：物理 Return 键在聊天应用中会触发"发送"
- **速度**：粘贴比逐字输入快 100 倍以上
- **补偿机制**：粘贴前保存/恢复用户原剪贴板内容

### 3. 为什么分段是 60s 而不是更短？

- **ASR 质量**：较短的音频片段缺少上下文，ASR 准确率下降
- **API 开销**：每段都需要一次 HTTP 请求，过短的段会增加延迟和成本
- **平衡**：60s 是大多数口语表达的合理上限，同时避免单段过长

### 4. 为什么并行调用两个 ASR Provider？

TeleSpeech 和 SenseVoice 各有优劣：
- **TeleSpeech**：中文标准普通话识别准确率高
- **SenseVoice**：对口语化、中英混合场景更鲁棒

通过 `ASRResultScorer` 7 维度打分（非空、长度、中文比例、filler 比例、术语命中率、重复惩罚、标点比例），自动选择最优结果。

### 5. 为什么引入 Apple 本地语音识别？

- **实时预览**：录音过程中实时显示识别文本，给用户即时反馈
- **离线兜底**：网络异常时自动回退到本地识别，保证可用性
- **隐私保护**：`requiresOnDeviceRecognition = true`，数据不出设备
- **零成本**：不消耗云端 API 配额

### 6. 为什么从 .env 配置迁移到 GUI 设置面板？

- **用户体验**：非技术用户不熟悉编辑 .env 文件
- **实时生效**：修改 API Key 或 Provider 后即时生效，无需重启
- **权限引导**：设置面板内可以集成权限检测和引导
- **持久化**：`ConfigurationStore` 使用 `UserDefaults` + JSON 序列化
- **兼容性**：`EnvMigration` 自动将旧版 .env 配置迁移到新系统

---

## 配置系统

### 配置存储

配置通过 `ConfigurationStore` 管理，持久化到 `UserDefaults`：

```swift
@MainActor
final class ConfigurationStore: ObservableObject {
    @Published var current: Configuration
    // save() 带 0.5s debounce，避免连续输入时频繁写入磁盘
}
```

### 配置项

| 配置项 | 类型 | 说明 |
|--------|------|------|
| `apiKey` | String | SiliconFlow/OpenAI API Key |
| `provider` | String | LLM Provider 标识 |
| `baseURL` | String | API 基础地址 |
| `model` | String | LLM 模型名称 |
| `triggerKey` | TriggerKey | 全局热键（.command / .option / .control / .function） |
| `asrStrategy` | ASRStrategy | 并行(parallel) / 兜底(fallback) |
| `enableFillerStrip` | Bool | 是否清洗 filler 词 |
| `enableTermCorrection` | Bool | 是否启用术语纠错 |
| `dumpAudio` | Bool | 是否导出调试音频 |

### 首次启动迁移

`EnvMigration.migrateIfNeeded()` 在应用启动时检测：
- 如果 `UserDefaults` 中无配置，尝试读取旧版 `.env` 文件
- 将 `.env` 中的配置迁移到 `ConfigurationStore`
- 迁移完成后，后续全部走 GUI 配置

---

## 状态机

```
.idle ──双击Command──► .recording ──单击Command──► .processingASR ──► .injecting ──► .idle
                     │                              │
                     │                              └── 双击Command ──► .polishing ──► .injecting ──► .idle
                     │
                     └── 双击Command（结束）──► .processingASR ──► .polishing ──► .injecting ──► .idle
```

---

## 扩展点

| 扩展 | 位置 | 说明 |
|------|------|------|
| 新 ASR Provider | 实现 `SpeechProvider` 协议 | 如 Whisper API、阿里云、科大讯飞 |
| 新 LLM Provider | 修改 `LLMService` | 更换 API endpoint 和请求格式 |
| 术语词典 | `Resources/tech_terms.json` | 添加行业/项目专属术语 |
| Filler 词 | `Resources/filler_words.json` | 添加方言或个性化 filler |
| 后处理规则 | `ASRPostProcessor` | 添加自定义文本替换逻辑 |
| 热键 | `Configuration.triggerKey` | 支持 Command/Option/Control/Function |

---

## 已知限制

1. **macOS 独占**：依赖 `CGEventTap`、`AVAudioEngine`、`NSPanel`，无法移植到 Windows/Linux
2. **Accessibility 权限**：首次运行需在系统设置中授予辅助功能权限（ad-hoc 签名每次重建后需重新添加）
3. **云端 ASR 依赖**：TeleSpeech/SenseVoice 需网络连接，离线仅支持 Apple 本地识别（准确率较低）
4. **60s 分段边界**：超长录音在 60s 边界处可能有极短的音频丢失（约 10-20ms）
5. **剪贴板覆盖风险**：粘贴注入期间（约 100ms）用户剪贴板被临时替换
6. **ad-hoc 签名限制**：每次重建后辅助功能权限失效，需手动重新添加（接入 Developer ID 可解决）
