import SwiftUI

struct CapsuleView: View {
    @EnvironmentObject var appState: AppState

    @State private var breathScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3

    var body: some View {
        HStack(spacing: 16) {
            // Left: Audio visualizer
            AudioVisualizer()
                .environmentObject(appState)

            // Center: Avatar / Status icon
            StatusAvatar(state: appState.state)

            // Right: Status text + subtitle
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                // Timer + preview on one line; timer stays visible, preview scrolls visually
                HStack(spacing: 4) {
                    if let timer = recordingTimerText {
                        Text(timer)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(statusColor.opacity(0.7))
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(statusSubtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(statusColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(width: 320, height: 70)
        .background(
            ZStack {
                // Base blur
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)

                // State-colored radial glow
                RadialGradient(
                    gradient: Gradient(colors: [
                        statusColor.opacity(0.25),
                        statusColor.opacity(0.05),
                        Color.clear
                    ]),
                    center: .center,
                    startRadius: 20,
                    endRadius: 160
                )
            }
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.3),
                            statusColor.opacity(0.5),
                            Color.white.opacity(0.2)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        // Outer glow shadow
        .shadow(color: statusColor.opacity(glowOpacity), radius: 15, x: 0, y: 0)
        .shadow(color: statusColor.opacity(glowOpacity * 0.5), radius: 30, x: 0, y: 0)
        // Breathing animation when recording
        .scaleEffect(breathScale)
        .onChange(of: appState.state.isRecordingIndicator) { oldValue, isRecording in
            if isRecording {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    breathScale = 1.02
                    glowOpacity = 0.6
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    breathScale = 1.0
                    glowOpacity = 0.3
                }
            }
        }
    }

    private var statusTitle: String {
        switch appState.state {
        case .idle: return "准备就绪"
        case .requestingPermission: return "请求权限..."
        case .recording: return "Listening..."
        case .previewing: return appState.isRefining ? "润色中..." : "实时预览..."
        case .processingASR(let provider): return "\(provider)..."
        case .polishing: return appState.isRefining ? "润色中..." : "润色完成"
        case .injecting: return "输入中..."
        case .error: return "出错了"
        }
    }

    /// Timer text shown during recording (e.g. "00:12"); nil for other states.
    private var recordingTimerText: String? {
        if case .recording(let seconds) = appState.state {
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        return nil
    }

    private var statusSubtitle: String {
        switch appState.state {
        case .idle: return "双击 Option 开始"
        case .requestingPermission: return ""
        case .recording:
            return appState.previewText.isEmpty ? "正在听写..." : appState.previewText
        case .previewing:
            return appState.previewText.isEmpty ? "正在听写..." : appState.previewText
        case .processingASR:
            return appState.previewText.isEmpty ? "识别中..." : appState.previewText
        case .polishing(let preview):
            return preview.isEmpty ? (appState.previewText.isEmpty ? "润色中..." : appState.previewText) : preview
        case .injecting:
            return appState.previewText.isEmpty ? "输入中..." : appState.previewText
        case .error(let msg): return msg
        }
    }

    private var statusColor: Color {
        switch appState.state {
        case .idle: return Color.white.opacity(0.5)
        case .requestingPermission: return .yellow
        case .recording: return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .previewing: return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .processingASR: return .blue
        case .polishing: return Color(red: 0.8, green: 0.4, blue: 0.9)
        case .injecting: return .green
        case .error: return .red
        }
    }
}

// Circular avatar/status icon (display only, no click interaction)
struct StatusAvatar: View {
    let state: RecordingState

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor.opacity(0.15))
                .frame(width: 36, height: 36)

            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(avatarColor)
        }
    }

    private var iconName: String {
        switch state {
        case .idle: return "mic"
        case .requestingPermission: return "hand.raised"
        case .recording: return "waveform"
        case .previewing: return "waveform"
        case .processingASR: return "brain.head.profile"
        case .polishing: return "sparkles"
        case .injecting: return "keyboard"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var avatarColor: Color {
        switch state {
        case .idle: return .gray
        case .requestingPermission: return .yellow
        case .recording, .previewing: return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .processingASR: return .blue
        case .polishing: return Color(red: 0.8, green: 0.4, blue: 0.9)
        case .injecting: return .green
        case .error: return .red
        }
    }
}

// 毛玻璃效果辅助
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
