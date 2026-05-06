# AI Coding 个人项目：Flowtype —— macOS 智能语音输入助手

## 一、个人应用展示

**Flowtype** 是我使用 AI Coding（Claude Code）独立开发的一款 macOS 原生语音输入工具。它的核心定位是"让语音输入像打字一样自然"——用户无需切换应用，通过全局快捷键即可随时开始语音输入，并将识别结果直接注入到当前光标所在的输入框中。

### 核心功能

| 功能 | 说明 |
|------|------|
| **全局热键触发** | 双击 `Command` 键开始录音，悬浮胶囊窗口出现在屏幕底部 |
| **双模式结束** | 单击结束 = 原始识别文本；双击结束 = LLM 润色后的文本 |
| **实时预览** | 录音过程中实时显示 Apple 本地语音识别的预览文字 |
| **多 ASR 引擎** | 支持 SiliconFlow、TeleSpeech、SenseVoice 等云端 API，支持并行/兜底策略 |
| **本地离线兜底** | Apple 本地语音识别（`requiresOnDeviceRecognition = true`），断网也能用 |
| **文本自动注入** | 识别结果通过模拟键盘事件直接输入到当前应用，无需复制粘贴 |
| **GUI 设置面板** | 原生 SwiftUI 设置界面，配置 API Key、Provider、触发键等 |

### 产品形态

- **无 Dock 图标**：纯菜单栏应用（`LSUIElement`），不占用 Dock 空间
- **悬浮胶囊 UI**：录音时底部显示胶囊状悬浮窗，展示波形动画和实时预览
- **菜单栏控制**：点击菜单栏图标可进入设置、查看状态、退出应用

---

## 二、开发过程中的挑战

整个开发过程持续约 2 周，期间遇到了大量 macOS 原生开发的"暗坑"。以下是我印象最深的几个技术挑战：

### 挑战 1：Swift 6 严格并发模式下的 C 回调隔离

**问题**：`CGEventTap` 的全局热键监听需要注册一个 `@convention(c)` 回调函数。这个回调在系统事件线程运行，而 `WindowManager` 是 `@MainActor` 隔离的。直接在回调中访问 `ConfigurationStore.shared.current.triggerKey` 会导致编译器报错。

**解决方案**：引入 `nonisolated(unsafe) static var cachedTriggerKey`，在 `setupGlobalHotkey()` 和 `reloadHotkey()` 时更新缓存值。C 回调只读取缓存值，避免跨 actor 访问。

```swift
private nonisolated(unsafe) static var cachedTriggerKey: TriggerKey = .command

private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    let triggerFlag = cachedTriggerKey.cgEventFlag  // 安全：只读缓存
    // ...
}
```

### 挑战 2：CGEventTap 在 GCD 线程上不稳定

**问题**：最初将 EventTap 的 RunLoop Source 添加到 `DispatchQueue.global().async { CFRunLoopRun() }` 创建的线程上。GCD 会回收空闲线程，导致 EventTap 随机停止工作。

**解决方案**：将 RunLoop Source 直接添加到**主线程 RunLoop**：

```swift
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
```

这保证了事件分发始终在主线程执行，与 `OptionTapDetector` 的 `Timer`（也在主线程）一致，避免了线程竞争。

### 挑战 3：macOS 权限系统的"四字符编码"陷阱

**问题**：应用启动后，麦克风权限请求始终被跳过。调试发现 `AVAudioApplication.shared.recordPermission.rawValue` 返回 `1970168948`，而不是文档中的 `0/1/2`。

**根因**：macOS 上 `AVAudioApplication.RecordPermission` 的枚举值是 **FourCC 字符码**（`undt` = 1970168948，`deny` = 1735552628，`grnt` = 1735552627），而 iOS 上才是简单的 `0/1/2`。代码中 `status.rawValue == 0` 的判断在 macOS 上永远为 false。

**解决方案**：直接比较枚举 case 而非 rawValue：

```swift
guard status == .undetermined else {
    return status == .granted
}
```

### 挑战 4：TCC 隐私权限导致的闪退

**问题**：用户授权麦克风权限后，应用秒闪退。崩溃报告显示：

> "This app has crashed because it attempted to access privacy-sensitive data without a usage description. The app's Info.plist must contain an NSSpeechRecognitionUsageDescription key."

**根因**：`AppleSpeechProvider` 使用了 `SFSpeechRecognizer` 进行本地语音识别。macOS TCC（透明度、同意和控制）系统在第一次访问语音识别服务时，会检查 `Info.plist` 中是否有 `NSSpeechRecognitionUsageDescription`。缺失该键会直接触发 `SIGABRT`。

**解决方案**：在构建脚本的 Info.plist 模板中添加：

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Flowtype 需要语音识别权限将语音转换为文字。</string>
```

### 挑战 5：ad-hoc 签名与权限持久化

**问题**：每次重新构建后，辅助功能权限失效，需要用户手动到系统设置中删除并重新添加 Flowtype。

**根因**：`codesign --force --deep --sign -` 是 ad-hoc 签名，每次签名会改变二进制哈希。macOS TCC 数据库以签名哈希为键，哈希变化后被视为全新应用。

**应对**：在构建脚本中明确提示用户，并考虑未来使用 Apple Developer 证书签名以解决此问题。

### 挑战 6：音频格式转换管线

**问题**：macOS 硬件音频输入格式各异（采样率、声道数不同），需要统一转换为 16kHz mono float32 供 ASR 使用。

**解决方案**：使用 `AVAudioConverter` 在 `installTap` 回调中进行实时格式转换，同时维护一个 60 秒滚动的 `AVAudioPCMBuffer`，分段输出为 WAV 供云端 ASR 处理。

---

## 三、应用的独特优势（与对标产品对比）

### 对标产品

| 产品 | 定位 | 不足 |
|------|------|------|
| **Whisper Flow** | macOS 语音输入 | 仅支持 Whisper 模型，无 LLM 润色，交互单一 |
| **MacWhisper** | 语音转文字工具 | 偏向文件转录，非实时输入，无文本注入功能 |
| **讯飞语音输入** | 中文语音输入 | 闭源、隐私数据上云、有订阅费用 |
| **Otter.ai** | 会议转录 | 纯云端、按月订阅、不支持实时输入到任意应用 |

### Flowtype 的独特优势

#### 1. 创新的"单击/双击"交互模式（业界首创）

传统语音输入工具只有一个"停止录音"动作。Flowtype 设计了**双模式结束**：

- **单击结束**：直接输出原始 ASR 文本（适合快速记录、代码输入）
- **双击结束**：触发 LLM 润色（适合撰写邮件、文档、消息）

这种设计让同一个热键承载了"快速"和"精致"两种使用场景，无需在设置中切换模式。

#### 2. 本地 + 云端混合架构

- **实时预览**使用 Apple 本地语音识别（`requiresOnDeviceRecognition = true`），数据不出设备
- **最终结果**使用云端 ASR（SiliconFlow 等）保证准确率
- **离线兜底**：网络异常时自动回退到本地识别，保证可用性

相比纯云端方案（Otter、讯飞），Flowtype 在隐私敏感场景下更有优势；相比纯本地方案（Whisper），又在准确率上不妥协。

#### 3. 文本直接注入（非复制粘贴）

大多数语音工具的最终输出方式是"复制到剪贴板"，用户需要手动粘贴。Flowtype 通过 `CGEventPost` 模拟键盘事件，将文本**直接注入**到当前光标位置，体验与打字完全一致。

#### 4. 多 Provider 并行与兜底策略

`SpeechRouter` 支持配置多 ASR Provider：

- **并行模式**：同时请求多个 Provider，取置信度最高的结果
- **兜底模式**：主 Provider 失败时自动切换备用 Provider

用户可以根据网络环境自由组合 SiliconFlow（便宜）、TeleSpeech（中文强）、SenseVoice（多语言）等。

#### 5. 开源与自托管

整个项目开源，用户可以使用自己的 API Key，无需订阅第三方服务。对于开发者而言，还可以自定义 LLM 润色 prompt、接入私有 ASR 模型。

---

## 四、技术栈

| 层级 | 技术 |
|------|------|
| **语言** | Swift 6 |
| **UI 框架** | SwiftUI + AppKit（混合使用） |
| **构建工具** | Swift Package Manager |
| **最低系统** | macOS 14.0 |
| **音频处理** | AVFoundation（`AVAudioEngine`、`AVAudioConverter`） |
| **语音识别** | Speech Framework（`SFSpeechRecognizer` 本地）+  REST API（云端） |
| **全局热键** | CoreGraphics `CGEventTap` + `CFRunLoop` |
| **状态管理** | Combine (`ObservableObject`) + `@MainActor` |
| **并发** | `async/await` + `AsyncStream` |
| **配置持久化** | `UserDefaults` + `JSONEncoder` |
| **代码签名** | ad-hoc（开发阶段） |

### 架构亮点

- **PipelineOrchestrator**：协调录音 → 分段 ASR → 合并 → LLM 润色 → 文本注入的完整管道
- **AudioRecorder**：60 秒滚动分段，实时输出 WAV 数据流
- **AppleSpeechProvider**：流式识别，通过 `onAudioBuffer` 回调接收实时音频
- **AsyncRefiner**：并行 ASR + LLM 润色，支持策略配置
- **KeyboardInjector**：通过 `CGEventPost` 模拟键盘输入，支持 Unicode 字符
