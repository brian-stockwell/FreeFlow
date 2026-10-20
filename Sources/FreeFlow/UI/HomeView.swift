import SwiftUI
import AVFoundation
import GRDB

// MARK: - View model

struct HomeStats: Equatable {
    var wordsToday = 0
    var wordsWeek = 0
    var avgWPM: Double = 0
    var spendMonth: Double = 0
}

@MainActor
@Observable
final class HomeViewModel {
    var entries: [HistoryEntry] = []
    var stats = HomeStats()
    var playingID: String?

    @ObservationIgnored private var listCancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var statsCancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegateProxy: HomePlayerDelegate?

    func start() {
        guard listCancellable == nil else { return }
        let listObs = ValueObservation.tracking { db in
            try HistoryEntry.filter(Column("isArchived") == false)
                .order(Column("timestamp").desc).limit(500).fetchAll(db)
        }
        listCancellable = listObs.start(in: Database.shared.dbQueue, scheduling: .immediate,
                                        onError: { _ in },
                                        onChange: { [weak self] rows in
            MainActor.assumeIsolated { self?.entries = rows }
        })

        let statsObs = ValueObservation.tracking { db -> HomeStats in
            let cal = Calendar.current
            let now = Date()
            let startOfDay = cal.startOfDay(for: now)
            let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfDay
            let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? startOfDay
            let rows = try Row.fetchAll(db, sql: "SELECT timestamp, numWords, speechDuration FROM history WHERE isArchived = 0")
            var s = HomeStats()
            var words = 0
            var secs = 0.0
            for r in rows {
                let ts: Date = r["timestamp"]
                let n: Int = r["numWords"] ?? 0
                let sp: Double = r["speechDuration"] ?? 0
                if ts >= startOfDay { s.wordsToday += n }
                if ts >= weekStart { s.wordsWeek += n }
                if sp > 0 { words += n; secs += sp }
            }
            s.avgWPM = secs > 0 ? Double(words) / (secs / 60) : 0
            let ledger = try UsageLedger.filter(Column("timestamp") >= monthStart).fetchAll(db)
            s.spendMonth = ledger.reduce(0) { $0 + $1.estimatedCostUSD }
            return s
        }
        statsCancellable = statsObs.start(in: Database.shared.dbQueue, scheduling: .immediate,
                                          onError: { _ in },
                                          onChange: { [weak self] s in
            MainActor.assumeIsolated { self?.stats = s }
        })
    }

    func archive(_ entry: HistoryEntry) {
        if playingID == entry.id { stopAudio() }
        let id = entry.id
        _ = try? Database.shared.write { db in
            try db.execute(sql: "UPDATE history SET isArchived = 1 WHERE id = ?", arguments: [id])
        }
    }

    func play(_ entry: HistoryEntry) {
        stopAudio()
        guard let path = entry.audioPath, FileManager.default.fileExists(atPath: path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            let proxy = HomePlayerDelegate { [weak self] in
                Task { @MainActor in self?.playingID = nil }
            }
            p.delegate = proxy
            delegateProxy = proxy
            player = p
            p.play()
            playingID = entry.id
        } catch {
            playingID = nil
        }
    }

    func stopAudio() {
        player?.stop()
        player = nil
        playingID = nil
    }
}

final class HomePlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
}

// MARK: - View

struct HomeView: View {
    @State private var model = HomeViewModel()
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var showRaw: Set<String> = []

    private var controller: DictationController { DictationController.shared }

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.entries }
        return model.entries.filter {
            $0.asrText.localizedCaseInsensitiveContains(q)
            || ($0.pastedText?.localizedCaseInsensitiveContains(q) ?? false)
            || ($0.formattedText?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var groups: [(day: Date, items: [HistoryEntry])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.timestamp) }
        return dict.keys.sorted(by: >).map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = controller.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err).font(.callout).textSelection(.enabled)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.red.opacity(0.85))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                    HomeStatsStrip(stats: model.stats)
                    if model.entries.isEmpty {
                        emptyState
                    } else if filtered.isEmpty {
                        Text("No transcripts match \"\(search)\".")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ForEach(groups, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Self.dayTitle(group.day))
                                    .font(.headline).foregroundStyle(.secondary)
                                VStack(spacing: 0) {
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, entry in
                                        HomeRow(entry: entry, model: model,
                                                isExpanded: expanded.contains(entry.id),
                                                showRaw: showRaw.contains(entry.id),
                                                toggleExpand: { toggle(&expanded, entry.id) },
                                                toggleRaw: { toggle(&showRaw, entry.id) })
                                        if idx < group.items.count - 1 { Divider().padding(.leading, 12) }
                                    }
                                }
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Home")
        .searchable(text: $search, placement: .toolbar, prompt: "Search transcripts")
        .onAppear { model.start() }
        .onDisappear { model.stopAudio() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No dictations yet").font(.title3.weight(.semibold))
            Text("Hold Fn and talk. Hold Fn+Ctrl for cleanup.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

// MARK: - Stats strip

struct HomeStatsStrip: View {
    let stats: HomeStats

    var body: some View {
        HStack(spacing: 12) {
            tile("Words today", "\(stats.wordsToday)", "text.word.spacing")
            tile("Words this week", "\(stats.wordsWeek)", "calendar")
            tile("Average speed", stats.avgWPM > 0 ? "\(Int(stats.avgWPM.rounded())) wpm" : "–", "speedometer")
            tile("Claude spend (month)", String(format: "$%.2f", stats.spendMonth), "dollarsign.circle")
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Row

struct HomeRow: View {
    let entry: HistoryEntry
    let model: HomeViewModel
    let isExpanded: Bool
    let showRaw: Bool
    let toggleExpand: () -> Void
    let toggleRaw: () -> Void

    @State private var hovering = false

    private var isPlaying: Bool { model.playingID == entry.id }
    private var hasAudio: Bool {
        guard let p = entry.audioPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }
    private var rawDiffers: Bool {
        guard let f = entry.formattedText else { return false }
        return f != entry.asrText
    }
    private var rawFallback: Bool { entry.mode == .clean && entry.status == .rawTranscript }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let app = entry.appName, !app.isEmpty {
                    Text(app).font(.caption.weight(.medium))
                }
                modeBadge
                if rawFallback {
                    Text("raw fallback").font(.caption2).foregroundStyle(.red)
                        .help(entry.errorMessage ?? "Cleanup failed; the raw transcript was pasted.")
                }
                Spacer()
                if hovering || isPlaying { actions }
                Text("\(entry.numWords) words").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1fs", entry.e2eLatency)).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(entry.displayText)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showRaw {
                if rawDiffers {
                    HStack(alignment: .top, spacing: 12) {
                        column("Heard (ASR)", entry.asrText)
                        column("Formatted", entry.formattedText ?? "")
                    }
                } else {
                    Text("Raw transcript is identical to the final text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { toggleExpand() } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            if hasAudio { Button(isPlaying ? "Stop audio" : "Play audio") { togglePlay() } }
            Button(showRaw ? "Hide raw transcript" : "Show raw transcript") { toggleRaw() }
            Divider()
            Button("Delete", role: .destructive) { model.archive(entry) }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if hasAudio {
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                }.help(isPlaying ? "Stop" : "Play audio")
            }
            Button { toggleRaw() } label: { Image(systemName: "text.alignleft") }
                .help("Show raw transcript")
            Button { copy() } label: { Image(systemName: "doc.on.doc") }.help("Copy")
            Button { model.archive(entry) } label: { Image(systemName: "trash") }.help("Delete")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var modeBadge: some View {
        let (label, color): (String, Color) = {
            switch entry.mode {
            case .raw: return ("RAW", .gray)
            case .clean: return ("CLEAN", .blue)
            case .command: return ("COMMAND", .purple)
            case .transform: return ("TRANSFORM", .orange)
            }
        }()
        return Text(label).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func column(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func copy() { TextInserter.copyToClipboard(entry.displayText) }
    private func togglePlay() { isPlaying ? model.stopAudio() : model.play(entry) }
}
