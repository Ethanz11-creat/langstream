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
    @StateObject private var serverManager = WhisperServerManager.shared
    @State private var isInstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                statusIcon
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(statusColor)
                    Text(statusDetail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if serverManager.serverStage == .envMissing {
                    Button(action: runInstallScript) {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60, height: 20)
                        } else {
                            Text("一键安装")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isInstalling)
                }
            }

            if serverManager.serverStage == .modelLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 4)
            }

            // Language selector removed from here, moved to parent SettingsView
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusIcon: some View {
        switch serverManager.serverStage {
        case .modelLoaded:
            return Image(systemName: "checkmark.circle.fill")
        case .modelLoading, .starting, .processStarted, .checking:
            return Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
        case .envMissing, .notStarted:
            return Image(systemName: "exclamationmark.circle.fill")
        case .error:
            return Image(systemName: "xmark.circle.fill")
        }
    }

    private var statusColor: Color {
        switch serverManager.serverStage {
        case .modelLoaded:
            return .green
        case .modelLoading, .starting, .processStarted, .checking:
            return .orange
        case .envMissing, .notStarted:
            return .red
        case .error:
            return .red
        }
    }

    private var statusTitle: String {
        switch serverManager.serverStage {
        case .modelLoaded:
            return "本地模型已就绪"
        case .modelLoading:
            return "模型加载中..."
        case .starting, .processStarted, .checking:
            return "服务启动中..."
        case .envMissing:
            return "本地 ASR 未安装"
        case .notStarted:
            return "本地 ASR 未启动"
        case .error:
            return "服务启动失败"
        }
    }

    private var statusDetail: String {
        switch serverManager.serverStage {
        case .modelLoaded:
            return "mlx-community/whisper-large-v3-turbo"
        case .modelLoading:
            return "首次加载需要一些时间"
        case .starting, .processStarted, .checking:
            return "请稍候..."
        case .envMissing:
            return "点击一键安装本地模型环境"
        case .notStarted:
            return "重启应用后自动检查"
        case .error:
            return serverManager.lastError ?? "未知错误"
        }
    }

    private func runInstallScript() {
        isInstalling = true
        Task {
            await installLocalASR()
            await MainActor.run {
                isInstalling = false
            }
        }
    }

    private func installLocalASR() async {
        guard let scriptURL = WhisperSetupChecker.serverDirectory()?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/setup_whisper.sh") else {
            await MainActor.run {
                serverManager.lastError = "找不到安装脚本"
            }
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                // Install succeeded, start server
                await serverManager.startServer()
            } else {
                let output = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    serverManager.lastError = "安装失败: \(output)"
                }
            }
        } catch {
            await MainActor.run {
                serverManager.lastError = error.localizedDescription
            }
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
