# Phase 1 快速胜利设计方案

**日期:** 2026-05-31
**状态:** 待讨论确认
**排除项:** 终身定价（用户明确不考虑）

---

## 功能 1: 交互式 Onboarding 演示

### 问题
当前 onboarding 在第 3 步（Quick Config）结束后直接关闭，用户还没真正体验过语音输入。第一次使用时不知道触发键是否生效，必须自己找文本框试。

### 方案

**新增 Step 4: "试一试"**

页面布局:
```
┌─────────────────────────────────────────────┐
│  🎉 一切准备就绪                             │
│                                              │
│  双击 ⌘ 开始录音，说一句话试试               │
│                                              │
│  ┌───────────────────────────────────────┐  │
│  │                                       │  │
│  │   [大文本区域，类似 TextEditor]         │  │
│  │                                       │  │
│  │   你的语音会显示在这里...               │  │
│  │                                       │  │
│  └───────────────────────────────────────┘  │
│                                              │
│  [开始体验]  ← 点击进入主应用                │
└─────────────────────────────────────────────┘
```

**技术实现:**

方案 A: 复用 SessionController（推荐）
1. 添加 `onboardingDemoMode: Bool` 属性到 SessionController
2. 在 demo 模式下，注入不调用 KeyboardInjector，而是回调给 OnboardingView
3. OnboardingView 通过 `@State` 显示结果文本

```swift
// SessionController 变更
var onboardingTextCallback: ((String) -> Void)?

private func injectText(_ text: String, sessionID: UInt64) async {
    if let callback = onboardingTextCallback {
        callback(text)
        resetToIdle()
        return
    }
    // 正常注入逻辑...
}
```

方案 B: 独立的演示录音器
1. 创建一个简化的录音流程，不走完整的 SessionController
2. 直接录音 → ASR → 显示文本
3. 不保存历史，不调用 LLM（纯 ASR）

**建议方案 A**，因为用户可以在 demo 中体验完整的流程（包括 LLM 润色，如果配置了 API key）。

### 需要讨论的问题

1. **Demo 模式是否走 LLM 润色？**
   - 走：体验完整，但需要有效的 API key（新用户可能没有）
   - 不走：更简单，但用户不知道润色是什么效果
   - **建议:** 检测是否有配置好的 provider，有则走完整流程，没有则只展示 ASR

2. **Demo 文本区域样式:**
   - 选项 A: 系统 TextEditor（真实感强）
   - 选项 B: 自定义装饰区域（更像演示）

3. **Step 4 是否可跳过？** 是，提供"跳过"按钮。

---

## 功能 2: 音频反馈（Audio Feedback）

### 问题
FlowType 完全静默。用户戴耳机或在安静环境中无法通过声音确认录音已开始/已停止。只能依赖视觉（Capsule 出现/消失）。

### 方案

使用 `AudioServicesPlaySystemSound` 播放系统音效:

| 事件 | 音效 | 时长 |
|------|------|------|
| 录音开始 | 上升音调 (1104) | 80ms |
| 录音结束 | 下降音调 (1103) | 80ms |
| 错误 | 轻微"嗒"声 (1102) | 50ms |

**技术实现:**

```swift
import AudioToolbox

enum SoundFeedback {
    static func playRecordingStart() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1104) // ascending
    }
    
    static func playRecordingStop() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1103) // descending
    }
    
    static func playError() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1102) // subtle bump
    }
    
    private static var isEnabled: Bool {
        // 检查 macOS "播放用户界面音效"设置
        let volume = UserDefaults.standard.float(forKey: "com.apple.sound.beep.volume")
        return volume > 0
    }
}
```

**集成点:**
- `SessionController.startRecording()` → `SoundFeedback.playRecordingStart()`
- `SessionController.endRecording()` → `SoundFeedback.playRecordingStop()`
- `SessionController.showError()` → `SoundFeedback.playError()`

### 需要讨论的问题

1. **是否提供关闭开关？** 建议提供，在 Settings 中添加"启用音频反馈"复选框
2. **使用系统音效还是自定义 .aiff？** 
   - 系统音效：简单，符合 macOS 风格，但选择有限
   - 自定义：可以设计品牌音效，但需要音频资源
3. **音量大小:** 系统音效的音量跟随系统提示音量，无需单独控制

---

## 功能 3: 可重试错误卡片（Retryable Error Cards）

### 问题
当前错误用 `showError(_:)` 显示 3 秒自动消失的红字消息。用户看到"润色失败，使用原始文本"但无法重试，只能重新录音。

### 方案

**将 `SessionState.error(String)` 升级为带操作的错误状态:**

```swift
enum SessionState: Equatable {
    // ... existing cases ...
    case error(title: String, detail: String?, actions: [ErrorAction])
}

enum ErrorAction: Equatable {
    case retryPolish      // 重试 LLM 润色
    case copyRaw          // 复制原始 ASR 文本到剪贴板
    case dismiss          // 关闭错误，返回 idle
}
```

**CapsuleView 错误 UI:**

```
┌─────────────────────────────────────┐
│  ⚠️ 润色失败                         │
│  SiliconFlow: 连接超时               │
│                                     │
│  [重试润色]  [复制原文]  [忽略]      │
└─────────────────────────────────────┘
```

**技术实现:**

1. 修改 `LLMService` 错误传递，保留原始 ASR 文本
2. 修改 `PipelineOrchestrator`，错误状态时存储原始文本
3. 修改 `CapsuleView`，渲染错误操作按钮

```swift
// PipelineOrchestrator 变更
private var sessionRawTextForRetry: String = ""

private func showError(_ message: String, detail: String? = nil, actions: [ErrorAction] = [.dismiss]) {
    let errorSessionID = activeSessionID
    sessionState = .error(title: message, detail: detail, actions: actions)
    WindowManager.shared.showWindow()
    // ... auto-dismiss timer
}

// 在 LLM 失败时
sessionState = .error(
    title: "润色失败",
    detail: "\(provider.name): \(error.localizedDescription)",
    actions: [.retryPolish, .copyRaw, .dismiss]
)
```

**重试逻辑:**
```swift
func retryPolish() {
    guard !sessionRawTextForRetry.isEmpty else { return }
    sessionState = .polishing(preview: "")
    // 重新调用 LLMService.polishText(sessionRawTextForRetry)
}
```

### 需要讨论的问题

1. **哪些错误支持重试？**
   - LLM API 错误（超时、5xx）→ 支持重试
   - 网络断开 → 支持重试
   - ASR 为空 → 不支持（没有内容可润色）
   - 麦克风权限拒绝 → 不支持（需要系统设置）

2. **重试次数限制？** 建议最多 3 次，防止无限重试循环。

3. **错误卡片的自动消失:** 是否保留 3 秒自动消失？
   - 保留：用户不操作时自动消失
   - 移除：必须用户手动处理（防止误操作）
   - **建议:** 有操作按钮时不自动消失，无操作按钮时 5 秒后消失。

---

## 功能 4: 设置搜索（Settings Search）

### 问题
Settings 是长表单（~1100 行），功能分散在多个 section 中。用户想找"麦克风"设置需要滚动，想找"API Key"需要滚动。

### 方案

**在 SettingsView 顶部添加搜索栏:**

```
┌─────────────────────────────────────────────┐
│ 🔍 搜索设置...                               │
├─────────────────────────────────────────────┤
│ [ASR] [LLM] [快捷键] [关于]                  │
│                                              │
│  ╔═══════════════════════════════════════╗  │
│  ║ LLM Provider                          ║  │
│  ║  SiliconFlow  [测试连接]              ║  │
│  ╚═══════════════════════════════════════╝  │
│                                              │
│  ╔═══════════════════════════════════════╗  │
│  ║ API Key                               ║  │
│  ║  [****************] 👁               ║  │
│  ╚═══════════════════════════════════════╝  │
└─────────────────────────────────────────────┘
```

**技术实现:**

```swift
struct SettingsView: View {
    @State private var searchQuery: String = ""
    
    var body: some View {
        VStack {
            searchBar
            ScrollView {
                if searchQuery.isEmpty || matchesSearch(.asrSection) {
                    asrSection
                }
                if searchQuery.isEmpty || matchesSearch(.llmSection) {
                    llmSection
                }
                // ...
            }
        }
    }
    
    private func matchesSearch(_ section: SettingsSection) -> Bool {
        let query = searchQuery.lowercased()
        return section.keywords.contains { $0.contains(query) }
    }
}

enum SettingsSection {
    case asrSection, llmSection, triggerSection, aboutSection
    
    var keywords: [String] {
        switch self {
        case .asrSection: return ["asr", "语音识别", "麦克风", "mic", "录音"]
        case .llmSection: return ["llm", "润色", "api", "key", "模型", "provider"]
        case .triggerSection: return ["触发", "快捷键", "hotkey", "command"]
        case .aboutSection: return ["关于", "版本", "日志", "更新"]
        }
    }
}
```

**搜索行为:**
- 实时过滤（输入即过滤）
- 无结果时显示"未找到设置项"
- 支持中文拼音匹配（可选，增加复杂度）

### 需要讨论的问题

1. **搜索匹配策略:**
   - 简单包含匹配（"mic" 匹配 "麦克风"）
   - 还是需要中文拼音匹配（"mai" 匹配 "麦克风"）？
   - **建议:** 先做简单包含匹配，拼音匹配后续迭代。

2. **高亮显示:** 匹配到的 section 正常显示，未匹配的半透明隐藏？还是完全隐藏？
   - **建议:** 未匹配的完全隐藏，界面更干净。

3. **搜索栏常驻还是可收起？**
   - 常驻：随时可用
   - 可收起（Cmd+F 展开）：更简洁
   - **建议:** 常驻，因为 Settings 窗口本来就够大了。

---

## 实施优先级建议

| 优先级 | 功能 | 估计工时 | 原因 |
|--------|------|---------|------|
| P0 | 音频反馈 | 2-4h | 最简单，影响所有用户 |
| P1 | 可重试错误卡片 | 4-6h | 解决真实痛点，提升可靠性感知 |
| P2 | 交互式 Onboarding | 6-8h | 提升新用户留存 |
| P3 | 设置搜索 | 4-6h | 锦上添花，用户学会后很少再用 |

---

## 下一步

请确认：
1. **四个功能的优先级是否符合你的预期？**
2. **每个功能选择的方案（A/B）是否正确？**
3. **是否有功能需要调整范围？**
4. **是否现在就开始实现，还是先看完 Phase 2 再决定？**
