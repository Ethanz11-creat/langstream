import Foundation

enum EntrySource: String, Codable {
    case manual, autoDetected
}

struct DictionaryEntry: Codable, Identifiable {
    let id: String
    var phrase: String
    var note: String?
    var enabled: Bool
    var hits: UInt64
    let createdAt: Date
    var source: EntrySource

    init(phrase: String, note: String? = nil, source: EntrySource = .manual) {
        self.id = UUID().uuidString
        self.phrase = phrase.trimmingCharacters(in: .whitespaces)
        self.note = note
        self.enabled = true
        self.hits = 0
        self.createdAt = Date()
        self.source = source
    }
}

@MainActor
final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()

    @Published private(set) var entries: [DictionaryEntry] = []

    private let store = PersistentStore<[DictionaryEntry]>(filename: "dictionary.json")
    private var saveDebounce: Task<Void, Never>?

    private init() {
        entries = store.load() ?? []
    }

    func add(phrase: String, note: String? = nil) {
        guard !phrase.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let entry = DictionaryEntry(phrase: phrase.trimmingCharacters(in: .whitespaces), note: note)
        entries.append(entry)
        scheduleSave()
    }

    func addAutoDetected(phrase: String) {
        guard !phrase.isEmpty else { return }
        // Security: reject suspicious patterns
        guard phrase.count <= 50 else { return }
        let lower = phrase.lowercased()
        let forbidden = [
            "ignore", "</system>", "```", "<script",
            "http://", "https://", "ftp://",
        ]
        for pattern in forbidden {
            if lower.contains(pattern) { return }
        }
        // Reject shell metacharacters
        if phrase.rangeOfCharacter(from: CharacterSet(charactersIn: ";|&$`\n\r")) != nil { return }

        let entry = DictionaryEntry(phrase: phrase, source: .autoDetected)
        guard !entries.contains(where: { $0.phrase.lowercased() == entry.phrase.lowercased() }) else { return }
        entries.append(entry)
        scheduleSave()
        AppLogger.log("[DictionaryStore] Auto-added: \(entry.phrase)")
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        scheduleSave()
    }

    func setEnabled(id: String, _ enabled: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].enabled = enabled
        scheduleSave()
    }

    func incrementHits(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for i in entries.indices {
            if ids.contains(entries[i].id) {
                entries[i].hits += 1
            }
        }
        scheduleSave()
    }

    func detectHits(in text: String) -> Set<String> {
        let lower = text.lowercased()
        var hitIds = Set<String>()
        for entry in entries where entry.enabled {
            if lower.contains(entry.phrase.lowercased()) {
                hitIds.insert(entry.id)
            }
        }
        return hitIds
    }

    var enabledPhrases: [String] {
        entries.filter(\.enabled).map(\.phrase)
    }

    private func scheduleSave() {
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.store.save(self.entries)
        }
    }
}
