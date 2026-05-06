# Flowtype

[English](README.md) | **简体中文**

> 语音转 AI 编程提示词

Flowtype 是一款为 AI 编程工作流打造的 macOS 语音输入应用。

它帮助开发者将口头表达的、混乱的、高度口语化的想法，转化为更清晰、结构化的提示词，直接发送给 Codex、Claude Code 等 AI 编程助手。

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
3. **转写** —— 停止录音后，音频发送至 ASR 服务提供商（并行路由 + 质量评分）
4. **精炼** —— LLM 清理填充词、修正识别错误、结构化提示词（仅双击结束时）
5. **注入** —— 结果直接输入到当前活动文本框

## 架构

```
Sources/flowtype/
├── App/
│   ├── FlowTypeApp.swift              # 入口，菜单栏应用
│   └── StatusBarController.swift      # 菜单栏图标与菜单
├── Core/
│   ├── AppState.swift                 # 全局状态管理
│   ├── Configuration.swift            # 配置模型
│   ├── ConfigurationStore.swift       # UserDefaults 持久化（带防抖）
│   ├── EnvMigration.swift             # 一次性 .env → GUI 迁移
│   ├── PipelineOrchestrator.swift     # 端到端音频 → 文本流水线
│   └── AsyncRefiner.swift             # 并行 ASR + LLM 精炼
├── Services/
│   ├── AudioRecorder.swift            # macOS 音频采集（分段式）
│   ├── KeyboardInjector.swift         # 剪贴板粘贴 / HID 逐字注入
│   ├── LLMService.swift               # SiliconFlow SSE 流式客户端
│   └── Speech/
│       ├── SpeechRouter.swift         # 多提供商路由与评分
│       ├── SpeechProvider.swift       # 协议定义
│       ├── ASRPostProcessor.swift     # 填充词过滤、术语纠正
│       ├── ASRResultScorer.swift      # 7 维度质量评分
│       ├── AppleSpeechProvider.swift  # Apple 本地语音识别（预览 + 兜底）
│       ├── TeleSpeechProvider.swift
│       ├── SenseVoiceProvider.swift
│       └── SiliconFlowSpeechProvider.swift
├── Settings/
│   ├── SettingsView.swift             # SwiftUI 设置面板
│   └── SettingsWindowController.swift # 设置窗口宿主
├── UI/
│   └── AudioVisualizer.swift          # 录音可视化反馈
├── Utilities/
│   ├── AudioFormatConverter.swift     # PCM → WAV、音量归一化、静音修剪
│   ├── SegmentMerger.swift            # 去重合并多段结果
│   ├── DotEnv.swift                   # .env 文件解析器（兼容旧版）
│   └── PermissionHelper.swift         # 辅助功能权限检测与引导
├── Resources/
│   ├── tech_terms.json                # 技术术语纠正表
│   └── filler_words.json              # 填充词词典
```

## 环境要求

- macOS 14+
- Swift 6.2+
- [SiliconFlow API Key](https://cloud.siliconflow.cn/account/ak)（用于 LLM 精炼和语音识别）

## 快速开始

```bash
# 1. 克隆仓库
git clone <仓库地址>
cd Flowtype

# 2. 构建
swift build

# 3. 运行
swift run FlowType
```

或构建 `.app` 应用包：

```bash
./scripts/build-app.sh
open build/Flowtype.app
```

## 配置说明

所有设置通过 **设置界面** 管理（点击菜单栏图标 → 设置，或按 `Cmd + ,`）：

| 分类 | 设置项 |
|------|--------|
| **主识别模型** | 服务商、Base URL、API Key、模型 ID |
| **兜底识别模型** | 服务商、Base URL、API Key、模型 ID |
| **文本润色模型** | 服务商、Base URL、API Key、模型 ID |
| **触发键** | Fn / Control / Option / Command |
| **识别策略** | 并行双发（同时运行两个模型，评分选优）/ 主模型优先（失败时回退） |

设置会自动保存到 `UserDefaults`。如果存在 `.env` 文件，首次启动时会**自动迁移一次**，此后以 GUI 设置为准。

## ASR 评估

`tools/` 目录包含 ASR 提供商的评估框架：

```bash
cd tools
cp .env ../.env  # 确保 API Key 可用
python evaluate_asr.py --output-dir eval_output/
```

数据集详情见 [`tools/eval_data/README.md`](tools/eval_data/README.md)。

## 许可证

MIT
