# 模块 3 + 4 + 5 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development

**Goal:** 实现录音时长限制、历史记录数据看板、智能词典功能

**Architecture:** 增量修改现有代码。模块 3 修改 SessionController + CapsuleView；模块 4 新增 DailyStats 模型和 OverviewPage 看板；模块 5 扩展 DictionaryEntry 和自动检测逻辑。

**Tech Stack:** Swift 6.2, SwiftUI, CoreAudio

---

## 文件结构

### 新增文件
| 文件 | 职责 |
|------|------|
| `Sources/flowtype/Core/DailyStats.swift` | DailyStats 模型 + DailyStatsStore |

### 修改文件
| 文件 | 职责 |
|------|------|
| `Sources/flowtype/Core/Configuration.swift` | 新增 `maxRecordingDuration` |
| `Sources/flowtype/Core/ConfigurationStore.swift` | Migration 5 |
| `Sources/flowtype/Core/DictationHistory.swift` | HistoryStore 扩展：统计计算、按天聚合 |
| `Sources/flowtype/Core/Dictionary.swift` | DictionaryEntry 添加 source 字段 |
| `Sources/flowtype/Core/PipelineOrchestrator.swift` | 录音时长限制、自动检测词典差异 |
| `Sources/flowtype/CapsuleView.swift` | 倒计时警告 |
| `Sources/flowtype/Settings/SettingsView.swift` | 录音时长滑块 |
| `Sources/flowtype/Settings/OverviewPage.swift` | 数据看板改造 |
| `Sources/flowtype/Settings/HistoryPage.swift` | 导出按钮 |
| `Sources/flowtype/Settings/VocabPage.swift` | 网格布局、来源标记 |

---

## Task 1: Configuration 录音时长限制字段

**Files:**
- Modify: `Sources/flowtype/Core/Configuration.swift`
- Modify: `Sources/flowtype/Core/ConfigurationStore.swift`

- [ ] **Step 1: Configuration.swift 添加 `maxRecordingDuration`**

在 `enableTermCorrection` 之后添加：
```swift
    var maxRecordingDuration: Int = 600 // seconds, default 10 minutes
```

更新 CodingKeys、decoder、encoder。

- [ ] **Step 2: ConfigurationStore.swift 升级 migration version**

Version 3 -> 4（等等，已经是 4 了，改为 5）

```swift
    private let currentMigrationVersion = 5
```

添加 Migration 5：
```swift
            if storedVersion < 5 {
                if config.maxRecordingDuration == 0 {
                    config.maxRecordingDuration = 600
                }
                needsSave = true
            }
```

- [ ] **Step 3: 编译 + Commit**

Run: `swift build`

```bash
git add Sources/flowtype/Core/Configuration.swift Sources/flowtype/Core/ConfigurationStore.swift
git commit -m "feat(config): add maxRecordingDuration field with migration"
```

---

## Task 2: 录音时长限制 + Capsule 倒计时

**Files:**
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Modify: `Sources/flowtype/CapsuleView.swift`
- Modify: `Sources/flowtype/Settings/SettingsView.swift`

### PipelineOrchestrator.swift

- [ ] **Step 1: 添加录音超时逻辑**

在 `startRecordingTimer()` 中，添加超时检查：

```swift
    private func startRecordingTimer() {
        elapsedSeconds = 0
        let maxDuration = ConfigurationStore.shared.current.maxRecordingDuration
        recordingTimer.schedule(withTimeInterval: 1.0, repeats: true) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.elapsedSeconds += 1
                self.sessionState = .recording(elapsedSeconds: self.elapsedSeconds)
                
                // Auto-stop at max duration
                if self.elapsedSeconds >= maxDuration {
                    AppLogger.log("[SessionController] Recording reached max duration (\(maxDuration)s), auto-stopping")
                    self.endRecording(withPolish: false)
                }
            }
        }
    }
```

### CapsuleView.swift

- [ ] **Step 2: 添加倒计时警告**

在 `statusColor` 或 `recordingTimerText` 中，当剩余时间 ≤ 30 秒时变橙色：

修改 `statusColor` 为计算属性：

```swift
    private var statusColor: Color {
        if case .recording(let seconds) = session.sessionState {
            let maxDuration = ConfigurationStore.shared.current.maxRecordingDuration
            if maxDuration - seconds <= 30 {
                return .orange
            }
        }
        return session.sessionState.statusColor
    }
```

或者更简单：在 `recordingTimerText` 中显示倒计时：

```swift
    private var recordingTimerText: String? {
        if case .recording(let seconds) = session.sessionState {
            let maxDuration = ConfigurationStore.shared.current.maxRecordingDuration
            let remaining = maxDuration - seconds
            if remaining <= 30 {
                return "剩余 \(remaining)s"
            }
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        return nil
    }
```

### SettingsView.swift

- [ ] **Step 3: 添加录音时长滑块**

在 Trigger Key Section 之前添加 Recording Section：

```swift
                // MARK: Recording Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.red)
                        Text("录音设置")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("录音时长限制")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(store.current.maxRecordingDuration / 60) 分钟")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        Slider(value: Binding(
                            get: { Double(store.current.maxRecordingDuration) },
                            set: { store.current.maxRecordingDuration = Int($0) }
                        ), in: 420...600, step: 60)
                        Text("达到限制后自动停止录音并输出原始文本")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 4)
```

- [ ] **Step 4: 编译 + Commit**

Run: `swift build`

```bash
git add Sources/flowtype/Core/PipelineOrchestrator.swift Sources/flowtype/CapsuleView.swift Sources/flowtype/Settings/SettingsView.swift
git commit -m "feat(recording): add max duration limit with countdown warning"
```

---

## Task 3: DailyStats 模型和存储

**Files:**
- Create: `Sources/flowtype/Core/DailyStats.swift`
- Modify: `Sources/flowtype/Core/DictationHistory.swift`

### DailyStats.swift

- [ ] **Step 1: 创建 DailyStats 模型**

```swift
import Foundation

struct DailyStats: Codable, Identifiable {
    let date: String // "YYYY-MM-DD"
    var totalDurationMs: UInt64
    var totalWordCount: Int
    var sessionCount: Int
    
    var id: String { date }
    
    var formattedDuration: String {
        let totalSeconds = Int(totalDurationMs / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
    
    var averageSpeed: Int {
        let totalMinutes = Double(totalDurationMs) / 1000.0 / 60.0
        guard totalMinutes > 0 else { return 0 }
        return Int(Double(totalWordCount) / totalMinutes)
    }
}

@MainActor
final class DailyStatsStore: ObservableObject {
    static let shared = DailyStatsStore()
    
    @Published private(set) var stats: [DailyStats] = []
    
    private let store = PersistentStore<[DailyStats]>(filename: "daily_stats.json")
    private var saveDebounce: Task<Void, Never>?
    
    private init() {
        stats = store.load() ?? []
    }
    
    func recordSession(durationMs: UInt64, wordCount: Int) {
        let date = Self.todayString
        if let idx = stats.firstIndex(where: { $0.date == date }) {
            stats[idx].totalDurationMs += durationMs
            stats[idx].totalWordCount += wordCount
            stats[idx].sessionCount += 1
        } else {
            stats.append(DailyStats(
                date: date,
                totalDurationMs: durationMs,
                totalWordCount: wordCount,
                sessionCount: 1
            ))
        }
        // Keep last 365 days
        if stats.count > 365 {
            stats.sort { $0.date > $1.date }
            stats = Array(stats.prefix(365))
        }
        scheduleSave()
    }
    
    var totalDurationMs: UInt64 {
        stats.reduce(0) { $0 + $1.totalDurationMs }
    }
    
    var totalWordCount: Int {
        stats.reduce(0) { $0 + $1.totalWordCount }
    }
    
    var totalSessionCount: Int {
        stats.reduce(0) { $0 + $1.sessionCount }
    }
    
    var overallAverageSpeed: Int {
        let totalMinutes = Double(totalDurationMs) / 1000.0 / 60.0
        guard totalMinutes > 0 else { return 0 }
        return Int(Double(totalWordCount) / totalMinutes)
    }
    
    var estimatedTimeSaved: String {
        // Assume typing speed of 40 WPM (≈ 200 CPM)
        let typingMinutes = Double(totalWordCount) / 40.0
        let speakingMinutes = Double(totalDurationMs) / 1000.0 / 60.0
        let savedMinutes = max(0, Int(typingMinutes - speakingMinutes))
        let hours = savedMinutes / 60
        let minutes = savedMinutes % 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
    
    private func scheduleSave() {
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.store.save(self.stats)
        }
    }
    
    private static var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
```

### DictationHistory.swift

- [ ] **Step 2: HistoryStore.append 时聚合到 DailyStats**

修改 `append` 方法：

```swift
    func append(_ session: DictationSession) {
        sessions.insert(session, at: 0)
        if sessions.count > maxEntries {
            sessions = Array(sessions.prefix(maxEntries))
        }
        scheduleSave()
        
        // Aggregate to daily stats
        if let durationMs = session.durationMs {
            let wordCount = session.finalText.count
            DailyStatsStore.shared.recordSession(durationMs: durationMs, wordCount: wordCount)
        }
    }
```

- [ ] **Step 3: 编译 + Commit**

Run: `swift build`

```bash
git add Sources/flowtype/Core/DailyStats.swift Sources/flowtype/Core/DictationHistory.swift
git commit -m "feat(stats): add DailyStats model and auto-aggregation"
```

---

## Task 4: 数据看板 OverviewPage

**Files:**
- Modify: `Sources/flowtype/Settings/OverviewPage.swift`

- [ ] **Step 1: 改造 OverviewPage 为统计看板**

参考 Typeless 截图的卡片式布局：

```swift
struct OverviewPage: View {
    @ObservedObject private var statsStore = DailyStatsStore.shared
    @ObservedObject private var dictionaryStore = DictionaryStore.shared
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Top row: Accuracy ring + main stats
                HStack(spacing: 20) {
                    accuracyCard
                    mainStatsGrid
                }
                .frame(height: 200)
                
                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var accuracyCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: accuracyProgress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(accuracyProgress * 100))%")
                    .font(.system(size: 18, weight: .bold))
            }
            Text("个性化")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(cardBackground)
    }
    
    private var mainStatsGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statCard(
                    icon: "clock",
                    value: statsStore.totalDurationMs.formattedDuration,
                    label: "总口述时间"
                )
                statCard(
                    icon: "text.word.count",
                    value: "\(statsStore.totalWordCount / 1000).\((statsStore.totalWordCount % 1000) / 100)K",
                    label: "口述字数"
                )
            }
            HStack(spacing: 12) {
                statCard(
                    icon: "hourglass",
                    value: statsStore.estimatedTimeSaved,
                    label: "节省时间"
                )
                statCard(
                    icon: "bolt",
                    value: "\(statsStore.overallAverageSpeed)",
                    label: "平均口述速度（字/分钟）"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func statCard(icon: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 22, weight: .bold))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(cardBackground)
    }
    
    private var accuracyProgress: Double {
        let total = dictionaryStore.entries.count
        guard total > 0 else { return 0 }
        let enabled = dictionaryStore.entries.filter(\.enabled).count
        return Double(enabled) / Double(total)
    }
    
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 2)
    }
}

// Helper for formatting duration
extension UInt64 {
    var formattedDuration: String {
        let totalSeconds = Int(self / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}
```

- [ ] **Step 2: 编译 + Commit**

Run: `swift build`

```bash
git add Sources/flowtype/Settings/OverviewPage.swift
git commit -m "feat(dashboard): add statistics cards to OverviewPage"
```

---

## Task 5: 历史记录导出功能

**Files:**
- Modify: `Sources/flowtype/Settings/HistoryPage.swift`

- [ ] **Step 1: 添加导出按钮和逻辑**

在 `headerBar` 的"清空"按钮之前添加导出按钮：

```swift
            Button {
                exportSessions()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(filteredSessions.isEmpty)
```

添加 `exportSessions()` 方法：

```swift
    private func exportSessions() {
        let sessions = filteredSessions
        guard !sessions.isEmpty else { return }
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.nameFieldStringValue = "flowtype_history_\(formatDateFile(Date()))"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let ext = url.pathExtension.lowercased()
        do {
            if ext == "json" {
                let data = try JSONEncoder().encode(sessions)
                try data.write(to: url)
            } else {
                // CSV
                var csv = "Created At,Mode,Duration (s),Final Text\n"
                for session in sessions {
                    let date = formatDateFull(session.createdAt)
                    let mode = session.polishMode.displayName
                    let duration = session.durationMs.map { String(Double($0) / 1000.0) } ?? ""
                    let text = session.finalText.replacingOccurrences(of: "\"", with: "\"\"")
                    csv += "\"\(date)\",\"\(mode)\",\"\(duration)\",\"\(text)\"\n"
                }
                try csv.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            AppLogger.log("[HistoryPage] Export failed: \(error)")
        }
    }
    
    private func formatDateFile(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
```

- [ ] **Step 2: 编译 + Commit**

Run: `swift build`

```bash
git add Sources/flowtype/Settings/HistoryPage.swift
git commit -m "feat(history): add JSON/CSV export functionality"
```

---

## Task 6: 智能词典自动添加

**Files:**
- Modify: `Sources/flowtype/Core/Dictionary.swift`
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`

### Dictionary.swift

- [ ] **Step 1: 添加 source 字段和自动添加方法**

```swift
enum EntrySource: String, Codable {
    case manual, autoDetected
}

struct DictionaryEntry: Codable, Identifiable {
    let id: String
    var phrase: String
    var note: String?
    var enabled: Bool
    var hits: UInt64
    let createdAt: Date
    var source: EntrySource

    init(phrase: String, note: String? = nil, source: EntrySource = .manual) {
        self.id = UUID().uuidString
        self.phrase = phrase.trimmingCharacters(in: .whitespaces)
        self.note = note
        self.enabled = true
        self.hits = 0
        self.createdAt = Date()
        self.source = source
    }
}
```

在 `DictionaryStore` 中添加：

```swift
    func addAutoDetected(phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !entries.contains(where: { $0.phrase.lowercased() == trimmed.lowercased() }) else { return }
        let entry = DictionaryEntry(phrase: trimmed, source: .autoDetected)
        entries.append(entry)
        scheduleSave()
        AppLogger.log("[DictionaryStore] Auto-added: \(trimmed)")
    }
```

### PipelineOrchestrator.swift

- [ ] **Step 2: 在 saveHistory 中比较 rawTranscript 和 finalText，提取差异**

修改 `saveHistory` 方法，在保存历史后添加自动检测逻辑：

```swift
    private func saveHistory(finalText: String) {
        // ... existing save logic ...
        
        // Auto-detect corrections for dictionary
        if sessionRawTranscript != finalText {
            detectAndAddCorrections(raw: sessionRawTranscript, final: finalText)
        }
    }
    
    private func detectAndAddCorrections(raw: String, final: String) {
        // Simple word-level diff
        let rawWords = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let finalWords = final.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        // Find words in final that are not in raw (potential corrections)
        let rawSet = Set(rawWords.map { $0.lowercased() })
        for word in finalWords {
            let lower = word.lowercased()
            if !rawSet.contains(lower), word.count >= 2 {
                DictionaryStore.shared.addAutoDetected(phrase: word)
            }
        }
    }
```

- [ ] **Step 3: 编译 + Commit**

Run: `swift build`

```bash
git add Sources/flowtype/Core/Dictionary.swift Sources/flowtype/Core/PipelineOrchestrator.swift
git commit -m "feat(dictionary): auto-detect corrections and add to dictionary"
```

---

## Task 7: 词典页面改造

**Files:**
- Modify: `Sources/flowtype/Settings/VocabPage.swift`

- [ ] **Step 1: 改造为网格标签布局 + 来源标记**

由于 VocabPage 的具体内容未知，这里给出改造方向：

```swift
struct VocabPage: View {
    @ObservedObject private var store = DictionaryStore.shared
    @State private var searchText = ""
    @State private var showAddSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            
            if store.entries.isEmpty {
                emptyState
            } else {
                tagGrid
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var filteredEntries: [DictionaryEntry] {
        if searchText.isEmpty { return store.entries }
        return store.entries.filter { $0.phrase.lowercased().contains(searchText.lowercased()) }
    }
    
    private var tagGrid: some View {
        ScrollView {
            FlowLayout(spacing: 8) {
                ForEach(filteredEntries) { entry in
                    VocabTag(entry: entry)
                }
            }
            .padding(16)
        }
    }
}

struct VocabTag: View {
    let entry: DictionaryEntry
    @ObservedObject private var store = DictionaryStore.shared
    
    var body: some View {
        HStack(spacing: 4) {
            if entry.source == .autoDetected {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
            }
            Text(entry.phrase)
                .font(.system(size: 13))
            if entry.hits > 0 {
                Text("\(entry.hits)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(entry.enabled ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(entry.enabled ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .contextMenu {
            Button(entry.enabled ? "禁用" : "启用") {
                store.setEnabled(id: entry.id, !entry.enabled)
            }
            Divider()
            Button("删除", role: .destructive) {
                store.remove(id: entry.id)
            }
        }
    }
}
```

- [ ] **Step 2: 编译 + Commit**

Run: `swift build`

```bash
git add Sources/flowtype/Settings/VocabPage.swift
git commit -m "feat(vocab): grid tag layout with source indicator"
```

---

## 验收标准

- [ ] `swift build` 编译成功
- [ ] 录音达到限制时自动停止并输出原始文本
- [ ] Capsule 在最后 30 秒显示倒计时并变橙色
- [ ] 设置页有录音时长限制滑块
- [ ] 历史记录页可以导出 JSON/CSV
- [ ] 首页看板显示正确的统计数据（总口述时间、字数、节省时间、平均速度）
- [ ] 按天统计数据正确累加
- [ ] 词典支持自动添加修正词汇（标记为 autoDetected）
- [ ] 词典页面显示来源标记（自动/手动）和网格布局
