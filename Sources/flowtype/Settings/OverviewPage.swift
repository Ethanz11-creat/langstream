import SwiftUI

struct OverviewPage: View {
    @ObservedObject private var statsStore = DailyStatsStore.shared
    @ObservedObject private var dictionaryStore = DictionaryStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Top row: Accuracy ring + main stats
                HStack(spacing: 20) {
                    accuracyCard
                    mainStatsGrid
                }
                .frame(height: 200)

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var accuracyCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: accuracyProgress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(accuracyProgress * 100))%")
                    .font(.system(size: 18, weight: .bold))
            }
            Text("个性化")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(cardBackground)
    }

    private var mainStatsGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statCard(
                    icon: "clock",
                    value: statsStore.totalDurationMs.formattedDuration,
                    label: "总口述时间"
                )
                statCard(
                    icon: "text.word.count",
                    value: formatWordCount(statsStore.totalWordCount),
                    label: "口述字数"
                )
            }
            HStack(spacing: 12) {
                statCard(
                    icon: "hourglass",
                    value: statsStore.estimatedTimeSaved,
                    label: "节省时间"
                )
                statCard(
                    icon: "bolt",
                    value: "\(statsStore.overallAverageSpeed)",
                    label: "平均口述速度（字/分钟）"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statCard(icon: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 22, weight: .bold))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var accuracyProgress: Double {
        let total = dictionaryStore.entries.count
        guard total > 0 else { return 0 }
        let enabled = dictionaryStore.entries.filter(\.enabled).count
        return Double(enabled) / Double(total)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 2)
    }

    private func formatWordCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

extension UInt64 {
    var formattedDuration: String {
        let totalSeconds = Int(self / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}

// MARK: - Shared Components

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}
