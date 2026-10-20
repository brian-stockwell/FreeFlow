import SwiftUI
import GRDB

@MainActor
@Observable
final class DictionaryViewModel {
    var entries: [DictionaryEntry] = []
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?

    func start() {
        guard cancellable == nil else { return }
        let obs = ValueObservation.tracking { db in
            try DictionaryEntry.filter(Column("isDeleted") == false)
                .order(Column("isStarred").desc, Column("createdAt").desc).fetchAll(db)
        }
        cancellable = obs.start(in: Database.shared.dbQueue, scheduling: .immediate,
                                onError: { _ in },
                                onChange: { [weak self] rows in
            MainActor.assumeIsolated { self?.entries = rows }
        })
    }

    func toggleStar(_ e: DictionaryEntry) {
        var copy = e
        copy.isStarred.toggle()
        copy.modifiedAt = Date()
        save(copy)
    }

    func delete(_ e: DictionaryEntry) {
        var copy = e
        copy.isDeleted = true
        copy.modifiedAt = Date()
        save(copy)
    }

    func save(_ e: DictionaryEntry) {
        _ = try? Database.shared.write { db in try e.save(db) }
    }
}

struct DictionaryEditTarget: Identifiable {
    let id = UUID()
    var entry: DictionaryEntry?   // nil => new
    var isSnippet: Bool
}

struct DictionaryView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case dictionary = "Dictionary", snippets = "Snippets"
        var id: String { rawValue }
    }

    @State private var model = DictionaryViewModel()
    @State private var tab: Tab = .dictionary
    @State private var search = ""
    @State private var editTarget: DictionaryEditTarget?
    @State private var importMessage: String?

    private var isSnippetTab: Bool { tab == .snippets }

    private var visible: [DictionaryEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.entries.filter { e in
            e.isSnippet == isSnippetTab
            && (q.isEmpty || e.phrase.localizedCaseInsensitiveContains(q)
                || (e.replacement?.localizedCaseInsensitiveContains(q) ?? false))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)

            Text(isSnippetTab ? "Say a trigger phrase to insert a longer text"
                              : "Words and names FreeFlow should spell your way")
                .foregroundStyle(.secondary)

            if let msg = importMessage {
                Text(msg).font(.callout)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }

            if visible.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: isSnippetTab ? "text.badge.plus" : "character.book.closed")
                        .font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(search.isEmpty ? (isSnippetTab ? "No snippets yet" : "No words yet") : "No matches")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visible) { e in
                        row(e)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(20)
        .navigationTitle("Dictionary")
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup {
                if WisprImport.isAvailable {
                    Button {
                        let r = WisprImport.run()
                        importMessage = "Imported \(r.dictionaryCount) words and \(r.snippetCount) snippets"
                            + (r.importedStyles ? ", styles" : "") + (r.importedSignature ? ", signature" : "") + "."
                    } label: { Label("Import from Wispr Flow", systemImage: "square.and.arrow.down") }
                }
                Button {
                    editTarget = DictionaryEditTarget(entry: nil, isSnippet: isSnippetTab)
                } label: { Label(isSnippetTab ? "Add snippet" : "Add word", systemImage: "plus") }
            }
        }
        .sheet(item: $editTarget) { target in
            DictionaryEditSheet(target: target) { saved in
                model.save(saved)
                editTarget = nil
            } onCancel: { editTarget = nil }
        }
        .onAppear { model.start() }
    }

    private func row(_ e: DictionaryEntry) -> some View {
        HStack(spacing: 10) {
            Button { model.toggleStar(e) } label: {
                Image(systemName: e.isStarred ? "star.fill" : "star")
                    .foregroundStyle(e.isStarred ? Color.yellow : Color.secondary)
            }.buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.phrase).fontWeight(.medium)
                if let r = e.replacement, !r.isEmpty {
                    Text("→ \(r)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(e.source)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(sourceColor(e.source).opacity(0.18), in: Capsule())
                .foregroundStyle(sourceColor(e.source))
            Text("\(e.frequencyUsed) uses").font(.caption).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Button { editTarget = DictionaryEditTarget(entry: e, isSnippet: e.isSnippet) } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.borderless).help("Edit")
            Button { model.delete(e) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editTarget = DictionaryEditTarget(entry: e, isSnippet: e.isSnippet) }
        .contextMenu {
            Button("Edit") { editTarget = DictionaryEditTarget(entry: e, isSnippet: e.isSnippet) }
            Button(e.isStarred ? "Unstar" : "Star") { model.toggleStar(e) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(e) }
        }
    }

    private func sourceColor(_ s: String) -> Color {
        switch s {
        case "auto": return .orange
        case "import": return .purple
        default: return .blue
        }
    }
}

struct DictionaryEditSheet: View {
    let target: DictionaryEditTarget
    let onSave: (DictionaryEntry) -> Void
    let onCancel: () -> Void

    @State private var phrase: String
    @State private var replacement: String

    init(target: DictionaryEditTarget, onSave: @escaping (DictionaryEntry) -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.onSave = onSave
        self.onCancel = onCancel
        _phrase = State(initialValue: target.entry?.phrase ?? "")
        _replacement = State(initialValue: target.entry?.replacement ?? "")
    }

    private var isSnippet: Bool { target.isSnippet }
    private var maxExpansion: Int { 4000 }
    private var trimmedPhrase: String { phrase.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        guard !trimmedPhrase.isEmpty, trimmedPhrase.count <= 60 else { return false }
        if isSnippet {
            let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            return !r.isEmpty && replacement.count <= maxExpansion
        }
        return replacement.count <= maxExpansion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(isSnippet ? "Trigger phrase" : "Word or phrase").font(.caption).foregroundStyle(.secondary)
                TextField(isSnippet ? "e.g. my address" : "e.g. Wispr", text: $phrase)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: phrase) { _, v in if v.count > 60 { phrase = String(v.prefix(60)) } }
                Text("\(phrase.count)/60").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(isSnippet ? "Expansion" : "Replacement (optional)").font(.caption).foregroundStyle(.secondary)
                if isSnippet {
                    TextEditor(text: $replacement)
                        .font(.body)
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .onChange(of: replacement) { _, v in
                            if v.count > maxExpansion { replacement = String(v.prefix(maxExpansion)) }
                        }
                    Text("\(replacement.count)/\(maxExpansion)").font(.caption2).foregroundStyle(.secondary)
                } else {
                    TextField("Leave empty to just spell the word this way", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var title: String {
        if target.entry != nil { return isSnippet ? "Edit snippet" : "Edit word" }
        return isSnippet ? "Add snippet" : "Add word"
    }

    private func save() {
        let rep: String? = replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : replacement
        var e = target.entry ?? DictionaryEntry(phrase: trimmedPhrase, replacement: rep, isSnippet: isSnippet, source: "manual")
        e.phrase = trimmedPhrase
        e.replacement = rep
        e.isSnippet = isSnippet
        e.modifiedAt = Date()
        onSave(e)
    }
}
