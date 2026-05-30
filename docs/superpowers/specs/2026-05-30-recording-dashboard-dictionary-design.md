# FlowType 模块 3 + 4 + 5 设计文档

**Date:** 2026-05-30  
**Scope:** 录音时长限制 + 历史记录看板 + 智能词典  
**Status:** Draft

---

## 1. 模块 3：录音时长限制

### 1.1 需求
- 录音时长上限：默认 10 分钟，用户可在设置中配置 7-10 分钟
- 最后 30 秒 Capsule 倒计时警告（变橙色）
- 到达限制自动停止录音，输出原始文本（不调用 LLM polish）

### 1.2 设计
- `Configuration` 新增 `maxRecordingDuration: Int = 600`（秒）
- `SessionController` 的 `recordingTimer` 在达到限制时自动调用 `endRecording(withPolish: false)`
- `CapsuleView` 在最后 30 秒显示倒计时并改变颜色

---

## 2. 模块 4：历史记录与数据看板

### 2.1 需求

**a) 搜索与导出**
- HistoryPage 已有搜索，需要添加导出按钮
- 导出格式：JSON（完整数据）和 CSV（简化表格）
- 导出范围：全部或筛选后的结果

**b) 数据看板（Dashboard）**
- 新增 `OverviewPage` 或改造现有页面展示统计：
  - 总口述时间（从所有历史记录累加 durationMs）
  - 总口述字数（累加 `finalText` 字符数）
  - 节省时间（假设打字速度 40 WPM，口述速度从统计数据计算）
  - 平均口述速度（总字数 / 总时间，每分钟字数）
  - 个性化准确度（词典命中率，已有 `DictionaryStore.detectHits`）
- 参考 Typeless 截图的卡片式布局

**c) 本地存储按天统计**
- 新增 `DailyStats` 模型：`date`（YYYY-MM-DD）、`totalDurationMs`、`totalWordCount`、`sessionCount`
- `HistoryStore.append()` 时自动聚合到对应日期的 `DailyStats`
- 看板从 `DailyStats` 读取聚合数据

### 2.2 设计

**数据模型：**
```swift
struct DailyStats: Codable, Identifiable {
    let date: String // "2026-05-30"
    var totalDurationMs: UInt64
    var totalWordCount: Int
    var sessionCount: Int
    
    var id: String { date }
}
```

**HistoryStore 扩展：**
- 新增 `dailyStats: [DailyStats]`，持久化到 `daily_stats.json`
- `append(_:)` 时更新对应日期的统计
- 提供计算属性：`totalDuration`、`totalWordCount`、`averageSpeed`

**OverviewPage：**
- 参考 Typeless 首页设计：大字体数字 + 小字标签的统计卡片
- 左侧：个性化准确度（环形进度图）
- 右侧 2x2 网格：总口述时间、总口述字数、节省时间、平均口述速度

**导出功能：**
- HistoryPage 工具栏添加"导出"按钮
- 弹出 NSSavePanel，支持 JSON 和 CSV 格式选择

---

## 3. 模块 5：智能词典

### 3.1 需求

**a) 自动添加**
- 用户注入后手动修正文本 → 系统对比原始 ASR 结果和最终文本
- 使用编辑距离（Levenshtein）对齐，识别被修正的词汇
- 自动加入 `DictionaryStore`（标记为 auto-added）

**b) 大模型辅助**
- 在 LLM polish 阶段，让模型同时返回可能的识别错误和修正建议
- 通过 JSON 格式返回 corrections 列表
- 用户确认后添加到词典

**c) 手动管理**
- 改造 `VocabPage`，参考 Typeless 词典的网格标签布局
- 支持添加、删除、编辑词条
- 标记来源：自动 / 手动

### 3.2 设计

**自动添加流程：**
1. 用户录音 → ASR 生成 rawText
2. 用户修正后的文本通过键盘注入（无法直接捕获）
3. **替代方案**：在 `HistoryStore.append()` 时，比较 rawTranscript 和 finalText
4. 提取差异词组，使用编辑距离算法
5. 将高频差异词添加到词典

**大模型辅助：**
- 修改 `LLMService.composeSystemPrompt`，添加指示让模型返回 corrections JSON
- 在 `PipelineOrchestrator` 中解析 corrections 并提示用户

**DictionaryEntry 扩展：**
```swift
enum EntrySource: String, Codable {
    case manual, autoDetected, llmSuggested
}

struct DictionaryEntry: Codable, Identifiable {
    // ... existing fields ...
    var source: EntrySource = .manual
}
```

---

## 4. UI 变更

| 页面 | 变更 |
|------|------|
| `SettingsView` | 新增"录音时长限制"滑块（7-10 分钟） |
| `CapsuleView` | 最后 30 秒倒计时 + 橙色警告 |
| `OverviewPage` | 新增统计看板（卡片式布局） |
| `HistoryPage` | 添加导出按钮（JSON/CSV） |
| `VocabPage` | 网格标签布局，标记来源 |

---

## 5. 验收标准

- [ ] 录音达到限制时自动停止并输出原始文本
- [ ] Capsule 在最后 30 秒显示倒计时并变橙色
- [ ] 历史记录页可以导出 JSON/CSV
- [ ] 首页看板显示正确的统计数据
- [ ] 按天统计数据正确累加
- [ ] 词典支持自动添加修正词汇
- [ ] 词典页面显示来源标记（自动/手动）
