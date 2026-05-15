import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case overview
    case history
    case vocab
    case style
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .history:  return "历史"
        case .vocab:    return "词典"
        case .style:    return "风格"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .history:  return "clock.arrow.circlepath"
        case .vocab:    return "character.book.closed.fill"
        case .style:    return "paintbrush.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MainWindowView: View {
    @State private var selectedTab: AppTab = .overview

    var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 150, maxWidth: 170)
        } detail: {
            switch selectedTab {
            case .overview: OverviewPage()
            case .history:  HistoryPage()
            case .vocab:    VocabPage()
            case .style:    StylePage()
            case .settings: SettingsPage()
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }
}
