import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @State private var step = 0
    @State private var hasAccessibility = false
    @State private var hasMicrophone = false
    @State private var micCheckDone = false
    @ObservedObject private var modelState = QwenModelState.shared
    @StateObject private var store = ConfigurationStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Group {
                switch step {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: asrStep
                case 3: llmStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 520, height: 480)
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("欢迎使用 FlowType")
                .font(.system(size: 24, weight: .bold))

            Text("FlowType 是一款 macOS 语音输入工具。\n双击触发键开始录音，语音自动转为文字并输入到当前应用。")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: { withAnimation { step = 1 } }) {
                Text("开始设置")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Text("权限设置")
                .font(.system(size: 20, weight: .bold))

            Text("FlowType 需要以下权限才能正常工作。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "hand.raised.fill",
                    title: "辅助功能",
                    detail: "用于监听全局快捷键和注入文字",
                    granted: hasAccessibility,
                    action: {
                        PermissionHelper.openAccessibilitySettings()
                    },
                    actionLabel: "打开系统设置"
                )

                permissionRow(
                    icon: "mic.fill",
                    title: "麦克风",
                    detail: "用于录制语音输入",
                    granted: hasMicrophone,
                    action: {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Task { @MainActor in
                                hasMicrophone = granted
                                micCheckDone = true
                            }
                        }
                    },
                    actionLabel: "请求权限"
                )
            }

            Spacer()

            HStack {
                Button("跳过") {
                    withAnimation { step = 2 }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    hasAccessibility = PermissionHelper.checkAccessibility()
                }) {
                    Text("刷新状态")
                }
                .buttonStyle(.bordered)

                Button(action: { withAnimation { step = 2 } }) {
                    Text("继续")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            hasAccessibility = PermissionHelper.checkAccessibility()
            checkMicPermission()
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void,
        actionLabel: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                    Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(granted ? .green : .red)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !granted {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(granted ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func checkMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophone = true
            micCheckDone = true
        case .notDetermined:
            hasMicrophone = false
            micCheckDone = false
        default:
            hasMicrophone = false
            micCheckDone = true
        }
    }

    // MARK: - Step 2: Local ASR

    private var asrStep: some View {
        VStack(spacing: 20) {
            Text("本地语音识别")
                .font(.system(size: 20, weight: .bold))

            Text("FlowType 使用本地 Qwen3-ASR 模型进行语音识别，\n所有数据都在本机处理，无需联网。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            asrStatusView

            Spacer()

            HStack {
                Button("跳过") {
                    withAnimation { step = 3 }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button(action: { withAnimation { step = 3 } }) {
                    Text("继续")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(modelState.status.isLoading)
            }
        }
        .onAppear {
            if case .notLoaded = modelState.status {
                Task {
                    let provider = SessionController.shared.qwenProvider
                    await modelState.loadModel(provider: provider)
                }
            }
        }
    }

    @ViewBuilder
    private var asrStatusView: some View {
        VStack(spacing: 16) {
            switch modelState.status {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                Text("Qwen3-ASR 模型已就绪")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.green)

            case .downloading(let progress, let detail):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.orange)
                Text("首次下载约 300 MB，请稍候。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

            case .loading:
                ProgressView()
                    .controlSize(.large)
                Text("正在加载模型...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.orange)

            case .error(let msg):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
                Text("模型加载失败")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                Button("重试") {
                    Task {
                        let provider = SessionController.shared.qwenProvider
                        await modelState.loadModel(provider: provider)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .notLoaded:
                ProgressView()
                    .controlSize(.large)
                Text("正在检查模型...")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Step 3: LLM Config

    private var llmStep: some View {
        VStack(spacing: 20) {
            Text("文本润色（可选）")
                .font(.system(size: 20, weight: .bold))

            Text("配置大语言模型 API，可在双击停止录音时\n自动润色识别结果。不配置也可正常使用语音输入。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ProviderPicker(
                    provider: $store.current.llmProvider,
                    baseURL: $store.current.llmBaseURL
                )

                SecureKeyField(title: "API Key", key: $store.current.llmApiKey)

                ModelIDField(
                    title: "模型 ID",
                    model: $store.current.llmModel,
                    placeholder: "例如：deepseek-ai/DeepSeek-V3"
                )
            }

            Spacer()

            HStack {
                Button("跳过") {
                    withAnimation { step = 4 }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    store.save(store.current)
                    withAnimation { step = 4 }
                }) {
                    Text(store.current.llmApiKey.isEmpty ? "跳过" : "保存并继续")
                        .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 4: Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)

            Text("设置完成！")
                .font(.system(size: 24, weight: .bold))

            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    title: "辅助功能",
                    ok: PermissionHelper.checkAccessibility()
                )
                statusRow(
                    title: "麦克风",
                    ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                )
                statusRow(
                    title: "Qwen3-ASR 模型",
                    ok: modelState.status == .ready
                )
                statusRow(
                    title: "文本润色 API",
                    ok: !store.current.llmApiKey.isEmpty
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            let triggerName = store.current.triggerKey.displayName
            Text("双击 \(triggerName) 键开始录音\n单击 \(triggerName) 结束 → 原始文本\n双击 \(triggerName) 结束 → 润色文本")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Spacer()

            Button(action: completeOnboarding) {
                Text("开始使用 FlowType")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func statusRow(title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(ok ? .green : .secondary)
                .font(.system(size: 14))
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Text(ok ? "已配置" : "未配置")
                .font(.system(size: 12))
                .foregroundColor(ok ? .green : .secondary)
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "flowtype.onboardingCompleted")
        if case .notLoaded = modelState.status {
            Task {
                let provider = SessionController.shared.qwenProvider
                await modelState.loadModel(provider: provider)
            }
        }
        NSApp.keyWindow?.close()
    }
}
