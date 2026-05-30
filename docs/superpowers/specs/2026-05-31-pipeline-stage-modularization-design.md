# FlowType Pipeline Stage 模块化架构设计

**Date:** 2026-05-31
**Scope:** 以 Phase 1 四个功能为载体，重构 PipelineOrchestrator，建立可插拔的 Stage 管道架构
**Status:** Approved

---

## 1. Background & Goals

### Current Problems

- `PipelineOrchestrator.swift` (726 lines) is a **God Class**: manages state machine, recording, ASR, LLM polish, keyboard injection, error handling, history tracking, and analytics all in one file
- `SessionController` hardcodes all dependencies (`AudioRecorder`, `SpeechRouter`, `LLMService`, `AppleSpeechProvider`) — no abstraction
- `LLMService` mixes too many responsibilities: prompt composition, provider resolution, fallback, connection test, streaming infrastructure
- New features require **modifying existing code** inside the orchestrator, creating technical debt

### Design Goals

1. **Modularity**: Each pipeline phase is an independent, testable unit with a single responsibility
2. **Extensibility**: New features are added as new files + one line of registration, zero modification to existing stages
3. **Phase 2/3 Ready**: App-Aware Profiles, Voice Snippets, Voice Commands, MCP Server all have clear extension points
4. **Incremental Updates**: After the one-time refactor, every subsequent feature follows the same "add file → register → ship" pattern

---

## 2. Architecture Overview

### 2.1 Core Abstraction: PipelineStage Protocol

```swift
// MARK: - Stage Payload (strongly-typed inter-stage data)

enum StagePayload {
    case empty
    case audio(samples: [Float], previewText: String)   // RecordingStage → ASRStage
    case transcript(String)                              // ASRStage → PostProcessStage
    case processed(String, raw: String)                  // PostProcessStage → PolishStage
    case polished(String, raw: String)                   // PolishStage → InjectionStage
}

// MARK: - Stage Result

enum StageResult {
    case `continue`(StagePayload)        // Proceed to next stage
    case skip(to: String, StagePayload)  // Jump to named stage (e.g., Snippet match → direct inject)
    case suspend(ErrorRecoveryContext)   // Pause pipeline for user interaction
    case complete                        // Pipeline finished successfully
}

// MARK: - Error Recovery Context

struct ErrorRecoveryContext {
    let failedStage: String
    let error: Error
    let rawText: String?          // For "Copy Raw" action
    let retryable: Bool           // Whether retry is supported
}

// MARK: - Pipeline Stage Protocol

protocol PipelineStage {
    var name: String { get }
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult
}
```

### 2.2 Session Context (Cross-Stage Shared State)

```swift
@MainActor
final class SessionContext {
    let sessionID: UInt64
    var usePolish: Bool = false
    var recordingStartTime: Date?
    
    // Injected by middleware stages for downstream consumption
    var appProfile: AppProfile?
    var clipboardContent: String?
    var selectedText: String?
    
    // Onboarding demo injection override
    var injectionHandler: ((String) -> Void)?
    
    // State publishing for UI and observers
    let statePublisher = PassthroughSubject<SessionState, Never>()
    
    init(sessionID: UInt64) { ... }
}
```

**Design principle:** `SessionContext` is the ONLY mutable shared state. All stages read from it or write to it. No hidden dependencies.

### 2.3 Session Observer (Lifecycle Events)

```swift
protocol SessionObserver: AnyObject {
    func sessionDidTransition(
        from oldState: SessionState,
        to newState: SessionState,
        context: SessionContext
    )
}
```

Observers are for **side effects that don't participate in data flow**: audio feedback, analytics, logging, history persistence.

---

## 3. SessionController as Orchestrator

`SessionController` becomes a thin orchestrator with zero business logic:

```swift
@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()
    
    private let pipeline: [PipelineStage]
    private let observers: [SessionObserver]
    
    @Published private(set) var sessionState: SessionState = .idle
    
    // Error recovery state
    private var suspendedContext: ErrorRecoveryContext?
    private var suspendedPayload: StagePayload?
    private var suspendedStageIndex: Int?
    
    init(
        pipeline: [PipelineStage] = PipelineRegistry.defaultPipeline(),
        observers: [SessionObserver] = PipelineRegistry.defaultObservers()
    ) {
        self.pipeline = pipeline
        self.observers = observers
    }
    
    // MARK: - Public API (stable, callers don't change)
    
    func startRecording() { ... }
    func endRecording(withPolish: Bool) { ... }
    func cancel() { ... }
    func retryPolish() { ... }
    func dismissError() { ... }
    
    // MARK: - Core Orchestration Loop
    
    private func executeStage(at index: Int, payload: StagePayload, context: SessionContext) {
        guard index < pipeline.count else { 
            return transition(to: .idle, context: context) 
        }
        
        Task {
            let stage = pipeline[index]
            let result = await stage.execute(payload: payload, context: context)
            
            switch result {
            case .continue(let nextPayload):
                executeStage(at: index + 1, payload: nextPayload, context: context)
                
            case .skip(let targetName, let nextPayload):
                if let targetIndex = pipeline.firstIndex(where: { $0.name == targetName }) {
                    executeStage(at: targetIndex, payload: nextPayload, context: context)
                }
                
            case .suspend(let recovery):
                suspendedContext = recovery
                suspendedPayload = payload
                suspendedStageIndex = index
                transition(to: .error(recovery.error.localizedDescription), context: context)
                
            case .complete:
                transition(to: .idle, context: context)
            }
        }
    }
    
    // MARK: - Error Recovery Actions
    
    func retryCurrentStage() {
        guard let payload = suspendedPayload,
              let index = suspendedStageIndex,
              let context = currentContext else { return }
        clearSuspension()
        executeStage(at: index, payload: payload, context: context)
    }
    
    func copyRawText() {
        guard let rawText = suspendedContext?.rawText else { return }
        NSPasteboard.general.setString(rawText, forType: .string)
    }
    
    // MARK: - Private
    
    private func transition(to newState: SessionState, context: SessionContext) {
        let oldState = sessionState
        sessionState = newState
        observers.forEach { 
            $0.sessionDidTransition(from: oldState, to: newState, context: context) 
        }
    }
}
```

---

## 4. Default Pipeline Stages

### 4.1 RecordingStage

```swift
struct RecordingStage: PipelineStage {
    let audioRecorder = AudioRecorder()
    let appleSpeechProvider = AppleSpeechProvider()
    
    var name: String { "RecordingStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        // 1. Request microphone permission
        // 2. Start AudioRecorder with selected device
        // 3. Start AppleSpeech real-time preview streaming
        // 4. Publish amplitude updates via context.statePublisher
        // 5. Wait until cancelled (by endRecording or cancel)
        // 6. Stop recording, collect samples + final preview text
        
        let samples = audioRecorder.takeAccumulatedSamples()
        let previewText = appleSpeechProvider.stopStreamingRecognition()
        return .continue(.audio(samples: samples, previewText: previewText))
    }
}
```

### 4.2 ASRStage

```swift
struct ASRStage: PipelineStage {
    let speechRouter = SpeechRouter()
    
    var name: String { "ASRStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .audio(let samples, let previewText) = payload else {
            return .suspend(ErrorRecoveryContext(failedStage: name, error: ASRError.invalidInput, rawText: nil, retryable: false))
        }
        
        var finalText = ""
        
        if speechRouter.qwenProvider.isLoaded && !samples.isEmpty {
            do {
                finalText = try await speechRouter.qwenProvider.transcribe(
                    samples: samples, language: nil, context: nil
                )
            } catch {
                // Qwen failed, fall through to AppleSpeech
                finalText = ""
            }
        }
        
        if finalText.isEmpty && !previewText.isEmpty {
            finalText = previewText
        }
        
        guard !finalText.isEmpty else {
            return .suspend(ErrorRecoveryContext(failedStage: name, error: ASRError.emptyResult, rawText: nil, retryable: false))
        }
        
        return .continue(.transcript(finalText))
    }
}
```

### 4.3 PostProcessStage

```swift
struct PostProcessStage: PipelineStage {
    var name: String { "PostProcessStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .transcript(let text) = payload else {
            return .continue(payload)
        }
        
        let processed = ASRPostProcessor.process(text)
        let result = processed.isEmpty ? text.trimmingCharacters(in: .whitespaces) : processed
        return .continue(.processed(result, raw: text))
    }
}
```

### 4.4 PolishStage

```swift
struct PolishStage: PipelineStage {
    let llmService = LLMService()
    
    var name: String { "PolishStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .processed(let text, let raw) = payload else {
            return .continue(payload)
        }
        
        guard context.usePolish else {
            return .continue(.polished(text, raw: raw))
        }
        
        let prompt = LLMService.composeSystemPrompt(fallback: ConfigurationStore.shared.current.systemPrompt)
        
        do {
            let stream = await llmService.polishText(text, systemPrompt: prompt)
            var accumulated = ""
            for try await chunk in stream {
                accumulated += chunk
                context.statePublisher.send(.polishing(preview: accumulated))
            }
            
            let finalText = accumulated.isEmpty || accumulated == text ? text : accumulated
            return .continue(.polished(finalText, raw: raw))
            
        } catch {
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: error,
                rawText: raw,
                retryable: true
            ))
        }
    }
}
```

### 4.5 InjectionStage

```swift
struct InjectionStage: PipelineStage {
    var name: String { "InjectionStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .polished(let text, _) = payload else {
            return .continue(payload)
        }
        
        // Onboarding demo: bypass injection, deliver to callback
        if let handler = context.injectionHandler {
            handler(text)
            return .complete
        }
        
        // Normal: keyboard injection
        do {
            try await KeyboardInjector.insertText(text)
            return .complete
        } catch {
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: error,
                rawText: text,
                retryable: false
            ))
        }
    }
}
```

---

## 5. Pipeline Registry

Central registration point for all stages and observers. This is the ONLY file that changes when adding new features.

```swift
// PipelineRegistry.swift
enum PipelineRegistry {
    
    static func defaultPipeline() -> [PipelineStage] {
        [
            RecordingStage(),
            ASRStage(),
            PostProcessStage(),
            PolishStage(),
            InjectionStage(),
        ]
    }
    
    static func defaultObservers() -> [SessionObserver] {
        [
            AudioFeedbackObserver(isEnabled: { ConfigurationStore.shared.current.enableAudioFeedback }),
            HistoryObserver(),
            AnalyticsObserver(),
        ]
    }
    
    // MARK: - Phase 2 Extensions (add one line each)
    
    static func pipelineWithAppContext() -> [PipelineStage] {
        var stages = defaultPipeline()
        // Insert AppContextMiddleware before PolishStage
        if let idx = stages.firstIndex(where: { $0 is PolishStage }) {
            stages.insert(AppContextMiddleware(), at: idx)
        }
        return stages
    }
    
    static func pipelineWithSnippets() -> [PipelineStage] {
        var stages = defaultPipeline()
        // Insert SnippetStage after ASRStage
        if let idx = stages.firstIndex(where: { $0 is ASRStage }) {
            stages.insert(SnippetStage(), at: idx + 1)
        }
        return stages
    }
}
```

---

## 6. Phase 1 Features Integration

### 6.1 Audio Feedback (Toggleable)

Implemented as a `SessionObserver`, not a Stage. Observers respond to lifecycle events without participating in data flow.

```swift
struct AudioFeedbackObserver: SessionObserver {
    let isEnabled: () -> Bool
    
    func sessionDidTransition(from oldState: SessionState, to newState: SessionState, context: SessionContext) {
        guard isEnabled() else { return }
        
        switch (oldState, newState) {
        case (_, .recording):
            SoundFeedback.playRecordingStart()
        case (.recording, .processing):
            SoundFeedback.playRecordingStop()
        case (_, .error):
            SoundFeedback.playError()
        default:
            break
        }
    }
}
```

**Why Observer:** Audio feedback is a side effect triggered by state changes. It doesn't transform data and doesn't need to block the pipeline.

### 6.2 Retryable Error Cards

Implemented via `StageResult.suspend`:

1. `PolishStage` catches LLM error → returns `.suspend(ErrorRecoveryContext(..., retryable: true))`
2. `SessionController` stores suspension state → transitions to `.error` state
3. UI renders `ErrorCardView` with action buttons
4. User taps "Retry Polish" → `SessionController.retryCurrentStage()` resumes pipeline from `PolishStage`
5. User taps "Copy Raw" → `SessionController.copyRawText()` copies `recovery.rawText` to clipboard
6. User taps "Dismiss" → `SessionController.dismissError()` clears state → `.idle`

```swift
// CapsuleView / FloatingPanel
struct ErrorCardView: View {
    let context: ErrorRecoveryContext
    let onRetry: () -> Void
    let onCopyRaw: () -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(context.error.localizedDescription)
                .font(.headline)
            
            HStack(spacing: 12) {
                if context.retryable {
                    Button("重试润色", action: onRetry)
                }
                if context.rawText != nil {
                    Button("复制原文", action: onCopyRaw)
                }
                Button("忽略", action: onDismiss)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}
```

### 6.3 Interactive Onboarding Demo

Create a custom pipeline for onboarding that replaces `InjectionStage` with `DemoInjectionStage`:

```swift
struct OnboardingPipeline {
    static func makeStages(demoHandler: @escaping (String) -> Void) -> [PipelineStage] {
        var stages = PipelineRegistry.defaultPipeline()
        if let idx = stages.firstIndex(where: { $0 is InjectionStage }) {
            stages[idx] = DemoInjectionStage(handler: demoHandler)
        }
        return stages
    }
}

struct DemoInjectionStage: PipelineStage {
    let handler: (String) -> Void
    var name: String { "DemoInjectionStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .polished(let text, _) = payload else { return .continue(payload) }
        handler(text)
        return .complete
    }
}
```

**OnboardingView usage:**

```swift
struct OnboardingStep4View: View {
    @State private var demoResult = ""
    
    private let demoController = SessionController(
        pipeline: OnboardingPipeline.makeStages { text in
            self.demoResult = text
        }
    )
    
    var body: some View {
        VStack {
            TextEditor(text: $demoResult)
                .frame(height: 100)
            
            Button("双击 ⌘ 开始录音") {
                demoController.startRecording()
            }
        }
    }
}
```

### 6.4 Settings Search

Pure UI layer feature. Implemented as an independent search module with a settings registry.

```swift
// SettingRegistry.swift
struct SettingEntry: Identifiable {
    let id = UUID()
    let title: String
    let keywords: [String]
    let category: String
    let view: AnyView
}

class SettingRegistry {
    static let shared = SettingRegistry()
    private var entries: [SettingEntry] = []
    
    func register(_ entry: SettingEntry) {
        entries.append(entry)
    }
    
    func search(_ query: String) -> [SettingMatch] {
        let lowerQuery = query.lowercased()
        return entries.compactMap { entry in
            let score = matchScore(entry: entry, query: lowerQuery)
            return score > 0 ? SettingMatch(entry: entry, score: score) : nil
        }.sorted { $0.score > $1.score }
    }
    
    private func matchScore(entry: SettingEntry, query: String) -> Int {
        var score = 0
        if entry.title.lowercased().contains(query) { score += 10 }
        for keyword in entry.keywords {
            if keyword.lowercased().contains(query) { score += 5 }
        }
        if entry.category.lowercased().contains(query) { score += 2 }
        return score
    }
}

struct SettingMatch {
    let entry: SettingEntry
    let score: Int
}
```

**Why a registry:** Future settings pages (from Phase 2/3 features) can self-register without modifying the search UI code.

---

## 7. Phase 2/3 Extension Points

Each Phase 2/3 feature is implemented as **one new file + one line in PipelineRegistry**.

### 7.1 Phase 2.1: App-Aware Profiles

```swift
// AppContextMiddleware.swift
struct AppContextMiddleware: PipelineStage {
    var name: String { "AppContextMiddleware" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        context.appProfile = AppProfileStore.shared.profile(for: bundleID)
        return .continue(payload)
    }
}
```

**Registration:** `stages.insert(AppContextMiddleware(), at: polishStageIndex)`

**PolishStage reads:** `context.appProfile` to customize the system prompt per app.

### 7.2 Phase 2.2: Clipboard Context

```swift
struct ClipboardContextStage: PipelineStage {
    var name: String { "ClipboardContextStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard ConfigurationStore.shared.current.enableClipboardContext else {
            return .continue(payload)
        }
        if let clipboard = NSPasteboard.general.string(forType: .string) {
            context.clipboardContent = clipboard
        }
        return .continue(payload)
    }
}
```

### 7.3 Phase 2.3: Voice Snippets

```swift
struct SnippetStage: PipelineStage {
    var name: String { "SnippetStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .transcript(let text) = payload else { return .continue(payload) }
        
        if let snippet = SnippetStore.shared.match(text) {
            let expanded = snippet.expand(variables: [
                "DATE": DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none),
                "CLIPBOARD": context.clipboardContent ?? "",
                "TIME": DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short),
            ])
            return .skip(to: "InjectionStage", .polished(expanded, raw: text))
        }
        
        return .continue(.transcript(text))
    }
}
```

### 7.4 Phase 3.1: Voice Commands

```swift
struct VoiceCommandStage: PipelineStage {
    var name: String { "VoiceCommandStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .transcript(let text) = payload else { return .continue(payload) }
        
        if let command = CommandParser.shared.parse(text) {
            await CommandDispatcher.shared.execute(command)
            return .complete  // Command executed, pipeline ends
        }
        
        return .continue(.transcript(text))
    }
}
```

### 7.5 Phase 3.2: Selected Text as Context

```swift
struct SelectedTextStage: PipelineStage {
    var name: String { "SelectedTextStage" }
    
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .empty = payload else { return .continue(payload) }
        
        if let selected = await AccessibilityHelper.getSelectedText() {
            context.selectedText = selected
        }
        
        return .continue(.empty)
    }
}
```

### 7.6 Phase 3.3: MCP Server

MCP Server is an **independent entry point**, not a pipeline modification:

```swift
actor MCPServer {
    func dictate() async throws -> String {
        let pipeline: [PipelineStage] = [
            RecordingStage(),
            ASRStage(),
            PostProcessStage(),
        ]
        let controller = SessionController(pipeline: pipeline)
        // Start recording, wait for result, return transcript
        // (No injection — returns text to caller)
    }
}
```

**Reuses existing stages** without modification.

---

## 8. File Structure Changes

### Before

```
Sources/flowtype/
├── Core/
│   └── PipelineOrchestrator.swift          # 726 lines, God Class
├── Services/
│   ├── LLMService.swift                     # Mixed responsibilities
│   └── Speech/...
```

### After

```
Sources/flowtype/
├── Core/
│   ├── Pipeline/
│   │   ├── PipelineStage.swift              # Protocol + types
│   │   ├── PipelineRegistry.swift           # Registration
│   │   ├── SessionContext.swift             # Shared state
│   │   ├── SessionController.swift          # Orchestrator (thin)
│   │   ├── Stages/
│   │   │   ├── RecordingStage.swift
│   │   │   ├── ASRStage.swift
│   │   │   ├── PostProcessStage.swift
│   │   │   ├── PolishStage.swift
│   │   │   └── InjectionStage.swift
│   │   └── Observers/
│   │       ├── SessionObserver.swift        # Protocol
│   │       ├── AudioFeedbackObserver.swift  # Feature 1
│   │       ├── HistoryObserver.swift
│   │       └── AnalyticsObserver.swift
│   ├── SessionState.swift                   # Extracted from PipelineOrchestrator
│   └── ... (other Core files)
├── Features/
│   ├── Onboarding/
│   │   ├── OnboardingPipeline.swift         # Feature 3
│   │   └── DemoInjectionStage.swift
│   └── SettingsSearch/
│       ├── SettingRegistry.swift            # Feature 4
│       └── SettingsSearchView.swift
└── Services/
    ├── LLMService.swift                     # Cleaned up
    └── Speech/...
```

---

## 9. Incremental Update Guarantee

### The Contract

After this refactor, every new feature follows:

1. **Add one file** implementing `PipelineStage` or `SessionObserver`
2. **Register one line** in `PipelineRegistry`
3. **Zero modification** to existing stages

### Why This Works

- **Protocol stability:** `PipelineStage` and `StagePayload` are the only shared contracts. They are designed to be stable — adding new cases to `StagePayload` is a compile-time breaking change that forces explicit handling.
- **No hidden dependencies:** All shared state is in `SessionContext`. Stages don't import each other.
- **Test isolation:** Each stage can be unit tested with a mock `SessionContext`.

### Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Protocol needs to change | `StagePayload` enum cases are additive only; new features use `SessionContext` for custom data |
| Stage ordering matters | `PipelineRegistry` makes ordering explicit and centralized |
| Performance overhead of abstraction | Protocol dispatch overhead is negligible compared to I/O (ASR, LLM network) |

---

## 10. Implementation Order

1. **Extract foundation types** (`PipelineStage`, `StagePayload`, `StageResult`, `SessionContext`, `SessionObserver`)
2. **Migrate existing stages** one by one from `PipelineOrchestrator`
3. **Rewrite `SessionController`** as thin orchestrator with stable public API
4. **Implement Audio Feedback** (Observer)
5. **Implement Retryable Error** (suspend/resume in SessionController + UI)
6. **Implement Onboarding Demo** (custom pipeline + DemoInjectionStage)
7. **Implement Settings Search** (SettingRegistry + UI)
8. **Verify:** All four features work, public API unchanged, `swift build` passes
