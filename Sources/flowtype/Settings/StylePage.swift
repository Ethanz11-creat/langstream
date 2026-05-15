import SwiftUI

struct StylePage: View {
    @ObservedObject private var store = StylePackStore.shared
    @State private var editingPack: StylePack?
    @State private var showNewSheet = false
    @State private var showImportSheet = false
    @State private var newName = ""
    @State private var newPrompt = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showNewSheet) { newPackSheet }
        .sheet(item: $editingPack) { pack in
            editPackSheet(pack)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            PageHeader(title: "风格包", subtitle: "管理润色提示词模板")
            Spacer()

            Button {
                showImportSheet = true
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fileImporter(isPresented: $showImportSheet, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result,
                   let data = try? Data(contentsOf: url) {
                    try? store.importFromJSON(data)
                }
            }

            Button {
                newName = ""
                newPrompt = ""
                showNewSheet = true
            } label: {
                Label("新建", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(store.packs) { pack in
                    stylePackCard(pack)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Pack Card

    private func stylePackCard(_ pack: StylePack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pack.name)
                            .font(.system(size: 14, weight: .semibold))

                        if pack.active {
                            Text("当前")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }

                        kindBadge(pack.kind)
                    }

                    if !pack.description.isEmpty {
                        Text(pack.description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    if !pack.active {
                        Button("启用") {
                            store.setActive(id: pack.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        editingPack = pack
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)

                    if pack.kind != .builtin {
                        Menu {
                            Button("导出 JSON") {
                                exportPack(pack)
                            }
                            Divider()
                            Button("删除", role: .destructive) {
                                store.delete(id: pack.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button {
                            exportPack(pack)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Text(pack.prompt)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(pack.active ? Color.blue.opacity(0.4) : Color.secondary.opacity(0.1), lineWidth: pack.active ? 2 : 1)
        )
    }

    private func kindBadge(_ kind: StylePackKind) -> some View {
        Text(kind == .builtin ? "内置" : kind == .imported ? "导入" : "自定义")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
    }

    // MARK: - New Pack Sheet

    private var newPackSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建风格包")
                .font(.system(size: 16, weight: .bold))

            TextField("名称", text: $newName)
                .textFieldStyle(.roundedBorder)

            Text("提示词")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            TextEditor(text: $newPrompt)
                .font(.system(size: 12))
                .frame(minHeight: 200)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            Text("提示：可使用 {{HOTWORDS}} 占位符控制词典注入位置")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("取消") { showNewSheet = false }
                    .buttonStyle(.bordered)
                Button("创建") {
                    _ = store.createCustom(name: newName, prompt: newPrompt)
                    showNewSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500, height: 420)
    }

    // MARK: - Edit Pack Sheet

    private func editPackSheet(_ pack: StylePack) -> some View {
        StylePackEditor(pack: pack) { updated in
            store.save(updated)
            editingPack = nil
        } onCancel: {
            editingPack = nil
        }
    }

    // MARK: - Export

    private func exportPack(_ pack: StylePack) {
        guard let data = store.exportToJSON(id: pack.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(pack.name).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Editor

private struct StylePackEditor: View {
    @State private var name: String
    @State private var description: String
    @State private var prompt: String
    private let pack: StylePack
    private let onSave: (StylePack) -> Void
    private let onCancel: () -> Void

    init(pack: StylePack, onSave: @escaping (StylePack) -> Void, onCancel: @escaping () -> Void) {
        self.pack = pack
        self._name = State(initialValue: pack.name)
        self._description = State(initialValue: pack.description)
        self._prompt = State(initialValue: pack.prompt)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑风格包")
                .font(.system(size: 16, weight: .bold))

            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(pack.kind == .builtin)

            TextField("描述", text: $description)
                .textFieldStyle(.roundedBorder)

            Text("提示词")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(minHeight: 200)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(.bordered)
                Button("保存") {
                    var updated = pack
                    updated.name = name
                    updated.description = description
                    updated.prompt = prompt
                    onSave(updated)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, height: 460)
    }
}
