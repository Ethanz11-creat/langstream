# Flowtype

[English](README.md) | **简体中文**

> 语音转 AI 编程提示词

Flowtype 是一款为 AI 编程工作流打造的 macOS 语音输入应用。

它帮助开发者将口头表达的、混乱的、高度口语化的想法，转化为更清晰、结构化的提示词，直接发送给 Codex、Claude Code 等 AI 编程助手。

## 关于本分支 (`flowtype-local`)

本分支采用 **Qwen3-ASR + 模块化 Pipeline** 架构。与 `main` 分支的主要区别：

- **语音识别引擎**：直接使用 [`speech-swift`](https://github.com/soniqo/speech-swift)（基于 MLX 的 Qwen3-ASR，约 300MB 4-bit 量化）—— 无需 Python 服务
- **流水线架构**：基于阶段的模块化流水线（录音 → ASR → 后处理 → 润色 → 注入），通过 `SessionContext` 传递状态
- **无 Python 依赖**：不需要 `uv`、不需要 Whisper Python 服务、不需要 `setup_whisper.sh`
- **需要 macOS 15+**（Swift 6.2）

> **GitHub 上缺少的文件**：`mlx.metallib`（119MB Metal 着色器库）超出 GitHub 文件大小限制。详见下方 [换电脑继续开发](#换电脑继续开发)。

## 为什么用 Flowtype

- **语音比打字快** —— 以自然语速描述想法
- **口语表达更流畅** —— 比打字更连贯、更有表现力
- **原始转写不够用** —— 语音识别结果对 AI 编程工具来说太口语化
- **Flowtype 弥合鸿沟** —— 一键将语音转化为结构化、面向编程的指令文本

## 核心交互

| 操作 | 结果 |
|------|------|
| 双击 `Command` | 开始录音（底部出现悬浮胶囊窗口） |
| 单击 `Command`（录音中） | 结束录音，输出原始语音文本 |
| 双击 `Command`（录音中） | 结束录音，输出 LLM 润色后的结构化提示词 |

## 使用场景

- 一边 review 代码，一边口述功能想法
- 将粗略的实现思路转化为可直接使用的编程提示词
- 快速为 AI 编程工具起草 UI、工作流和产品需求
- 大声讨论架构决策，然后直接粘贴整理后的结果

## 工作流程

1. **录音** —— 双击 `Command` 开始语音捕获（底部出现悬浮胶囊窗口）
2. **实时预览** —— Apple 本地语音识别实时显示转写文字
3. **转写** —— 停止录音后，音频发送至本地 Qwen3-ASR 模型进行高质量识别；模型不可用时自动回退至 AppleSpeech
4. **精炼** —— LLM 清理填充词、修正识别错误、结构化提示词（仅双击结束时）
5. **注入** —— 结果直接输入到当前活动文本框

## 架构

```
Sources/flowtype/
├── App/
│   ├── FlowTypeApp.swift              # 入口，菜单栏应用
│   └── StatusBarController.swift      # 菜单栏图标与菜单
├── Core/
│   ├── Configuration.swift            # 配置模型
│   ├── ConfigurationStore.swift       # UserDefaults 持久化（带防抖）
│   ├── PipelineOrchestrator.swift     # SessionController + SessionState 状态机
│   ├── Pipeline/                      # 模块化流水线阶段架构
│   │   ├── SessionContext.swift       # 在各阶段间传递的不可变上下文
│   │   ├── PipelineStage.swift        # 阶段协议
│   │   ├── PipelineRegistry.swift     # 阶段注册
│   │   ├── Observers/                 # 实时状态观察
│   │   └── Stages/                    # 各流水线阶段
│   │       ├── RecordingStage.swift   # 音频采集
│   │       ├── ASRStage.swift         # Qwen3-ASR / AppleSpeech 识别
│   │       ├── PostProcessStage.swift # 填充词过滤、术语纠正
│   │       ├── PolishStage.swift      # LLM 润色
│   │       └── InjectionStage.swift   # 键盘文本注入
│   ├── DailyStats.swift               # 使用统计聚合
│   ├── DictationHistory.swift         # 历史记录持久化
│   └── Dictionary.swift               # 用户词汇表 & 自动检测纠正
├── Services/
│   ├── AudioRecorder.swift            # macOS 音频采集（16kHz 单声道 Float32）
│   ├── AudioDevice.swift              # 输入设备枚举与选择
│   ├── KeyboardInjector.swift         # 剪贴板粘贴 / CGEvent 逐字注入
│   ├── LLMService.swift               # OpenAI 兼容 SSE 流式客户端
│   ├── WindowManager.swift            # CGEventTap 热键设置
│   └── Speech/
│       ├── SpeechRouter.swift         # 提供商路由（QwenASR → AppleSpeech 兜底）
│       ├── SpeechProvider.swift       # 协议定义
│       ├── QwenASRProvider.swift      # 本地 Qwen3-ASR MLX 模型（约 300MB 4-bit）
│       ├── QwenModelState.swift       # 模型加载状态管理
│       ├── AppleSpeechProvider.swift  # Apple 本地语音识别（预览 + 兜底）
│       └── ASRPostProcessor.swift     # 填充词过滤、重复检测、术语纠正
├── Settings/
│   ├── SettingsView.swift             # SwiftUI 设置面板
│   ├── SettingsWindowController.swift # 设置窗口宿主
│   ├── MainWindowView.swift           # 设置标签页容器
│   ├── OverviewPage.swift             # 每日统计仪表盘
│   ├── HistoryPage.swift              # 听写历史与导出
│   ├── VocabPage.swift                # 个人词典管理
│   └── StylePage.swift                # UI 样式自定义
├── Features/
│   └── Onboarding/
│       └── OnboardingPipeline.swift   # 首次启动引导
├── UI/
│   ├── CapsuleView.swift              # 录音胶囊窗口
│   ├── FloatingPanel.swift            # 面板窗口宿主
│   └── AudioVisualizer.swift          # 录音可视化反馈
├── Utilities/
│   ├── AppLogger.swift                # 文件诊断日志
│   ├── AudioFormatConverter.swift     # PCM 格式转换
│   ├── KeychainHelper.swift           # API 密钥安全存储
│   ├── PermissionHelper.swift         # 辅助功能权限检测与引导
│   ├── SoundFeedback.swift            # 录音事件音频反馈
│   └── UnsafeCell.swift               # 线程安全值包装器
└── Resources/
    ├── tech_terms.json                # 技术术语纠正表
    ├── filler_words.json              # 填充词词典
    ├── AppIcon.icns                   # 应用图标
    └── status_bar_icon*.png           # 状态栏图标
```

## 模型选型

Flowtype 通过 [`speech-swift`](https://github.com/soniqo/speech-swift) 包使用 [Qwen3-ASR](https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit) —— 一个针对 Apple Silicon MLX 优化的 Qwen3 语音识别模型。

### 为什么选 Qwen3-ASR

- **体积小巧** — 约 300MB 4-bit 量化模型，远轻于 Whisper Large v3（约 1.6GB）
- **快速加载** — 直接通过 MLX 在 Swift 中加载，无 Python 服务开销
- **原生 MLX** — 通过 Metal 在 Apple Silicon GPU/神经网络引擎上运行
- **识别质量** — 在中英文代码混排和技术词汇上表现优秀

### 为什么选 MLX

[MLX](https://github.com/ml-explore/mlx) 是 Apple 专为 Apple Silicon 打造的机器学习框架：

- **统一内存** — 模型权重直接存于系统内存，无显存拷贝开销
- **原生 Metal 后端** — 计算着色器直接在 GPU / 神经网络引擎上运行
- **低延迟** — 无需网络往返，转写完全在本地完成
- **隐私** — 音频数据永不离开设备

## 环境要求

- macOS 15+
- Swift 6.2+
- Apple Silicon（M1 或更新机型）—— 本地 MLX 推理所需
- [SiliconFlow API Key](https://cloud.siliconflow.cn/account/ak) —— 仅用于 LLM 文本润色（语音识别已完全本地运行）

## 快速开始

### 1. 构建

```bash
swift build
```

### 2. 提供 `mlx.metallib`（Qwen3-ASR GPU 推理必需）

SPM 无法编译 Metal 着色器。`mlx.metallib` 文件必须从 Python `mlx` 安装目录复制到二进制文件旁边：

```bash
# 安装 Python mlx（如尚未安装）
pip install mlx

# 查找并复制 metallib
python3 -c "import mlx, pathlib; print(pathlib.Path(mlx.__file__).parent / 'lib' / 'mlx.metallib')"
# 然后将上面打印的路径复制到：
cp <上面打印的路径> .build/debug/
```

常见位置：
- `~/.cache/uv/archive-v0/*/mlx/lib/mlx.metallib`（使用 `uv` 时）
- `~/.cache/pip/*/mlx/lib/mlx.metallib`（使用 `pip` 时）

> ⚠️ **没有 `mlx.metallib`，Qwen3-ASR 将在运行时崩溃。** 该文件因体积（119MB > GitHub 100MB 限制）被故意排除在版本控制外。

### 3. 运行

```bash
swift run FlowType
```

或构建 `.app` 应用包（如能找到 `mlx.metallib` 会自动复制）：

```bash
./scripts/build-app.sh
open build/Flowtype.app
```

## 配置说明

所有设置通过 **设置界面** 管理（点击菜单栏图标 → 设置，或按 `Cmd + ,`）：

| 分类 | 设置项 |
|------|--------|
| **本地语音识别** | 模型加载状态、语言选择（自动 / 中文 / English） |
| **文本润色模型** | 服务商、Base URL、API Key、模型 ID |
| **触发键** | Fn / Control / Option / Command |
| **历史记录** | 听写历史，支持 JSON/CSV 导出 |
| **词典** | 个人词汇表 & 自动检测纠正 |

设置会自动保存到 `UserDefaults`。如果存在 `.env` 文件，首次启动时会**自动迁移一次**，此后以 GUI 设置为准。

### 语音识别回退行为

| 场景 | 行为 |
|------|------|
| Qwen3-ASR 模型已加载 | Qwen3-ASR 提供最终转写结果 |
| Qwen3-ASR 未加载 / 崩溃 | AppleSpeech 提供最终转写结果 |
| 实时预览 | AppleSpeech 在录音过程中流式输出 |

## 换电脑继续开发

在新 Mac 上克隆本仓库后，以下内容**未包含在 Git 中**，需要手动准备：

1. **克隆并构建**
   ```bash
   git clone -b flowtype-local https://github.com/Ethanz11-creat/Flowtype.git
   cd Flowtype
   swift build
   ```

2. **安装 Python `mlx`** 以获取 `mlx.metallib`：
   ```bash
   pip install mlx
   ```

3. **复制 `mlx.metallib`** 到 debug 二进制文件旁边：
   ```bash
   python3 -c "import mlx, pathlib; print(pathlib.Path(mlx.__file__).parent / 'lib' / 'mlx.metallib')"
   cp <上面的路径> .build/debug/
   ```

4. **运行**
   ```bash
   swift run FlowType
   ```

`.gitignore` 已排除：`build/`、`FlowType.app/`、`FlowType` 二进制文件、`*.dmg`、以及 `.build/`（SPM 构建目录）。Git 中仅追踪源代码和资源文件。

## 许可证

MIT
