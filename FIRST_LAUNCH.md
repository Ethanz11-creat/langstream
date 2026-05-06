# Flowtype 内测版 — 启动与 ASR 技术说明

> Flowtype 由前身项目 langstream 演进而来，继承了完整的 ASR 链路优化经验。

---

## 一、快速开始

### 启动应用

```bash
./scripts/build-app.sh
open build/Flowtype.app
```

### 基本操作

| 操作 | 效果 |
|------|------|
| **双击 `Command` 键** | 开始录音，底部出现悬浮胶囊窗口 |
| **单击 `Command` 键** | 结束录音，输出原始识别文本 |
| **双击 `Command` 键** | 结束录音，输出 LLM 润色后的文本 |

---

## 二、必须开启的两项权限

### 1. 辅助功能权限（监听全局热键）

**用途**：监听全局 `Command` 键双击/单击，触发录音开始/停止。

**开启步骤**：
1. 打开「系统设置 → 隐私与安全性 → 辅助功能」
2. 点击左下角 `+`，选择 `build/Flowtype.app`，勾选启用
3. **完全退出 Flowtype**（菜单栏图标 → 退出），重新打开

> **注意**：ad-hoc 签名应用每次重新构建后会被系统视为"新应用"。如果双击 `Command` 没反应，请删除辅助功能列表中的旧 Flowtype，重新添加并勾选。

### 2. 麦克风权限（录制语音）

**用途**：录制语音并转为文字。

**自动授权**：
- 第一次双击 `Command` 开始录音时，系统会弹出"允许访问麦克风"对话框
- 点击"允许"即可

**如果弹窗没有出现**：
1. **完全退出 Flowtype**，重新打开
2. 再次双击 `Command` 尝试录音
3. 如果还是没有弹窗，检查「系统设置 → 隐私与安全性 → 麦克风」列表中是否有 Flowtype

> **关于 ad-hoc 签名与权限**：内测版使用 ad-hoc 代码签名（无 Apple Developer ID），辅助功能权限每次重建后需重新添加，麦克风权限通常可保留。

---

## 三、故障排查

### 双击 Command 完全没有反应

1. 检查辅助功能权限是否已开启（见上文）
2. 检查菜单栏是否有 Flowtype 图标
3. 查看日志：`cat ~/Library/Logs/flowtype/diagnostic.log`

### 录音界面出现但立刻显示错误

1. 检查麦克风权限是否已开启
2. 检查是否有其他应用占用麦克风
3. 查看日志：`cat ~/Library/Logs/flowtype/diagnostic.log`

### 应用闪退（崩溃）

**可能原因**：TCC 隐私权限缺失导致 `SIGABRT`。

**检查方法**：
```bash
# 查看崩溃报告
ls -lt ~/Library/Logs/DiagnosticReports/ | grep FlowType
```

**已知问题**：若 Info.plist 中缺少 `NSSpeechRecognitionUsageDescription`，调用 `SFSpeechRecognizer` 时会触发 TCC 崩溃。当前版本已修复。

---

## 四、ASR 技术架构

### 4.1 音频链路

```
硬件输入 (44.1/48kHz) → AVAudioEngine tap
    → AVAudioConverter → 16kHz mono Float32
    → AudioFormatConverter → Int16 PCM WAV
    → ASR Provider (TeleSpeech / SenseVoice / AppleSpeech)
```

**关键处理**：
- **重采样**：`AVAudioConverter` 将硬件原生格式转为 16kHz mono Float32
- **增益归一化**：peak < 0.1 时自动增益至 0.95，解决 macOS 内置麦克风音量偏低问题
- **静音修剪**：energy-based 首尾 trimming（threshold=0.01, padding=50ms）
- **引擎预热**：`engine.prepare()` 降低启动延迟，减少首字截断
- **尾帧保护**：`removeTap` 先于 `stop`，避免 guard 语句丢弃最后一帧

### 4.2 Provider 策略

| 策略 | 说明 |
|------|------|
| **并行（parallel）** | 同时请求多个 Provider，取评分最高结果 |
| **兜底（fallback）** | 主 Provider 失败后切换备用 |

**评分维度**（7 维度加权）：
1. 文本长度（非空优先）
2. 中文占比
3. filler 词比例
4. 术语命中率
5. 重复度
6. 置信度（如有）
7. 响应速度

### 4.3 本地离线识别（AppleSpeech）

- 使用 `SFSpeechRecognizer` + `requiresOnDeviceRecognition = true`
- 作为**实时预览**和**离线兜底**
- 数据不出设备，隐私敏感场景可用

### 4.4 后处理管道

```
原始 ASR 文本 → ASRPostProcessor → 最终输出
    ├── 术语纠错（tech_terms.json）
    ├── filler 清洗（filler_words.json）
    ├── 空格规范化
    └── 连续重复字去重
```

**术语词典示例**：
```json
{
  "swift ui": "SwiftUI",
  "lang graph": "LangGraph",
  "tailwind css": "Tailwind CSS",
  "fast api": "FastAPI",
  "rag": "RAG"
}
```

---

## 五、评测方案

### 5.1 评测脚本

```bash
cd tools
pip install requests python-Levenshtein
python evaluate_asr.py
```

- 读取 `tools/eval_data/manifest.json`
- 并发调用 TeleSpeech 和 SenseVoice
- 计算 CER（字符错误率）
- 输出 JSON 结果 + Markdown 报告到 `tools/eval_output/`

### 5.2 历史评测结论（基于合成语音）

| 指标 | TeleSpeech | SenseVoice |
|------|-----------|-----------|
| 平均 CER | **0.284** | 0.501 |
| 超时率 | 0% | **28%** (7/25) |

**关键发现**：
- TeleSpeech 显著优于 SenseVoice，但两者对**英文/代码术语**识别均较差
- 后处理（术语纠错）可部分缓解，但无法恢复完全漏掉的词
- 合成语音评测仅用于框架验证，真实场景需真人录音复测

---

## 六、日志与调试

### 日志位置

```
~/Library/Logs/flowtype/diagnostic.log
```

### 音频导出调试

在 `.env` 中设置（或代码中启用）：
```
LANGSTREAM_DUMP_AUDIO=1
```

录音的 WAV 文件将写入 `~/Library/Logs/flowtype/`，可用于人工核查音频质量。

### 常见日志模式

| 日志 | 含义 |
|------|------|
| `CGEvent tap created and enabled successfully` | 热键监听正常 |
| `FAILED to create CGEvent tap` | 辅助功能权限未授予 |
| `mic status = AVAudioApplicationRecordPermission(rawValue: 1970168948)` | 权限状态为 undetermined（FourCC 编码） |
| `AudioRecorder: Engine start FAILED` | 麦克风被占用或权限被拒绝 |
| `Tap #0 fired: inputFrames=0` | 音频引擎未正确启动，可能权限问题 |

---

## 七、从 langstream 到 Flowtype 的演进

| 维度 | langstream（前身） | Flowtype（当前） |
|------|-------------------|-----------------|
| 热键 | 双击 Option | **双击 Command**（更符合 macOS 习惯） |
| 结束模式 | 单一模式 | **单击=原始 / 双击=润色**（双模式） |
| 配置方式 | `.env` 文件 | **GUI 设置面板** + `ConfigurationStore` |
| 权限提示 | 无 | **启动时自动检测** + 引导弹窗 |
| 代码签名 | ad-hoc | ad-hoc（待接入 Developer ID） |
| 菜单栏 | 无 | **有菜单栏图标** |
| 状态管理 | 简单枚举 | **Combine + AppState 管道** |

---

## 八、构建说明

```bash
# 开发构建
swift build

# 生产构建（生成 .app bundle）
./scripts/build-app.sh

# 运行
open build/Flowtype.app
```

构建脚本会自动：
1. 编译 release 二进制
2. 创建 `.app` bundle 结构
3. 复制资源文件（JSON 词典、图标、状态栏图标）
4. 生成 `Info.plist`（含麦克风 + 语音识别权限声明）
5. ad-hoc 签名 + 清除隔离属性
