import SwiftUI

struct OverviewPage: View {
    @ObservedObject private var historyStore = HistoryStore.shared
    @ObservedObject private var modelState = QwenModelState.shared
    @ObservedObject private var configStore = ConfigurationStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "概览", subtitle: "FlowType 使用统计与状态")

                providerCards

                metricsCards

                weeklyChart

                recentSessions
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Provider Status

    private var providerCards: some View {
        HStack(spacing: 12) {
            StatusCard(
                icon: "waveform",
                iconColor: .blue,
                title: asrStatusTitle,
                subtitle: "Qwen3-ASR 0.6B MLX",
                isReady: modelState.status == .ready
            )

            StatusCard(
                icon: "sparkles",
                iconColor: .purple,
                title: llmStatusTitle,
                subtitle: configStore.current.llmModel,
                isReady: !configStore.current.llmApiKey.isEmpty
            )
        }
    }

    private var asrStatusTitle: String {
        switch modelState.status {
        case .ready: return "ASR 就绪"
        case .downloading(let p, _): return "下载中 \(Int(p * 100))%"
        case .loading: return "加载中..."
        case .error: return "加载失败"
        case .notLoaded: return "等待加载"
        }
    }

    private var llmStatusTitle: String {
        configStore.current.llmApiKey.isEmpty ? "未配置" : "LLM 已配置"
    }

    // MARK: - Metrics

    private var metricsCards: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let todaySessions = historyStore.sessions.filter {
            Calendar.current.isDate($0.createdAt, inSameDayAs: today)
        }

        let todayWords = todaySessions.reduce(0) { $0 + $1.finalText.count }
        let todayCount = todaySessions.count
        let todayDuration = todaySessions.compactMap(\.durationMs).reduce(0, +)
        let totalCount = historyStore.sessions.count

        return HStack(spacing: 12) {
            MetricCard(title: "今日字数", value: "\(todayWords)", icon: "character.cursor.ibeam")
            MetricCard(title: "今日次数", value: "\(todayCount)", icon: "mic.fill")
            MetricCard(title: "今日时长", value: formatDuration(todayDuration), icon: "timer")
            MetricCard(title: "历史总计", value: "\(totalCount)", icon: "tray.full.fill")
        }
    }

    // MARK: - Weekly Chart

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("过去 7 天活跃度")
                .font(.system(size: 13, weight: .semibold))

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(weeklyData, id: \.date) { day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.7))
                            .frame(width: 32, height: max(4, CGFloat(day.count) * barScale))

                        Text(day.label)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .frame(height: 120)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    private struct DayData: Hashable {
        let date: Date
        let label: String
        let count: Int
    }

    private var weeklyData: [DayData] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        formatter.locale = Locale(identifier: "zh_CN")

        return (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let count = historyStore.sessions.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }.count
            return DayData(date: date, label: formatter.string(from: date), count: count)
        }
    }

    private var barScale: CGFloat {
        let maxCount = weeklyData.map(\.count).max() ?? 1
        return maxCount > 0 ? 80.0 / CGFloat(maxCount) : 1
    }

    // MARK: - Recent Sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近使用")
                .font(.system(size: 13, weight: .semibold))

            if historyStore.sessions.isEmpty {
                Text("暂无历史记录")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(historyStore.sessions.prefix(5)) { session in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(session.polishMode == .raw ? Color.blue.opacity(0.3) : Color.purple.opacity(0.3))
                            .frame(width: 8, height: 8)

                        Text(session.finalText)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        Text(relativeTime(session.createdAt))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func formatDuration(_ ms: UInt64) -> String {
        let seconds = Int(ms / 1000)
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86400))天前"
    }
}

// MARK: - Reusable Components

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

struct StatusCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Circle()
                        .fill(isReady ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}
