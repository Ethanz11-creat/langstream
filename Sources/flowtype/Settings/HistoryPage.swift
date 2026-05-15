import SwiftUI

struct HistoryPage: View {
    @ObservedObject private var historyStore = HistoryStore.shared
    @State private var selectedID: String?
    @State private var searchText: String = ""
    @State private var filterMode: PolishMode?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                sessionList
                    .frame(minWidth: 240, idealWidth: 280)
                detailPanel
                    .frame(minWidth: 300)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("确认清空", isPresented: $showClearConfirm) {
            Button("清空全部", role: .destructive) { historyStore.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有历史记录，此操作不可撤销。")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            PageHeader(title: "历史记录", subtitle: "共 \(filteredSessions.count) 条")

            Spacer()

            Picker("", selection: $filterMode) {
                Text("全部").tag(Optional<PolishMode>.none)
                ForEach(PolishMode.allCases) { mode in
                    Text(mode.displayName).tag(Optional(mode))
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            TextField("搜索...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(historyStore.sessions.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var filteredSessions: [DictationSession] {
        historyStore.sessions.filter { session in
            if let mode = filterMode, session.polishMode != mode { return false }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                return session.finalText.lowercased().contains(query) ||
                       session.rawTranscript.lowercased().contains(query)
            }
            return true
        }
    }

    private var sessionList: some View {
        List(filteredSessions, selection: $selectedID) { session in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.polishMode.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pillColor(session.polishMode))
                        .clipShape(Capsule())

                    Spacer()

                    Text(formatDate(session.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Text(session.finalText)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if let ms = session.durationMs {
                    Text("\(String(format: "%.1f", Double(ms) / 1000))s")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .tag(session.id)
            .contextMenu {
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.finalText, forType: .string)
                }
                Divider()
                Button("删除", role: .destructive) {
                    if selectedID == session.id { selectedID = nil }
                    historyStore.delete(id: session.id)
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Detail

    private var selectedSession: DictationSession? {
        guard let id = selectedID else { return nil }
        return historyStore.sessions.first(where: { $0.id == id })
    }

    private var detailPanel: some View {
        Group {
            if let session = selectedSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(session.polishMode.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(pillColor(session.polishMode))
                                .clipShape(Capsule())

                            Spacer()

                            Text(formatDateFull(session.createdAt))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        if session.rawTranscript != session.finalText {
                            DetailSection(title: "原始识别", text: session.rawTranscript)
                        }

                        DetailSection(title: "最终文本", text: session.finalText)

                        HStack(spacing: 12) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.finalText, forType: .string)
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(role: .destructive) {
                                selectedID = nil
                                historyStore.delete(id: session.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(20)
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("选择一条记录查看详情")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Helpers

    private func pillColor(_ mode: PolishMode) -> Color {
        switch mode {
        case .raw: return .blue
        case .light: return .teal
        case .structured: return .purple
        case .formal: return .orange
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatDateFull(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct DetailSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        }
    }
}
