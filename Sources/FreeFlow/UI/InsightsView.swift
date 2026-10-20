import SwiftUI
import GRDB

struct InsightsData {
    var avgWPM: Double = 0
    var totalWords = 0
    var wordsThisWeek = 0
    var fixes = 0
    var minutesSaved: Double = 0
    var dayStreak = 0
    var weekStreak = 0
    var byCategory: [(AppCategory, Int)] = []
    var topApps: [(String, Int)] = []
    var wordsByDay: [Date: Int] = [:]
    var costMonth = 0.0
    var costAll = 0.0
    var byFeature: [(feature: String, cost: Double, calls: Int, input: Int, output: Int)] = []
    var inputTokens = 0
    var outputTokens = 0
}

@MainActor
@Observable
final class InsightsViewModel {
    var data = InsightsData()
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?

    func start() {
        guard cancellable == nil else { return }
        let obs = ValueObservation.tracking { db -> ([HistoryEntry], [UsageLedger]) in
            (try HistoryEntry.filter(Column("isArchived") == false).fetchAll(db),
             try UsageLedger.fetchAll(db))
        }
        cancellable = obs.start(in: Database.shared.dbQueue, scheduling: .immediate,
                                onError: { _ in },
                                onChange: { [weak self] pair in
            let d = Self.compute(history: pair.0, ledger: pair.1)
            MainActor.assumeIsolated { self?.data = d }
        })
    }

    nonisolated static func compute(history: [HistoryEntry], ledger: [UsageLedger]) -> InsightsData {
        var d = InsightsData()
        var cal = Calendar.current
        cal.firstWeekday = 1
        let now = Date()
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? cal.startOfDay(for: now)

        var spokenWords = 0
        var speech = 0.0
        var cat: [AppCategory: Int] = [:]
        var apps: [String: Int] = [:]
        for e in history where e.status == .formatted || e.status == .rawTranscript {
            d.totalWords += e.numWords
            if e.timestamp >= weekStart { d.wordsThisWeek += e.numWords }
            d.fixes += e.numWordsCorrected + e.numDictionaryReplacements
            if e.speechDuration > 0 { spokenWords += e.numWords; speech += e.speechDuration }
            cat[e.category, default: 0] += e.numWords
            if let n = e.appName, !n.isEmpty { apps[n, default: 0] += e.numWords }
            d.wordsByDay[cal.startOfDay(for: e.timestamp), default: 0] += e.numWords
        }
        d.avgWPM = speech > 0 ? Double(spokenWords) / (speech / 60) : 0
        if d.avgWPM > 0 {
            d.minutesSaved = max(0, Double(d.totalWords) / 45 - Double(d.totalWords) / d.avgWPM)
        }
        d.byCategory = cat.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        d.topApps = apps.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }

        // Streaks
        let activeDays = Set(d.wordsByDay.filter { $0.value > 0 || true }.keys)
        var day = cal.startOfDay(for: now)
        if !activeDays.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        while activeDays.contains(day) {
            d.dayStreak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        let activeWeeks = Set(activeDays.compactMap { cal.dateInterval(of: .weekOfYear, for: $0)?.start })
        var wk = weekStart
        if !activeWeeks.contains(wk) { wk = cal.date(byAdding: .weekOfYear, value: -1, to: wk) ?? wk }
        while activeWeeks.contains(wk) {
            d.weekStreak += 1
            guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: wk) else { break }
            wk = prev
        }

        // Cost
        var feat: [String: (Double, Int, Int, Int)] = [:]
        for l in ledger {
            d.costAll += l.estimatedCostUSD
            if l.timestamp >= monthStart { d.costMonth += l.estimatedCostUSD }
            d.inputTokens += l.inputTokens + l.cacheReadTokens + l.cacheWriteTokens
            d.outputTokens += l.outputTokens
            var f = feat[l.feature] ?? (0, 0, 0, 0)
            f.0 += l.estimatedCostUSD; f.1 += 1
            f.2 += l.inputTokens + l.cacheReadTokens + l.cacheWriteTokens; f.3 += l.outputTokens
            feat[l.feature] = f
        }
        d.byFeature = feat.map { (feature: $0.key, cost: $0.value.0, calls: $0.value.1, input: $0.value.2, output: $0.value.3) }
            .sorted { $0.cost > $1.cost }
        return d
    }
}

struct InsightsView: View {
    @State private var model = InsightsViewModel()
    private let typingWPM = 45.0

    var body: some View {
        let d = model.data
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your usage").font(.title2.weight(.semibold))
                let cols = [GridItem(.adaptive(minimum: 190), spacing: 12)]
                LazyVGrid(columns: cols, spacing: 12) {
                    wpmCard(d)
                    statCard("Total words dictated", "\(d.totalWords.formatted())", "text.word.spacing")
                    statCard("Words this week", "\(d.wordsThisWeek.formatted())", "calendar")
                    statCard("Fixes by FreeFlow", "\(d.fixes.formatted())", "wand.and.stars",
                             sub: "corrections + dictionary replacements")
                    statCard("Time saved", Self.formatMinutes(d.minutesSaved), "clock",
                             sub: "vs typing at ~45 wpm")
                    statCard("Day streak", "\(d.dayStreak)", "flame", sub: d.dayStreak == 1 ? "day" : "days")
                    statCard("Week streak", "\(d.weekStreak)", "flame.fill", sub: d.weekStreak == 1 ? "week" : "weeks")
                }

                card("Activity (last 12 weeks)") { InsightsHeatmap(wordsByDay: d.wordsByDay) }

                HStack(alignment: .top, spacing: 12) {
                    card("By category") {
                        InsightsBars(items: d.byCategory.map { ($0.0.displayName, $0.1) }, color: .blue)
                    }
                    card("Top apps") {
                        InsightsBars(items: d.topApps, color: .teal)
                    }
                }

                costCard(d)
            }
            .padding(20)
        }
        .navigationTitle("Insights")
        .onAppear { model.start() }
    }

    private func wpmCard(_ d: InsightsData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Average speed", systemImage: "speedometer").font(.caption).foregroundStyle(.secondary)
            Text(d.avgWPM > 0 ? "\(Int(d.avgWPM.rounded())) wpm" : "–")
                .font(.title.weight(.semibold)).monospacedDigit()
            if d.avgWPM > 0 {
                Text(String(format: "vs ~45 wpm typing (%.1f×)", d.avgWPM / typingWPM))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("vs ~45 wpm typing").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func statCard(_ title: String, _ value: String, _ icon: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
            Text(sub ?? " ").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func costCard(_ d: InsightsData) -> some View {
        card("Claude API cost") {
            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("This month").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "$%.4f", d.costMonth)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                VStack(alignment: .leading) {
                    Text("All time").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "$%.4f", d.costAll)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                VStack(alignment: .leading) {
                    Text("Tokens in / out").font(.caption).foregroundStyle(.secondary)
                    Text("\(d.inputTokens.formatted()) / \(d.outputTokens.formatted())")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                }
            }
            if d.byFeature.isEmpty {
                Text("No Claude calls recorded yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(d.byFeature, id: \.feature) { f in
                    HStack {
                        Text(f.feature.capitalized).frame(width: 90, alignment: .leading)
                        Text("\(f.calls) calls").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text("\(f.input.formatted()) in / \(f.output.formatted()) out")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "$%.4f", f.cost)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    static func formatMinutes(_ m: Double) -> String {
        if m < 1 { return "0 min" }
        if m < 60 { return "\(Int(m.rounded())) min" }
        let h = Int(m) / 60
        return "\(h) h \(Int(m) % 60) min"
    }
}

// MARK: - Bars

struct InsightsBars: View {
    let items: [(String, Int)]
    let color: Color

    var body: some View {
        if items.isEmpty {
            Text("No data yet.").font(.callout).foregroundStyle(.secondary)
        } else {
            let maxV = max(items.map { $0.1 }.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.0).font(.callout).lineLimit(1)
                            Spacer()
                            Text(item.1.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color.opacity(0.75))
                                .frame(width: max(3, geo.size.width * CGFloat(item.1) / CGFloat(maxV)))
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }
}

// MARK: - Heatmap

struct InsightsHeatmap: View {
    let wordsByDay: [Date: Int]

    private static func band(_ w: Int) -> Int {
        switch w { case ..<1: return 0; case 1..<250: return 1; case 250..<500: return 2; case 500..<750: return 3; default: return 4 }
    }

    private func color(_ w: Int) -> Color {
        let b = Self.band(w)
        return b == 0 ? Color.primary.opacity(0.08) : Color.green.opacity(0.25 + 0.2 * Double(b - 1))
    }

    var body: some View {
        var cal = Calendar.current
        cal.firstWeekday = 1
        let today = cal.startOfDay(for: Date())
        let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstWeek = cal.date(byAdding: .weekOfYear, value: -11, to: thisWeekStart) ?? thisWeekStart
        let labels = ["S", "M", "T", "W", "T", "F", "S"]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(labels[r]).font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: 12, height: 18)
                    }
                }
                ForEach(0..<12, id: \.self) { col in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { row in
                            let off = col * 7 + row
                            let day = cal.date(byAdding: .day, value: off, to: firstWeek) ?? firstWeek
                            let w = wordsByDay[day] ?? 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(day > today ? Color.clear : color(w))
                                .frame(height: 18)
                                .frame(minWidth: 18)
                                .help(day > today ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)): \(w) words")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 4) {
                Spacer()
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach([0, 1, 250, 500, 750], id: \.self) { v in
                    RoundedRectangle(cornerRadius: 2).fill(color(v)).frame(width: 12, height: 12)
                }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
