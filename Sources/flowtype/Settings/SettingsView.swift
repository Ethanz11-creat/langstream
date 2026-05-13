import SwiftUI

// MARK: - Provider Selector

struct ProviderPicker: View {
    @Binding var provider: String
    @Binding var baseURL: String

    var body: some View {
        Picker("服务商", selection: $provider) {
            ForEach(ProviderPreset.all, id: \.id) { preset in
                Text(preset.name).tag(preset.name)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: provider) { _, newValue in
            if let preset = ProviderPreset.all.first(where: { $0.name == newValue }),
               !preset.isCustom {
                // Auto-fill base URL if current one is empty or matches another preset
                if baseURL.isEmpty || ProviderPreset.all.contains(where: { $0.baseURL == baseURL && !$0.isCustom }) {
                    baseURL = preset.baseURL
                }
            }
        }
    }
}

// MARK: - API Key Field

struct SecureKeyField: View {
    let title: String
    @Binding var key: String
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Group {
                    if isVisible {
                        TextField("输入 API Key", text: $key)
                    } else {
                        SecureField("输入 API Key", text: $key)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                Button(action: { isVisible.toggle() }) {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Model ID Field

struct ModelIDField: View {
    let title: String
    @Binding var model: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            TextField(placeholder, text: $model)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

// MARK: - Install Progress Banner

struct InstallProgressBanner: View {
    @ObservedObject var manager: WhisperServerManager = .shared
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.serverStage.isInstalling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(manager.serverStage.statusTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.orange)
                }
                if let detail = manager.installDetail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if manager.serverStage == .error, let error = manager.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("重试", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("查看日志") { AppLogger.openLogInFinder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Service Config Card

struct ServiceConfigCard: View {
    let title: String
    let subtitle: String
    @Binding var provider: String
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var model: String
    let modelPlaceholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Divider()

            // Provider
            VStack(alignment: .leading, spacing: 6) {
                Text("服务商")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                ProviderPicker(provider: $provider, baseURL: $baseURL)
            }

            // Base URL
            VStack(alignment: .leading, spacing: 6) {
                Text("Base URL")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("https://...", text: $baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            // API Key
            SecureKeyField(title: "API Key", key: $apiKey)

            // Model
            ModelIDField(title: "模型 ID", model: $model, placeholder: modelPlaceholder)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Local Model Status Card

struct LocalModelStatusCard: View {
    @StateObject private var manager = WhisperServerManager.shared
    @State private var cachedModelSize: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: manager.serverStage.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(manager.serverStage.statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.serverStage.statusTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(manager.serverStage.statusColor)
                    Text(statusDetail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if manager.serverStage.canInstall {
                    Button(action: { Task { await manager.install() } }) {
                        Text("一键安装")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if manager.serverStage == .modelLoading || manager.serverStage == .restarting {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 4)
            }

            if manager.serverStage.isInstalling || manager.serverStage == .error {
                InstallProgressBanner(onRetry: { Task { await manager.retry() } })
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(manager.serverStage.statusColor.opacity(0.3), lineWidth: 1)
        )
        .onAppear {
            cachedModelSize = WhisperSetupChecker.modelCacheSize()
        }
    }

    private var statusDetail: String {
        switch manager.serverStage {
        case .ready:
            if let size = cachedModelSize {
                return "mlx-community/whisper-large-v3-turbo (\(size))"
            }
            return "mlx-community/whisper-large-v3-turbo"
        case .modelLoading:
            return "首次加载需要一些时间"
        case .starting, .processStarted, .checking:
            return "请稍候..."
        case .restarting:
            return manager.lastError ?? "正在自动恢复..."
        case .installingVenv, .installingDeps, .downloadingModel:
            return manager.installDetail ?? manager.serverStage.rawValue
        case .needsInstall:
            if WhisperSetupChecker.checkModelCache() {
                return "模型已缓存，仅需安装 Python 依赖"
            }
            return "点击一键安装本地模型环境"
        case .notStarted:
            return "重启应用后自动检查"
        case .error:
            return manager.lastError ?? "未知错误"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var store = ConfigurationStore.shared
    @State private var showSaved = false
    @State private var hasAccessibility = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: Title
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设置")
                            .font(.system(size: 22, weight: .bold))
                        Text("配置语音识别与文本润色服务")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)

                // MARK: ASR Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.blue)
                        Text("语音转文字（ASR）")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }

                    Text("Flowtype 使用本地 MLX Whisper 模型进行语音识别，AppleSpeech 作为兜底方案。所有识别均在本地完成，无需联网。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    // Local Model Status
                    LocalModelStatusCard()

                    // Model ID (read-only display)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("模型 ID")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(store.current.whisperModel)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // Language selector
                    HStack {
                        Text("识别语言")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $store.current.whisperLanguage) {
                            ForEach(WhisperLanguage.allCases, id: \.self) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                        .onChange(of: store.current.whisperLanguage) { _, newLang in
                            // Restart the Whisper server so the new language takes effect immediately.
                            Task {
                                WhisperServerManager.shared.stopServer()
                                await WhisperServerManager.shared.checkAndStart()
                                AppLogger.log("[Settings] Language changed to \(newLang.rawValue), server restarted")
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)

                Divider()
                    .padding(.vertical, 4)

                // MARK: LLM Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.purple)
                        Text("文本润色（LLM）")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }

                    Text("配置大语言模型服务商，用于将口语化的语音识别结果整理成结构化的开发指令。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    ServiceConfigCard(
                        title: "润色模型",
                        subtitle: "用于整理和优化识别结果",
                        provider: $store.current.llmProvider,
                        baseURL: $store.current.llmBaseURL,
                        apiKey: $store.current.llmApiKey,
                        model: $store.current.llmModel,
                        modelPlaceholder: "例如：deepseek-ai/DeepSeek-V3"
                    )

                    // System Prompt Editor
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("系统提示词")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("恢复默认") {
                                store.current.systemPrompt = Configuration.default.systemPrompt
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                        }

                        Text("双击触发键结束录音时，使用此提示词对识别结果进行润色。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        TextEditor(text: $store.current.systemPrompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 120, maxHeight: 200)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 4)

                Divider()
                    .padding(.vertical, 4)

                // MARK: Trigger Key Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.orange)
                        Text("触发键与交互")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("触发键")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Picker("", selection: $store.current.triggerKey) {
                                ForEach(TriggerKey.allCases, id: \.self) { key in
                                    Text(key.displayName).tag(key)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 280)
                        }

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("单击")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("停止录音，输出原始识别文本")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            HStack(spacing: 6) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.purple)
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("双击")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("停止录音，输出润色后的文本")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.purple.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 4)

                Divider()
                    .padding(.vertical, 4)

                // MARK: Permission Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.green)
                        Text("权限与系统状态")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: hasAccessibility ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 16))
                                .foregroundColor(hasAccessibility ? .green : .orange)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(hasAccessibility ? "辅助功能权限已开启" : "辅助功能权限未开启")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(hasAccessibility ? .green : .orange)
                                Text(hasAccessibility
                                     ? "Flowtype 可以监听全局按键触发"
                                     : "需要开启权限才能使用语音输入功能")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Button("打开系统设置") {
                            PermissionHelper.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 4)

                // MARK: Diagnostics
                HStack {
                    Button(action: { AppLogger.openLogInFinder() }) {
                        Label("查看诊断日志", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                    Spacer()
                }
                .padding(.horizontal, 4)

                // Bottom spacer
                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .frame(minWidth: 520, maxWidth: 580, minHeight: 600, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            hasAccessibility = PermissionHelper.checkAccessibility()
        }
        .onChange(of: store.current) { _, _ in
            store.save(store.current)
            WindowManager.shared.reloadHotkey()
            withAnimation(.easeInOut(duration: 0.2)) {
                showSaved = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showSaved = false
                }
            }
        }
        .overlay(alignment: .top) {
            if showSaved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("设置已自动保存")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.9))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
