import SwiftUI

struct AudioVisualizer: View {
    @EnvironmentObject var session: SessionController

    private let barCount = 9
    private let phases: [Double] = [0, 0.3, 0.6, 0.9, 1.2, 0.9, 0.6, 0.3, 0]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                AudioBar(
                    amplitude: session.amplitude,
                    phase: phases[index],
                    isActive: session.sessionState.isRecordingIndicator
                )
            }
        }
        .frame(width: 40, height: 24)
    }
}

struct AudioBar: View {
    let amplitude: Float
    let phase: Double
    let isActive: Bool

    @State private var animationOffset: Double = 0

    var height: CGFloat {
        guard isActive else { return 3 }
        let base: CGFloat = 3
        let wave = sin(animationOffset + phase) * 0.5 + 0.5
        let volumeBoost = CGFloat(min(amplitude * 15, 1.0)) * 18
        return base + CGFloat(wave) * 8 + volumeBoost
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(barColor)
            .frame(width: 3, height: height)
            .animation(.easeInOut(duration: 0.1), value: height)
            .onAppear {
                if isActive {
                    withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                        animationOffset = .pi * 2
                    }
                }
            }
    }

    private var barColor: Color {
        if !isActive { return Color.white.opacity(0.2) }
        let intensity = min(Double(amplitude * 10), 1.0)
        return Color(
            red: 0.4 + 0.6 * intensity,
            green: 0.3 + 0.4 * intensity,
            blue: 0.8 + 0.2 * intensity
        )
    }
}
