import SwiftUI
import GRDB
import Observation

@MainActor
@Observable
final class ScratchpadModel {
    var notes: [Note] = []
    var selectedID: String?
    var title = ""
    var content = ""
    var search = ""
    var versions: [NoteVersion] = []

    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadedID: String?

    init() {
        cancellable = ValueObservation
            .tracking { db in
                try Note.filter(Column("isDeleted") == false)
                    .order(Column("pinned").desc, Column("modifiedAt").desc)
                    .fetchAll(db)
            }
            .start(in: Database.shared.dbQueue, scheduling: .immediate,
                   onError: { _ in },
                   onChange: { [weak self] notes in
                       MainActor.assumeIsolated { self?.notes = notes }
                   })
    }

    var filtered: [Note] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.displayTitle.localizedCaseInsensitiveContains(q) || $0.content.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q) }
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    func select(_ id: String?) {
        guard id != loadedID || id == nil else { return }
        flush()
        discardIfBlank()
        selectedID = id
        loadedID = id
        if let n = notes.first(where: { $0.id == id }) {
            title = n.title; content = n.content
        } else { title = ""; content = "" }
        loadVersions()
    }

    func newNote() {
        flush()
        discardIfBlank()
        let n = Note()
        try? Database.shared.write { db in try n.insert(db) }
        search = ""
        selectedID = n.id
        loadedID = n.id
        title = ""; content = ""
        loadVersions()
    }

    private func discardIfBlank() {
        guard let id = loadedID else { return }
        let blankLocal = title.isEmpty && content.isEmpty
        if blankLocal {
            try? Database.shared.write { db in _ = try Note.deleteOne(db, key: id) }
        }
    }

    func edited() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard let id = loadedID else { return }
        let t = title, c = content
        if t.isEmpty && c.isEmpty { return }
        try? Database.shared.write { db in
            guard var n = try Note.fetchOne(db, key: id) else { return }
            if n.title == t && n.content == c { return }
            n.title = t; n.content = c; n.modifiedAt = Date()
            try n.update(db)
            let last = try NoteVersion.filter(Column("noteId") == id).order(Column("createdAt").desc).fetchOne(db)
            if last == nil || Date().timeIntervalSince(last!.createdAt) > 600 {
                try NoteVersion(noteId: id, content: c).insert(db)
                let all = try NoteVersion.filter(Column("noteId") == id).order(Column("createdAt").desc).fetchAll(db)
                for old in all.dropFirst(50) { try old.delete(db) }
            }
        }
        loadVersions()
    }

    func loadVersions() {
        guard let id = loadedID else { versions = []; return }
        versions = (try? Database.shared.read { db in
            try NoteVersion.filter(Column("noteId") == id).order(Column("createdAt").desc).fetchAll(db)
        }) ?? []
    }

    func restore(_ v: NoteVersion) {
        content = v.content
        flush()
        edited()
    }

    func togglePin() {
        guard let id = loadedID else { return }
        try? Database.shared.write { db in
            if var n = try Note.fetchOne(db, key: id) { n.pinned.toggle(); try n.update(db) }
        }
    }

    func deleteSelected() {
        guard let id = loadedID else { return }
        saveTask?.cancel()
        try? Database.shared.write { db in _ = try Note.deleteOne(db, key: id) }
        loadedID = nil; selectedID = nil; title = ""; content = ""; versions = []
        if let first = filtered.first { select(first.id) }
    }
}

struct ScratchpadView: View {
    @State private var model = ScratchpadModel()
    @Bindable private var nav = Navigation.shared
    @State private var confirmDelete = false
    @State private var showHistory = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        HSplitView {
            list.frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            detail.frame(minWidth: 360, maxWidth: .infinity)
        }
        .onAppear {
            if nav.newNoteRequested { create() }
            else if model.selectedID == nil, let first = model.notes.first { model.select(first.id) }
        }
        .onChange(of: nav.newNoteRequested) { _, v in if v { create() } }
        .onDisappear { model.flush() }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
        }
    }

    private func create() {
        model.newNote()
        nav.newNoteRequested = false
        DispatchQueue.main.async { editorFocused = true }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search notes", text: $model.search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Button { create() } label: { Image(systemName: "plus") }
                    .help("New note")
            }
            .padding(10)
            Divider()
            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.filtered) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if n.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                            Text(n.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                        }
                        Text(n.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(n.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.selectedID == nil {
            VStack(spacing: 8) {
                Image(systemName: "note.text").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text("No note selected").font(.headline)
                Text("Hold Fn to dictate here.").foregroundStyle(.secondary)
                Button("New note") { create() }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    TextField("Untitled", text: $model.title)
                        .textFieldStyle(.plain).font(.title2.weight(.semibold))
                        .onChange(of: model.title) { _, _ in model.edited() }
                    Spacer()
                    Button { model.togglePin() } label: {
                        Image(systemName: model.selected?.pinned == true ? "pin.slash" : "pin")
                    }.help(model.selected?.pinned == true ? "Unpin" : "Pin")
                    Button { TextInserter.copyToClipboard(model.content) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy")
                    Button { model.flush(); showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                        .help("History")
                        .popover(isPresented: $showHistory) { history }
                    Button { confirmDelete = true } label: { Image(systemName: "trash") }.help("Delete")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                Divider().padding(.horizontal, 20)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.content)
                        .font(.body).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .onChange(of: model.content) { _, _ in model.edited() }
                        .padding(.horizontal, 15).padding(.vertical, 8)
                    if model.content.isEmpty {
                        Text("Start typing, or hold Fn to dictate here.")
                            .foregroundStyle(.tertiary).padding(.horizontal, 20).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Version history").font(.headline).padding(12)
            Divider()
            if model.versions.isEmpty {
                Text("No earlier versions yet.").foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.versions) { v in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                                    Text(v.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "(empty)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Restore") { model.restore(v); showHistory = false }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 320)
    }
}
