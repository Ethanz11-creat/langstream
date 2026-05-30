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
                ForEach(0..<3) { i in
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
                default: quickConfigStep
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

                Button(action: {
                    hasAccessibility = PermissionHelper.checkAccessibility()
                    if hasAccessibility {
                        withAnimation { step = 2 }
                    }
                }) {
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

    // MARK: - Step 2: Quick Config

    private var quickConfigStep: some View {
        VStack(spacing: 20) {
            Text("快速配置")
                .font(.system(size: 20, weight: .bold))

            Text("设置触发键和交互方式。你也可以稍后打开设置更改。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 16) {
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
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("交互模式")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Picker("", selection: $store.current.interactionMode) {
                            ForEach(InteractionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }

                // Dynamic interaction hint
                VStack(alignment: .leading, spacing: 10) {
                    let mode = store.current.interactionMode

                    if mode == .tapToStart {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("单击")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("停止录音，输出原始文本")
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
                                    Text("停止录音，输出润色文本")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.purple.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("单击")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("开始 / 停止录音")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Spacer()

            HStack {
                Button("跳过") {
                    completeOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button(action: completeOnboarding) {
                    Text("开始使用 FlowType")
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func completeOnboarding() {
        store.current.hasCompletedOnboarding = true
        store.save(store.current)
        AppLogger.log("[Onboarding] Completed and saved")
        if case .notLoaded = modelState.status {
            Task {
                let provider = SessionController.shared.qwenProvider
                await modelState.loadModel(provider: provider)
            }
        }
        NSApp.keyWindow?.close()
    }
}
