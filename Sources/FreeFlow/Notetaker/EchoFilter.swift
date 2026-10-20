import Foundation

/// Removes speaker bleed from meeting transcripts. Without headphones the mic hears the other side through the
/// speakers, so each "Them" line comes back a few ms later as a near-identical "Me" line. The system-audio channel
/// never contains the user's voice, so only mic segments can be echoes.
enum EchoFilter {
    struct Span {
        var text: String
        var startMs: Int
        var endMs: Int
    }

    /// Indices of `mic` segments that are echoes of `system` audio.
    static func echoIndices(mic: [Span], system: [Span]) -> IndexSet {
        let sys = system.map { (span: $0, words: words($0.text)) }
        var result = IndexSet()
        for (i, m) in mic.enumerated() {
            let mw = words(m.text)
            guard !mw.isEmpty else { continue }
            // Speech recognition splits the two channels differently, so compare against every system segment near this one.
            let near = sys.filter { $0.span.endMs >= m.startMs - 1500 && $0.span.startMs <= m.endMs + 1500 }
            guard !near.isEmpty else { continue }
            if isEcho(words: mw, span: m, near: near) { result.insert(i) }
        }
        return result
    }

    private static func isEcho(words mw: [String], span m: Span, near: [(span: Span, words: [String])]) -> Bool {
        // An echo starts or ends within a fraction of a second of the original; misheard copies still line up in time.
        let aligned = near.filter { abs($0.span.startMs - m.startMs) <= 500 || abs($0.span.endMs - m.endMs) <= 500 }
        // "Yeah", "No worries": too common to judge by words alone, so they must repeat the system line they line up with.
        if mw.count <= 2 { return aligned.contains { 2 * overlap(mw, $0.words) >= Double(mw.count) } }
        let coverage = overlap(mw, near.flatMap(\.words)) / Double(mw.count)
        return coverage >= 0.6 || (!aligned.isEmpty && coverage >= 0.34)
    }

    /// True when most of `text` is a passage of `source` (for the live, not-yet-final mic line).
    static func repeats(_ text: String, of source: String) -> Bool {
        let w = words(text)
        guard !w.isEmpty else { return false }
        return overlap(w, words(source)) >= 0.6 * Double(w.count)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    /// How many words of `a` appear, in order, as one contiguous passage somewhere in `b`. Fuzzy word equality because
    /// the two channels mishear words differently; skipping words of `b` inside the passage costs half a match, so
    /// common words scattered across a long monologue ("yeah ... for ... sure") don't add up to a match.
    private static func overlap(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Double](repeating: 0, count: b.count + 1) // the passage may start anywhere in b
        var cur = prev
        var best = 0.0
        for x in a {
            cur[0] = 0
            for (j, y) in b.enumerated() {
                cur[j + 1] = max(prev[j] + (similar(x, y) ? 1 : 0), // match, or a misheard word
                                 prev[j + 1],                        // word of a missing from b
                                 cur[j] - 0.5)                       // extra word in b
            }
            swap(&prev, &cur)
        }
        for v in prev { best = max(best, v) } // ...and end anywhere
        return best
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        let d = levenshtein(Array(a), Array(b))
        return Double(d) / Double(max(a.count, b.count)) <= 0.34
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var diag = row[0]
            row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let up = row[j + 1]
                row[j + 1] = ca == cb ? diag : min(diag, row[j], row[j + 1]) + 1
                diag = up
            }
        }
        return row[b.count]
    }
}
