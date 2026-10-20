import SwiftUI
import GRDB
import Observation

@MainActor
@Observable
final class MeetingsModel {
    var meetings: [Meeting] = []
    var todos: [Todo] = []
    var segments: [MeetingSegment] = []
    var selectedID: String?

    @ObservationIgnored private var meetingsObs: AnyDatabaseCancellable?
    @ObservationIgnored private var todosObs: AnyDatabaseCancellable?
    @ObservationIgnored private var segObs: AnyDatabaseCancellable?

    init() {
        meetingsObs = ValueObservation
            .tracking { db in try Meeting.order(Column("createdAt").desc).fetchAll(db) }
            .start(in: Database.shared.dbQueue, scheduling: .immediate, onError: { _ in },
                   onChange: { [weak self] m in MainActor.assumeIsolated { self?.meetings = m } })
        todosObs = ValueObservation
            .tracking { db in
                try Todo.filter(Column("isDeleted") == false).order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
            }
            .start(in: Database.shared.dbQueue, scheduling: .immediate, onError: { _ in },
                   onChange: { [weak self] t in MainActor.assumeIsolated { self?.todos = t } })
    }

    func observeSegments(_ id: String?) {
        segObs = nil
        segments = []
        guard let id else { return }
        segObs = ValueObservation
            .tracking { db in
                try MeetingSegment.filter(Column("meetingId") == id).order(Column("startMs")).fetchAll(db)
            }
            .start(in: Database.shared.dbQueue, scheduling: .immediate, onError: { _ in },
                   onChange: { [weak self] s in MainActor.assumeIsolated { self?.segments = s } })
    }

    func delete(_ m: Meeting) {
        let fm = FileManager.default
        for p in [m.micAudioPath, m.systemAudioPath].compactMap({ $0 }) { try? fm.removeItem(atPath: p) }
        try? fm.removeItem(at: Database.shared.meetingsDirectory.appendingPathComponent(m.id))
        let id = m.id
        try? Database.shared.write { db in
            _ = try MeetingSegment.filter(Column("meetingId") == id).deleteAll(db)
            _ = try Meeting.deleteOne(db, key: id)
        }
    }

    func update(_ id: String, _ change: @escaping (inout Meeting) -> Void) {
        try? Database.shared.write { db in
            if var m = try Meeting.fetchOne(db, key: id) { change(&m); try m.update(db) }
        }
    }
}

struct MeetingsView: View {
    @State private var model = MeetingsModel()
    @Bindable private var nav = Navigation.shared
    private let recorder = MeetingRecorder.shared

    var body: some View {
        HSplitView {
            list.frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            Group {
                if let m = model.meetings.first(where: { $0.id == model.selectedID }) {
                    MeetingDetailView(meeting: m, model: model).id(m.id)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity)
        }
        .onAppear {
            if let id = nav.selectedMeetingID, model.meetings.contains(where: { $0.id == id }) { model.selectedID = id }
            else if model.selectedID == nil { model.selectedID = model.meetings.first?.id }
        }
        .onChange(of: nav.selectedMeetingID) { _, id in if let id { model.selectedID = id } }
        .onChange(of: recorder.currentMeetingID) { _, id in if let id, recorder.isRecording { model.selectedID = id } }
        .onChange(of: model.selectedID) { _, id in
            model.observeSegments(id)
            nav.selectedMeetingID = id // keep in sync so reopening mid-recording can jump back to the live meeting
        }
        .task { model.observeSegments(model.selectedID) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Button { recorder.toggle() } label: {
                HStack {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                    Text(recorder.isRecording ? "Stop (\(recorder.elapsedString))" : "Start recording").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .controlSize(.large)
            .padding(10)
            if let e = recorder.lastError {
                Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            List(selection: $model.selectedID) {
                ForEach(model.meetings) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(.body.weight(.medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            if m.kind == .lecture { Image(systemName: "graduationcap").help("Lecture") }
                            Text(m.createdAt.formatted(date: .abbreviated, time: .shortened))
                            if m.status != .recording { Text("· \(durationText(m.durationMs))") }
                            Spacer()
                            badge(m)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(m.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func badge(_ m: Meeting) -> some View {
        let summarizing = m.status == .processing || recorder.summarizingMeetingID == m.id
        if m.status == .recording {
            HStack(spacing: 3) { Circle().fill(.red).frame(width: 7, height: 7); Text("Recording") }.foregroundStyle(.red)
        } else if summarizing {
            Text("Summarizing…").foregroundStyle(.orange)
        } else if m.status == .failed {
            Text("Failed").foregroundStyle(.red)
        } else {
            Text("Done").foregroundStyle(.green)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(model.meetings.isEmpty ? "No meetings yet" : "Select a meeting").font(.title3.weight(.semibold))
            if model.meetings.isEmpty {
                Text("Records your mic and the other side of the call, transcribes on-device, then Claude writes the summary. Works with Zoom, Teams, Meet, or in person. Press Option+N anytime.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func durationText(_ ms: Int) -> String {
    let s = ms / 1000
    if s < 60 { return "\(s) sec" }
    return "\((s + 30) / 60) min"
}

// MARK: - Detail

private enum MeetingTab: String, CaseIterable, Identifiable {
    case summary = "Summary", transcript = "Transcript", thoughts = "My thoughts", tasks = "Tasks"
    var id: String { rawValue }
}

struct MeetingDetailView: View {
    let meeting: Meeting
    let model: MeetingsModel
    private let recorder = MeetingRecorder.shared

    @State private var title = ""
    @State private var thoughts = ""
    @State private var tab: MeetingTab = .summary
    @State private var confirmDelete = false
    @State private var thoughtsTask: Task<Void, Never>?
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false
    @State private var askError: String?
    @State private var newTask = ""

    private var isLive: Bool { recorder.isRecording && recorder.currentMeetingID == meeting.id }
    private var kind: MeetingKind { isLive ? recorder.kind : meeting.kind }
    private var kindBinding: Binding<MeetingKind> {
        Binding(get: { kind }, set: { k in
            if isLive { recorder.setKind(k) } else { model.update(meeting.id) { $0.kind = k } }
        })
    }
    private var todos: [Todo] { model.todos.filter { $0.meetingId == meeting.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 10)
            Divider()
            if isLive { liveView } else {
                Picker("", selection: $tab) {
                    ForEach(MeetingTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 24).padding(.vertical, 10)
                switch tab {
                case .summary: summaryTab
                case .transcript: transcriptTab
                case .thoughts: thoughtsEditor
                case .tasks: tasksTab
                }
            }
        }
        .onAppear { title = meeting.title; thoughts = meeting.myThoughts }
        .onChange(of: meeting.title) { _, t in if t != title { title = t } }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete meeting", role: .destructive) { model.delete(meeting) }
        } message: { Text("The summary, transcript and audio files will be removed.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain).font(.title.weight(.bold))
                    .onSubmit { saveTitle() }
                    .onChange(of: title) { _, _ in saveTitle() }
                Spacer()
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete meeting").disabled(isLive)
            }
            HStack(spacing: 12) {
                Label(meeting.createdAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                if meeting.status != .recording { Label(durationText(meeting.durationMs), systemImage: "clock") }
                if let p = meeting.platform, !p.isEmpty { Label(p.capitalized, systemImage: "video") }
                if let p = meeting.participants, !p.isEmpty { Label(p, systemImage: "person.2").lineLimit(1) }
                Spacer()
                Picker("", selection: kindBinding) {
                    ForEach(MeetingKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(isLive ? "Tap Control to switch while recording" : "Click Regenerate to rewrite the summary for this mode")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func saveTitle() {
        let t = title
        guard t != meeting.title else { return }
        model.update(meeting.id) { $0.title = t }
    }

    // MARK: Live

    private var liveView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(recorder.elapsedString).font(.title3.monospacedDigit().weight(.semibold))
                meter(kind.speakerLabel("me"), recorder.micLevel, .blue)
                meter(kind.speakerLabel("them"), recorder.systemLevel, .green)
                Spacer()
            }
            .padding(.top, 10)
            Text("Live transcript").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recorder.liveSegments) { segmentRow($0) }
                        if !recorder.liveMicText.isEmpty { partialRow(kind.speakerLabel("me"), recorder.liveMicText) }
                        if !recorder.liveSystemText.isEmpty { partialRow(kind.speakerLabel("them"), recorder.liveSystemText) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: recorder.liveSegments.count) { _, _ in proxy.scrollTo("bottom") }
                .onChange(of: recorder.liveMicText) { _, _ in proxy.scrollTo("bottom") }
                .onChange(of: recorder.liveSystemText) { _, _ in proxy.scrollTo("bottom") }
            }
            .frame(minHeight: 120)
            Text("My thoughts").font(.headline)
            thoughtsEditor.frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
    }

    private func meter(_ label: String, _ level: Float, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color)
                        .frame(width: g.size.width * CGFloat(min(1, max(0, level))))
                }
            }
            .frame(width: 80, height: 6)
        }
    }

    private func segmentRow(_ s: MeetingSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(stamp(s.startMs)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 40, alignment: .leading)
            Text(kind.speakerLabel(s.speaker)).font(.caption.weight(.semibold))
                .foregroundStyle(s.speaker == "me" ? Color.blue : Color.green).frame(width: 44, alignment: .leading)
            Text(s.text).textSelection(.enabled)
        }
    }

    private func partialRow(_ who: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Spacer().frame(width: 40)
            Text(who).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func stamp(_ ms: Int) -> String {
        let t = ms / 1000
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: Summary

    private var summarizing: Bool { recorder.summarizingMeetingID == meeting.id || meeting.status == .processing }

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { Task { await recorder.summarize(meetingID: meeting.id) } } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }.disabled(summarizing)
                    if summarizing { ProgressView().controlSize(.small); Text("Summarizing…").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Copy summary") { TextInserter.copyToClipboard(meeting.summary ?? "") }
                        .disabled((meeting.summary ?? "").isEmpty)
                    Button("Copy as Markdown") { TextInserter.copyToClipboard(markdownExport()) }
                }
                if meeting.status == .failed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meeting.errorMessage ?? "Something went wrong.").foregroundStyle(.red)
                        Button("Retry") { Task { await recorder.summarize(meetingID: meeting.id) } }.disabled(summarizing)
                    }
                    .padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if let s = meeting.summary, !s.isEmpty {
                    MarkdownBlock(text: s)
                } else if !summarizing && meeting.status != .failed {
                    Text("No summary yet.").foregroundStyle(.secondary)
                }
                Divider()
                askSection
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == .lecture ? "Ask about this lecture" : "Ask about this meeting").font(.headline)
            HStack {
                TextField(kind == .lecture ? "e.g. What did the professor say will be on the exam?"
                                           : "e.g. What did we decide about the launch date?", text: $question)
                    .textFieldStyle(.roundedBorder).onSubmit { ask() }
                Button("Ask") { ask() }.disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if asking { ProgressView().controlSize(.small) }
            if let e = askError { Text(e).foregroundStyle(.red).font(.callout) }
            if let a = answer { MarkdownBlock(text: a).padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)) }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !asking else { return }
        asking = true; askError = nil; answer = nil
        Task {
            do { answer = try await recorder.ask(meetingID: meeting.id, question: q) }
            catch { askError = error.localizedDescription }
            asking = false
        }
    }

    private func markdownExport() -> String {
        var out = "# \(meeting.title)\n\n\(meeting.summary ?? "")\n"
        if !todos.isEmpty {
            out += "\n### Tasks\n" + todos.map { "- [\($0.status == .done ? "x" : " ")] \($0.title)" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    // MARK: Transcript

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Copy transcript") { TextInserter.copyToClipboard(MeetingRecorder.transcriptText(model.segments, kind: kind)) }
                    .disabled(model.segments.isEmpty)
            }
            if model.segments.isEmpty {
                Text("No transcript.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.segments) { segmentRow($0) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
    }

    // MARK: Thoughts

    private var thoughtsEditor: some View {
        TextEditor(text: $thoughts)
            .font(.body).lineSpacing(3).scrollContentBackground(.hidden)
            .padding(.horizontal, 19).padding(.bottom, 8)
            .onChange(of: thoughts) { _, v in
                thoughtsTask?.cancel()
                let id = meeting.id
                thoughtsTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    model.update(id) { $0.myThoughts = v }
                }
            }
            .onDisappear {
                thoughtsTask?.cancel()
                let v = thoughts, id = meeting.id
                if v != meeting.myThoughts { model.update(id) { $0.myThoughts = v } }
            }
    }

    // MARK: Tasks

    private var tasksTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a task", text: $newTask).textFieldStyle(.roundedBorder).onSubmit { addTask() }
                Button("Add") { addTask() }.disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if todos.isEmpty {
                Text("No tasks").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(todos) { t in
                        HStack {
                            Button { toggle(t) } label: {
                                Image(systemName: t.status == .done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(t.status == .done ? Color.green : Color.secondary)
                            }.buttonStyle(.borderless)
                            Text(t.title).strikethrough(t.status == .done)
                                .foregroundStyle(t.status == .done ? .secondary : .primary)
                            Spacer()
                            Button { remove(t) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
    }

    private func addTask() {
        let t = newTask.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var todo = Todo(meetingId: meeting.id, title: t)
        todo.sortOrder = Date().timeIntervalSince1970
        try? Database.shared.write { db in try todo.insert(db) }
        newTask = ""
    }

    private func toggle(_ t: Todo) {
        var u = t
        u.status = t.status == .done ? .open : .done
        u.modifiedAt = Date()
        try? Database.shared.write { db in try u.update(db) }
    }

    private func remove(_ t: Todo) {
        var u = t
        u.isDeleted = true
        u.modifiedAt = Date()
        try? Database.shared.write { db in try u.update(db) }
    }
}

// MARK: - Markdown rendering

struct MarkdownBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let l = raw.trimmingCharacters(in: .whitespaces)
        if l.isEmpty {
            Spacer().frame(height: 4)
        } else if let h = heading(l) {
            Text(inline(h.1)).font(h.0 <= 2 ? .title3.weight(.bold) : .headline).padding(.top, 8)
        } else if l.hasPrefix("- ") || l.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(l.dropFirst(2))))
            }
            .padding(.leading, CGFloat(raw.prefix(while: { $0 == " " }).count) * 6 + 4)
        } else {
            Text(inline(l)).lineSpacing(2)
        }
    }

    private func heading(_ l: String) -> (Int, String)? {
        let hashes = l.prefix(while: { $0 == "#" }).count
        guard hashes > 0, hashes <= 6, l.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return (hashes, String(l.dropFirst(hashes + 1)))
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
