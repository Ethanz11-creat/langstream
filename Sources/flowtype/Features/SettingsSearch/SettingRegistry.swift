import Foundation

// MARK: - SettingEntry

/// A single searchable setting entry.
struct SettingEntry: Identifiable {
    let id = UUID()
    let title: String
    let keywords: [String]
    let category: String
}

// MARK: - SettingMatch

/// A matched setting with its relevance score.
struct SettingMatch {
    let entry: SettingEntry
    let score: Int
}

// MARK: - SettingRegistry

/// Central registry for searchable settings.
///
/// Settings pages self-register their entries so that the search UI can
/// discover them without hard-coding a list.
@MainActor
class SettingRegistry {
    static let shared = SettingRegistry()
    private var entries: [SettingEntry] = []

    func register(_ entry: SettingEntry) {
        entries.append(entry)
    }

    func search(_ query: String) -> [SettingMatch] {
        guard !query.isEmpty else { return [] }
        let lowerQuery = query.lowercased()
        return entries.compactMap { entry in
            let score = matchScore(entry: entry, query: lowerQuery)
            return score > 0 ? SettingMatch(entry: entry, score: score) : nil
        }.sorted { $0.score > $1.score }
    }

    private func matchScore(entry: SettingEntry, query: String) -> Int {
        var score = 0
        if entry.title.lowercased().contains(query) { score += 10 }
        for keyword in entry.keywords {
            if keyword.lowercased().contains(query) { score += 5 }
        }
        if entry.category.lowercased().contains(query) { score += 2 }
        return score
    }
}
