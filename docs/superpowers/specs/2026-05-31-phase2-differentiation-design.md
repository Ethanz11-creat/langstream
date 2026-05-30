# Phase 2 核心差异化功能设计方案

**日期:** 2026-05-31
**状态:** 待讨论确认

---

## 功能 1: 应用感知润色（App-Aware Polish Profiles）

### 问题
用户在不同应用中说同样的话，需要不同的输出格式：
- 在 VS Code/Xcode 中：需要代码注释、技术术语、无多余标点
- 在 Slack/微信中：需要 casual 语气、emoji、简短
- 在邮件/Notion 中：需要正式结构、完整句子
- 在 Terminal 中：需要 shell 命令、无换行

当前所有输出使用同一个 systemPrompt，用户必须手动切换 Style Pack。

### 方案 A: 自动 BundleID 映射（推荐）

**原理:**
1. 录音前通过 `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` 获取前台应用
2. 查询映射表 `[BundleID: StylePackID]`
3. 如果匹配到，使用该 Style Pack 的 prompt 替代默认 prompt
4. 未匹配则使用默认 prompt

**数据模型变更:**
```swift
struct StylePack: Codable, Identifiable {
    let id: String
    var name: String
    var prompt: String
    var baseMode: PolishMode
    // 新增: 适用应用列表
    var applicableApps: [String] = []  // 如 ["com.microsoft.VSCode", "com.apple.dt.Xcode"]
}
```

**录音流程变更:**
```swift
// PipelineOrchestrator.startRecording() 中
let frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
let matchingPack = StylePackStore.shared.packs.first { 
    $0.applicableApps.contains(frontmostApp ?? "") 
}
// 如果有匹配，覆盖当前的 activePack
```

**优点:**
- 实现简单，复用现有 StylePack 架构
- 用户可自定义映射（在 StylePage 中添加"适用应用"多选）
- 无额外 API 调用

**缺点:**
- BundleID 可能因应用版本变化
- 浏览器（Chrome/Safari）无法区分具体网站

### 方案 B: URL/域名感知（浏览器增强）

**原理:**
- 对于浏览器类应用，进一步读取当前页面 URL（通过 AppleScript 或 Accessibility API）
- 根据域名匹配：github.com → code style, gmail.com → formal style

**优点:**
- 浏览器内不同网站可用不同风格

**缺点:**
- 需要额外 Accessibility 权限读取浏览器地址栏
- 实现复杂，不同浏览器 API 不同
- 隐私风险（读取用户浏览的 URL）

**建议:** 先实现方案 A，后续考虑方案 B。

### 需要讨论的问题

1. **内置预设映射:** 是否需要预置一些常用应用映射？
   - VS Code → 代码风格
   - Slack →  casual 风格
   - Terminal → shell 命令风格
   - Mail → 正式邮件风格

2. **UI 怎么设计:** StylePage 中如何让用户选择"适用应用"？
   - 选项 A: 文本输入框手动填 BundleID（太技术）
   - 选项 B: 下拉菜单选择已安装应用（需要扫描 `/Applications`）
   - 选项 C: 按钮"为当前应用设置"自动捕获前台应用

3. **和现有 Style Pack 的关系:** 是扩展 Style Pack，还是新增独立概念？
   - 扩展 Style Pack 更自然（每个 Pack 可选绑定应用）

---

## 功能 2: 剪贴板上下文（Clipboard-Aware Polish）

### 问题
用户想说"重写这段代码"或"翻译这句话"，但语音输入只包含指令，不包含被操作的对象。

### 方案

**原理:**
1. 录音开始前读取 `NSPasteboard.general.string(forType: .string)`
2. 如果剪贴板有文本内容，将其作为 context 传给 LLM
3. LLM prompt 中增加："用户的剪贴板内容: [clipboard]。请结合该内容和用户的语音指令进行润色。"

**数据模型变更:**
```swift
struct Configuration {
    // 新增
    var useClipboardContext: Bool = false
    var maxClipboardContextLength: Int = 2000  // 安全: 限制上下文长度
}
```

**LLMService 变更:**
```swift
// composeSystemPrompt 中新增剪贴板上下文段
let clipboardText = NSPasteboard.general.string(forType: .string)
if useClipboardContext, let clipboard = clipboardText, !clipboard.isEmpty {
    let truncated = String(clipboard.prefix(maxClipboardContextLength))
    prompt += "\n\n用户剪贴板内容（供参考）:\n\(truncated)"
}
```

**隐私/安全考虑:**
- 默认关闭（opt-in），因为剪贴板可能包含密码、密钥等敏感信息
- 在 Settings 中添加显式开关 + 警告说明
- 限制上下文长度（2000 字符），防止 Token 爆炸
- 不将剪贴板内容写入日志或历史记录

### 需要讨论的问题

1. **默认开启还是默认关闭？** 考虑到剪贴板隐私，建议默认关闭。
2. **上下文长度限制多少合适？** 2000 字符？还是按 Token 数估算？
3. **是否只在特定 polish mode 下启用？** 比如"重写"模式自动启用，其他模式不启用？

---

## 功能 3: 语音片段（Voice-Triggered Snippets）

### 问题
开发者经常需要输入重复模板（React 组件、函数模板、版权头、 today's date）。现有解决方案（TextExpander、Alfred）需要打字缩写，不如语音直接。

### 方案

**原理:**
1. 用户预定义片段：触发词 → 模板文本
2. ASR 输出后，先匹配触发词（精确匹配或前缀匹配）
3. 如果匹配成功，直接注入模板文本，跳过 LLM 润色
4. 支持变量替换：`{{DATE}}`、`{{TIME}}`、`{{CLIPBOARD}}`

**数据模型:**
```swift
struct VoiceSnippet: Codable, Identifiable {
    let id: String
    var triggerPhrase: String      // 如 "boilerplate react"
    var template: String           // 如 "import React from 'react';\n\nconst {{NAME}} = () => {\n  return (\n    <div>\n    </div>\n  );\n};\n"
    var isEnabled: Bool = true
    var createdAt: Date
}

@MainActor
final class VoiceSnippetStore: ObservableObject {
    static let shared = VoiceSnippetStore()
    @Published private(set) var snippets: [VoiceSnippet] = []
    // ... persistence, CRUD
}
```

**流程变更:**
```swift
// PipelineOrchestrator.runProcessingSession 中
let asrText = ...

// 检查是否匹配 snippet
if let snippet = VoiceSnippetStore.shared.match(asrText) {
    await injectText(snippet.expandedTemplate, sessionID: id)
    return  // 跳过 LLM 润色
}

// 否则正常走 LLM 润色流程
```

**变量替换:**
```swift
extension VoiceSnippet {
    var expandedTemplate: String {
        var result = template
        result = result.replacingOccurrences(of: "{{DATE}}", with: dateString)
        result = result.replacingOccurrences(of: "{{TIME}}", with: timeString)
        result = result.replacingOccurrences(of: "{{CLIPBOARD}}", with: clipboardString)
        return result
    }
}
```

### 需要讨论的问题

1. **匹配策略:** 精确匹配（说的一样）还是模糊匹配（包含关键词即可）？
   - 精确匹配更安全，但容错差
   - 模糊匹配更自然，但可能误触发

2. **和 LLM 润色的关系:**
   - 选项 A: Snippet 完全跳过润色（快速）
   - 选项 B: Snippet 作为输入传给 LLM，让 LLM 在模板基础上填充

3. **UI 位置:** 在 Settings 中新建"片段"标签页，还是放在 VocabPage 旁边？

---

## 功能 4: 提交信息生成（Commit Message Generator）

### 问题
写 commit message 是开发者最讨厌的事情之一。用户需要手动阅读 diff，思考总结，然后打字输入。

### 方案

**原理:**
1. 新增 Polish Mode / Style Pack: "Git Commit"
2. 触发后执行 `git diff --staged` 获取暂存区变更
3. 将 diff + 用户的语音描述传给 LLM
4. LLM 生成符合 conventional commits 格式的提交信息

**数据模型:**
```swift
enum PolishMode: String, Codable, CaseIterable {
    case raw, light, structured, formal
    case commit  // 新增
    
    var displayName: String {
        switch self {
        case .raw: return "原文"
        case .light: return "轻量润色"
        case .structured: return "结构化"
        case .formal: return "正式"
        case .commit: return "Git 提交"
        }
    }
}
```

**System Prompt 模板:**
```
你是一个 Git 提交信息生成助手。用户会用语音描述他刚才做了什么更改，同时我会提供 git diff --staged 的输出。

请生成一条符合 Conventional Commits 规范的提交信息：
- 格式: <type>(<scope>): <subject>
- type: feat, fix, refactor, docs, test, chore
- subject 使用祈使句、小写开头、不超过 72 字符
- 如果变更复杂，在 body 中简要说明

用户的描述: {{USER_DESCRIPTION}}
暂存区变更:
{{GIT_DIFF}}
```

**技术实现:**
```swift
func getStagedDiff() async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["diff", "--staged", "--stat"]
    // 或使用 --cached 获取完整 diff
    // 限制 diff 大小（如 5000 字符）避免 Token 爆炸
    ...
}
```

**注入方式:**
- 直接注入到 Terminal/VS Code 的 commit message 输入框
- 或注入后自动回车（如果用户配置了）

### 需要讨论的问题

1. **diff 截断策略:** 大项目的 staged diff 可能非常大。截断到多少 Token 合适？
2. **是否需要先检测是否在 git 仓库内？** 如果不在 git 仓库中，提示用户。
3. **注入位置:** 是直接注入文本，还是需要和特定应用（如 Terminal）配合？
4. **commit body 是否生成？** 简单变更只生成 subject，复杂变更生成 body + subject？

---

## 实施优先级建议

| 优先级 | 功能 | 原因 |
|--------|------|------|
| P0 | 应用感知润色 | 差异化最强，实现简单，复用现有架构 |
| P1 | 语音片段 | 用户价值高，实现中等，可快速迭代 |
| P2 | 剪贴板上下文 | 价值高，但隐私敏感，需要仔细设计 |
| P3 | 提交信息生成 | 开发者刚需，但依赖 git 和 Terminal 上下文 |

---

## 下一步

请确认：
1. **这四个功能中，你最想先做哪几个？**
2. **对每个功能，选择方案 A 还是方案 B？**
3. **是否有功能需要调整范围或合并？**
