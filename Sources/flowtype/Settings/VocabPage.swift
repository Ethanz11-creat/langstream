import SwiftUI

struct VocabPage: View {
    @ObservedObject private var store = DictionaryStore.shared
    @State private var newPhrase: String = ""
    @State private var newNote: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            PageHeader(title: "词典", subtitle: "管理专有名词和热词，提升识别与润色准确度")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                addEntryCard

                if store.entries.isEmpty {
                    emptyState
                } else {
                    entryList
                }

                usageHint
            }
            .padding(20)
        }
    }

    // MARK: - Add Entry

    private var addEntryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加词条")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                TextField("专有名词（如 Claude、FlowType）", text: $newPhrase)
                    .textFieldStyle(.roundedBorder)

                TextField("备注（可选）", text: $newNote)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                Button("添加") {
                    store.add(phrase: newPhrase, note: newNote.isEmpty ? nil : newNote)
                    newPhrase = ""
                    newNote = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
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

    // MARK: - Entry List

    private var entryList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("词条列表")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(store.entries.count) 条")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Tag grid
            let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.entries) { entry in
                    VocabTag(entry: entry)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.4))
            Text("还没有词条")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text("添加专有名词后，FlowType 会在识别和润色时优先使用正确写法。")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Usage Hint

    private var usageHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("使用说明")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                hintRow(icon: "waveform", text: "词典中的词条会作为热词提示注入 ASR 上下文")
                hintRow(icon: "sparkles", text: "润色时，启用的词条会被添加到系统提示词中")
                hintRow(icon: "chart.bar", text: "命中次数统计每次识别结果中包含该词条的频率")
                hintRow(icon: "text.badge.plus", text: "支持在 prompt 中使用 {{HOTWORDS}} 占位符精确控制注入位置")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.1), lineWidth: 1)
        )
    }

    private func hintRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.blue.opacity(0.7))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

struct VocabTag: View {
    let entry: DictionaryEntry

    var body: some View {
        HStack(spacing: 4) {
            // Source indicator
            if entry.source == .autoDetected {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9))
                    .foregroundColor(.blue)
            }

            Text(entry.phrase)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            if entry.hits > 0 {
                Text("\(entry.hits)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Button {
                DictionaryStore.shared.remove(id: entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(entry.enabled ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(entry.enabled ? Color.blue.opacity(0.25) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .opacity(entry.enabled ? 1.0 : 0.5)
        .contextMenu {
            Button(entry.enabled ? "禁用" : "启用") {
                DictionaryStore.shared.setEnabled(id: entry.id, !entry.enabled)
            }
            Divider()
            Button("删除", role: .destructive) {
                DictionaryStore.shared.remove(id: entry.id)
            }
        }
    }
}
