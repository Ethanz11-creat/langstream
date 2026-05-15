import Foundation

enum StylePackKind: String, Codable {
    case builtin
    case custom
    case imported
}

struct StylePack: Codable, Identifiable {
    let id: String
    var name: String
    var description: String
    var prompt: String
    var baseMode: PolishMode
    let kind: StylePackKind
    var enabled: Bool
    var active: Bool

    static let builtinLight = StylePack(
        id: "builtin.light",
        name: "轻度润色",
        description: "修正标点、去除口头词，保留原始语气",
        prompt: """
        你是一位语音文本整理助手。用户输入的是语音识别后的原始文本。

        请做以下处理：
        1. 修正标点符号和断句。
        2. 删除口头词（嗯、啊、那个、就是）和重复词。
        3. 保持原意和语气，不改变表达风格。
        4. 不添加任何前缀、说明或客套话。
        5. 只输出整理后的文本。
        """,
        baseMode: .light,
        kind: .builtin,
        enabled: true,
        active: false
    )

    static let builtinStructured = StylePack(
        id: "builtin.structured",
        name: "AI Prompt 模式",
        description: "将口语整理为结构化的 AI 编码指令",
        prompt: Configuration.default.systemPrompt,
        baseMode: .structured,
        kind: .builtin,
        enabled: true,
        active: true
    )

    static let builtinFormal = StylePack(
        id: "builtin.formal",
        name: "正式表达",
        description: "正式文档语气，适合邮件和报告",
        prompt: """
        你是一位专业文档润色助手。用户输入的是语音识别后的原始文本。

        请将其整理为正式、专业的书面文字：
        1. 使用正式的书面语表达。
        2. 修正所有标点、断句和语法问题。
        3. 删除口头词和重复内容。
        4. 组织成清晰的段落结构。
        5. 保持原意，不添加用户没有表达的内容。
        6. 不添加任何前缀、说明或客套话。
        7. 只输出整理后的文本。
        """,
        baseMode: .formal,
        kind: .builtin,
        enabled: true,
        active: false
    )

    static let allBuiltins: [StylePack] = [builtinLight, builtinStructured, builtinFormal]
}

@MainActor
final class StylePackStore: ObservableObject {
    static let shared = StylePackStore()

    @Published private(set) var packs: [StylePack] = []

    private let store = PersistentStore<[StylePack]>(filename: "style-packs.json")
    private var saveDebounce: Task<Void, Never>?

    private init() {
        var loaded = store.load() ?? []
        for builtin in StylePack.allBuiltins {
            if !loaded.contains(where: { $0.id == builtin.id }) {
                loaded.append(builtin)
            }
        }
        packs = loaded
    }

    var activePack: StylePack? {
        packs.first(where: { $0.active && $0.enabled })
            ?? packs.first(where: { $0.id == "builtin.structured" })
    }

    func setActive(id: String) {
        for i in packs.indices {
            packs[i].active = packs[i].id == id
        }
        scheduleSave()
    }

    func save(_ pack: StylePack) {
        if let idx = packs.firstIndex(where: { $0.id == pack.id }) {
            packs[idx] = pack
        } else {
            packs.append(pack)
        }
        scheduleSave()
    }

    func delete(id: String) {
        guard packs.first(where: { $0.id == id })?.kind != .builtin else { return }
        let wasActive = packs.first(where: { $0.id == id })?.active == true
        packs.removeAll { $0.id == id }
        if wasActive {
            setActive(id: "builtin.structured")
        }
        scheduleSave()
    }

    func createCustom(name: String, prompt: String) -> StylePack {
        let pack = StylePack(
            id: UUID().uuidString,
            name: name,
            description: "",
            prompt: prompt,
            baseMode: .light,
            kind: .custom,
            enabled: true,
            active: false
        )
        packs.append(pack)
        scheduleSave()
        return pack
    }

    func exportToJSON(id: String) -> Data? {
        guard let pack = packs.first(where: { $0.id == id }) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(pack)
    }

    func importFromJSON(_ data: Data) throws {
        let decoder = JSONDecoder()
        var pack = try decoder.decode(StylePack.self, from: data)
        pack = StylePack(
            id: UUID().uuidString,
            name: pack.name,
            description: pack.description,
            prompt: pack.prompt,
            baseMode: pack.baseMode,
            kind: .imported,
            enabled: true,
            active: false
        )
        packs.append(pack)
        scheduleSave()
    }

    private func scheduleSave() {
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.store.save(self.packs)
        }
    }
}
