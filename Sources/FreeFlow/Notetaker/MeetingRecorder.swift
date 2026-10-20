import Foundation
import AppKit
import AVFoundation
import Observation
import GRDB

/// Wispr "Notetaker": records mic + system audio, transcribes both live, then summarizes with Claude.
@MainActor
@Observable
final class MeetingRecorder {
    static let shared = MeetingRecorder()

    private(set) var isRecording = false
    private(set) var currentMeetingID: String?
    /// Meeting or Lecture for the recording in progress; a lone Control tap switches it.
    private(set) var kind: MeetingKind = .meeting
    private(set) var startedAt: Date?
    private(set) var elapsed: TimeInterval = 0
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var liveSegments: [MeetingSegment] = []
    private(set) var liveMicText = ""
    private(set) var liveSystemText = ""
    private(set) var lastError: String?
    private(set) var summarizingMeetingID: String?

    private let micRecorder = AudioRecorder()
    private let systemTap = SystemAudioTap()
    private var micSession: SpeechSession?
    private var systemSession: SpeechSession?
    private var tick: Timer?
    private var maxTimer: Timer?
    private var lastMicSegmentCount = 0
    private var lastSystemSegmentCount = 0
    private var flushTimer: Timer?

    private init() {}

    var elapsedString: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        lastError = nil
        var meeting = Meeting()
        kind = .meeting
        meeting.platform = detectPlatform()
        meeting.title = Self.defaultTitle(.meeting, meeting.createdAt)
        let dir = Database.shared.meetingsDirectory.appendingPathComponent(meeting.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("system.wav")
        meeting.micAudioPath = micURL.path
        meeting.systemAudioPath = sysURL.path
        try? Database.shared.write { db in try meeting.insert(db) }
        currentMeetingID = meeting.id
        liveSegments = []
        liveMicText = ""; liveSystemText = ""
        lastMicSegmentCount = 0; lastSystemSegmentCount = 0
        isRecording = true
        HotkeyManager.shared.isRecordingMeeting = true
        startedAt = Date()
        elapsed = 0
        Navigation.shared.selectedMeetingID = meeting.id

        let mic = SpeechSession(contextualStrings: contextualStrings(), timeIndexed: true)
        let sys = SpeechSession(contextualStrings: contextualStrings(), timeIndexed: true)
        micSession = mic; systemSession = sys

        Task { [weak self] in
            guard let self else { return }
            let format = await mic.bestFormat()
            await mic.setUpdateHandler { [weak self] final, volatile in
                Task { @MainActor in self?.setLiveMicText(volatile); self?.pullSegments() }
            }
            await sys.setUpdateHandler { [weak self] final, volatile in
                Task { @MainActor in self?.liveSystemText = volatile; self?.pullSegments() }
            }
            micRecorder.onBuffer = { buf in mic.feed(buf) }
            micRecorder.onLevel = { [weak self] l in DispatchQueue.main.async { self?.micLevel = l } }
            systemTap.onBuffer = { buf in sys.feed(buf) }
            systemTap.onLevel = { [weak self] l in DispatchQueue.main.async { self?.systemLevel = l } }
            do {
                try micRecorder.start(targetFormat: format, fileURL: micURL, deviceUID: Settings.shared.microphoneUID)
                try await mic.start()
            } catch {
                self.lastError = "Microphone: \(error.localizedDescription)"
            }
            do {
                try systemTap.start(targetFormat: format, fileURL: sysURL)
                try await sys.start()
            } catch {
                self.lastError = error.localizedDescription
                Notifier.notify("System audio not captured", error.localizedDescription)
            }
        }

        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.persistSegments() }
        }
        let maxMin = Double(Settings.shared.meetingMaxMinutes)
        maxTimer = Timer.scheduledTimer(withTimeInterval: maxMin * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        Sounds.play(.ready)
        // Stay out of the way: the Flow Bar pill shows the recording; the live transcript is in Meetings if opened.
        FlowBarController.shared.show()
    }

    func stop() {
        guard isRecording, let meetingID = currentMeetingID else { return }
        isRecording = false
        HotkeyManager.shared.isRecordingMeeting = false
        tick?.invalidate(); tick = nil
        flushTimer?.invalidate(); flushTimer = nil
        maxTimer?.invalidate(); maxTimer = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        micRecorder.stop()
        systemTap.stop()
        let mic = micSession, sys = systemSession
        micSession = nil; systemSession = nil
        Sounds.play(.stop)

        Task { [weak self] in
            guard let self else { return }
            _ = await mic?.finish()
            _ = await sys?.finish()
            // Await directly: pullSegments() bails once the sessions are cleared and would race persistSegments().
            if let mic, let sys { await self.refreshSegments(mic: mic, sys: sys) }
            self.persistSegments()
            try? Database.shared.write { db in
                if var m = try Meeting.fetchOne(db, key: meetingID) {
                    m.endedAt = Date()
                    m.durationMs = Int(duration * 1000)
                    m.status = .processing
                    // The transcript is saved, so the audio has done its job.
                    Self.deleteAudio(&m)
                    try m.update(db)
                }
            }
            self.currentMeetingID = nil
            await self.summarize(meetingID: meetingID)
        }
    }

    /// Lone Control tap while recording: Meeting ↔ Lecture.
    func switchKind() { setKind(kind.toggled) }

    func setKind(_ k: MeetingKind) {
        guard isRecording, let id = currentMeetingID, k != kind else { return }
        let old = kind
        kind = k
        try? Database.shared.write { db in
            if var m = try Meeting.fetchOne(db, key: id) {
                m.kind = k
                if m.title == Self.defaultTitle(old, m.createdAt) { m.title = Self.defaultTitle(k, m.createdAt) }
                try m.update(db)
            }
        }
        Sounds.play(.modeSwitch)
        FlowBarController.shared.flash(message: "\(k.label) mode")
        Log.write("meeting kind → \(k.rawValue)")
    }

    // MARK: - Segments

    private func pullSegments() {
        guard let mic = micSession, let sys = systemSession else { return }
        Task { [weak self] in await self?.refreshSegments(mic: mic, sys: sys) }
    }

    private func refreshSegments(mic: SpeechSession, sys: SpeechSession) async {
        guard let meetingID = currentMeetingID else { return }
        let m = await mic.segments
        let s = await sys.segments
        // Volatile updates fire many times a second; only rebuild when a segment was finalized.
        guard m.count != lastMicSegmentCount || s.count != lastSystemSegmentCount else { return }
        lastMicSegmentCount = m.count; lastSystemSegmentCount = s.count
        let all = await Task.detached {
            var all = m.map { MeetingSegment(meetingId: meetingID, speaker: "me", text: $0.text, startMs: $0.startMs, endMs: $0.endMs) }
            all += s.map { MeetingSegment(meetingId: meetingID, speaker: "them", text: $0.text, startMs: $0.startMs, endMs: $0.endMs) }
            return Self.removingEcho(all)
        }.value
        guard m.count == lastMicSegmentCount, s.count == lastSystemSegmentCount else { return } // a newer refresh landed first
        // Keep ids stable across refreshes so SwiftUI lists don't flicker.
        var keyed: [String: String] = [:]
        for seg in liveSegments { keyed["\(seg.speaker)-\(seg.startMs)"] = seg.id }
        liveSegments = all.map { var s = $0; if let id = keyed["\($0.speaker)-\($0.startMs)"] { s.id = id }; return s }
    }

    /// Drops mic segments that are just the other side playing through the speakers, sorted by start time.
    nonisolated static func removingEcho(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        let mic = segments.filter { $0.speaker == "me" }
        let system = segments.filter { $0.speaker != "me" }
        let span = { (s: MeetingSegment) in EchoFilter.Span(text: s.text, startMs: s.startMs, endMs: s.endMs) }
        let echoes = EchoFilter.echoIndices(mic: mic.map(span), system: system.map(span))
        let kept = mic.enumerated().filter { !echoes.contains($0.offset) }.map(\.element)
        return (kept + system).sorted { $0.startMs < $1.startMs }
    }

    /// Hides the in-progress "Me" line while it is only repeating what the other side is saying.
    private func setLiveMicText(_ volatile: String) {
        let lastThem = liveSegments.last { $0.speaker != "me" }?.text ?? ""
        liveMicText = EchoFilter.repeats(volatile, of: lastThem + " " + liveSystemText) ? "" : volatile
    }

    private func persistSegments() {
        guard let meetingID = currentMeetingID ?? liveSegments.first?.meetingId else { return }
        let segs = liveSegments
        try? Database.shared.write { db in
            try MeetingSegment.filter(Column("meetingId") == meetingID).deleteAll(db)
            for s in segs { try s.insert(db) }
        }
    }

    // MARK: - Summary

    func summarize(meetingID: String) async {
        summarizingMeetingID = meetingID
        defer { summarizingMeetingID = nil }
        guard var meeting = try? Database.shared.read({ db in try Meeting.fetchOne(db, key: meetingID) }) ?? nil else { return }
        let stored = (try? Database.shared.read { db in
            try MeetingSegment.filter(Column("meetingId") == meetingID).order(Column("startMs")).fetchAll(db)
        }) ?? []
        // Meetings recorded before echo filtering (or via Regenerate) still hold the duplicated lines; clean them up.
        let segments = Self.removingEcho(stored)
        if segments.count < stored.count {
            let keep = Set(segments.map(\.id))
            try? Database.shared.write { db in
                for s in stored where !keep.contains(s.id) { try s.delete(db) }
            }
        }
        guard !segments.isEmpty else {
            meeting.status = .done
            meeting.summary = "_No speech was captured in this meeting._"
            try? Database.shared.write { db in try meeting.update(db) }
            return
        }
        let transcript = Self.transcriptText(segments, kind: meeting.kind)
        var user = "USER NAME: \(Settings.shared.userFirstName) \(Settings.shared.userLastName)\n"
        user += "DATE: \(meeting.createdAt.formatted(date: .long, time: .shortened))\n"
        if let p = meeting.platform { user += "PLATFORM: \(p)\n" }
        if !meeting.myThoughts.isEmpty { user += "\n<my_thoughts>\n\(meeting.myThoughts)\n</my_thoughts>\n" }
        user += "\n<transcript>\n\(transcript)\n</transcript>"
        let model = Settings.shared.summaryModel
        let system = meeting.kind == .lecture ? Prompts.lectureSummarySystem() : Prompts.summarySystem()
        let req = ClaudeClient.Request(model: model, system: system, userContent: user,
                                       maxTokens: 8192, effort: "medium", disableThinking: false,
                                       jsonSchema: Prompts.summarySchema, timeout: 180)
        do {
            let resp = try await ClaudeClient.shared.send(req, feature: "summary")
            if let data = resp.text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let t = obj["title"] as? String, !t.isEmpty { meeting.title = t }
                meeting.summary = obj["summary_markdown"] as? String
                let participants = obj["participants"] as? [String] ?? []
                meeting.participants = participants.isEmpty ? nil : participants.joined(separator: ", ")
                let items = obj["action_items"] as? [String] ?? []
                try? Database.shared.write { db in
                    try Todo.filter(Column("meetingId") == meetingID).deleteAll(db)
                    for (i, item) in items.enumerated() {
                        try Todo(meetingId: meetingID, title: item, sortOrder: Double(i)).insert(db)
                    }
                }
            } else {
                meeting.summary = resp.text
            }
            meeting.model = model
            meeting.inputTokens = resp.usage.inputTokens
            meeting.outputTokens = resp.usage.outputTokens
            meeting.status = .done
            Notifier.notify("Meeting summary ready", meeting.title)
        } catch {
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
            Notifier.notify("Summary failed", error.localizedDescription)
        }
        try? Database.shared.write { db in try meeting.update(db) }
    }

    /// Ask a question about a meeting (cheap: Haiku).
    func ask(meetingID: String, question: String) async throws -> String {
        guard let meeting = try Database.shared.read({ db in try Meeting.fetchOne(db, key: meetingID) }) else { return "" }
        let segments = try Database.shared.read { db in
            try MeetingSegment.filter(Column("meetingId") == meetingID).order(Column("startMs")).fetchAll(db)
        }
        let user = "<summary>\n\(meeting.summary ?? "")\n</summary>\n<transcript>\n\(Self.transcriptText(segments, kind: meeting.kind))\n</transcript>\n\n<question>\(question)</question>"
        let req = ClaudeClient.Request(model: Settings.shared.cleanupModel, system: Prompts.askMeetingSystem(meeting.kind),
                                       userContent: user, maxTokens: 2048, effort: "low", disableThinking: true, timeout: 60)
        return try await ClaudeClient.shared.send(req, feature: "ask").text
    }

    static func transcriptText(_ segments: [MeetingSegment], kind: MeetingKind) -> String {
        segments.map { s in
            let t = s.startMs / 1000
            let stamp = String(format: "%02d:%02d", t / 60, t % 60)
            return "[\(stamp)] \(kind.speakerLabel(s.speaker)): \(s.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func contextualStrings() -> [String] {
        var c = Database.shared.activeDictionary().filter { !$0.isSnippet }.map { $0.replacement ?? $0.phrase }
        c.append(contentsOf: [Settings.shared.userFirstName, Settings.shared.userLastName].filter { !$0.isEmpty })
        return c
    }

    private func detectPlatform() -> String? {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        if running.contains(where: { $0.contains("zoom.us") }) { return "zoom" }
        if running.contains(where: { $0.contains("microsoft.teams") }) { return "teams" }
        if running.contains(where: { $0.contains("webex") }) { return "webex" }
        if let front = NSWorkspace.shared.frontmostApplication, ContextReader.browserBundleIDs.contains(front.bundleIdentifier ?? "") {
            let ctx = ContextReader.capture(readText: false)
            let t = (ctx.windowTitle ?? "").lowercased() + " " + (ctx.url ?? "").lowercased()
            if t.contains("meet.google") || t.contains("google meet") { return "meet" }
            if t.contains("teams") { return "teams" }
            if t.contains("zoom") { return "zoom" }
        }
        return nil
    }

    nonisolated private static func defaultTitle(_ kind: MeetingKind, _ date: Date) -> String {
        kind.label + " " + date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Audio is only kept until the transcript is saved. Clears what's left from older builds or a crash mid-recording.
    func deleteLeftoverAudio() {
        let leftovers = (try? Database.shared.read { db in
            try Meeting.filter(Column("micAudioPath") != nil || Column("systemAudioPath") != nil).fetchAll(db)
        }) ?? []
        for var m in leftovers where m.id != currentMeetingID {
            Self.deleteAudio(&m)
            try? Database.shared.write { db in try m.update(db) }
        }
    }

    nonisolated private static func deleteAudio(_ m: inout Meeting) {
        let fm = FileManager.default
        for p in [m.micAudioPath, m.systemAudioPath].compactMap({ $0 }) { try? fm.removeItem(atPath: p) }
        try? fm.removeItem(at: Database.shared.meetingsDirectory.appendingPathComponent(m.id, isDirectory: true))
        m.micAudioPath = nil; m.systemAudioPath = nil
    }
}
