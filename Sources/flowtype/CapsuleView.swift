import SwiftUI

struct CapsuleView: View {
    @EnvironmentObject var session: SessionController

    @State private var breathScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3

    var body: some View {
        HStack(spacing: 16) {
            AudioVisualizer()

            StatusAvatar(state: session.sessionState)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.sessionState.statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

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
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)

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
        .shadow(color: statusColor.opacity(glowOpacity), radius: 15, x: 0, y: 0)
        .shadow(color: statusColor.opacity(glowOpacity * 0.5), radius: 30, x: 0, y: 0)
        .scaleEffect(breathScale)
        .onChange(of: session.sessionState.isRecordingIndicator) { oldValue, isRecording in
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

    private var recordingTimerText: String? {
        if case .recording(let seconds) = session.sessionState {
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        return nil
    }

    private var statusSubtitle: String {
        switch session.sessionState {
        case .idle:
            return "双击 Option 开始"
        case .recording:
            return session.previewText.isEmpty ? "正在听写..." : session.previewText
        case .processing:
            return session.previewText.isEmpty ? "识别中..." : session.previewText
        case .polishing(let preview):
            return preview.isEmpty ? (session.previewText.isEmpty ? "润色中..." : session.previewText) : preview
        case .injecting:
            return session.previewText.isEmpty ? "输入中..." : session.previewText
        case .error(let msg):
            return msg
        }
    }

    private var statusColor: Color {
        session.sessionState.statusColor
    }
}

struct StatusAvatar: View {
    let state: SessionState

    var body: some View {
        ZStack {
            Circle()
                .fill(state.statusColor.opacity(0.15))
                .frame(width: 36, height: 36)

            Image(systemName: state.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(state.statusColor)
        }
    }
}

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
