import Foundation
import AppKit
import ApplicationServices

/// Watches a text field after we paste; if the user corrects a word, learns the correction.
/// Mirrors Wispr's auto-learn: only proper nouns / unknown words, never URLs, numbers, code or common words.
enum AutoLearn {
    struct Watch {
        let historyID: String
        let element: AXUIElement
        let pasted: String
        let before: String
        let after: String
    }

    static func schedule(_ w: Watch) {
        guard Settings.shared.autoLearnWords, TextProcessor.wordCount(w.pasted) >= 1 else { return }
        for delay in [20.0, 60.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { check(w) }
        }
    }

    private static var learnedThisSession = Set<String>()

    private static func check(_ w: Watch) {
        guard let value = ContextReader.stringAttr(w.element, kAXValueAttribute), !value.isEmpty else { return }
        // Locate the pasted region using the text that surrounded it.
        var region = value
        if !w.before.isEmpty, let r = value.range(of: String(w.before.suffix(80)), options: .backwards) {
            region = String(value[r.upperBound...])
        }
        if !w.after.isEmpty, let r = region.range(of: String(w.after.prefix(80))) {
            region = String(region[..<r.lowerBound])
        }
        // Keep the comparison bounded to roughly the pasted length.
        let maxLen = Int(Double(w.pasted.count) * 1.5) + 40
        if region.count > maxLen { region = String(region.prefix(maxLen)) }
        guard region != w.pasted else { return }

        var learned = 0
        for (old, new) in TextProcessor.substitutions(before: w.pasted, after: region) {
            guard learned < 3, isLearnable(old: old, new: new) else { continue }
            let key = new.lowercased()
            guard !learnedThisSession.contains(key) else { continue }
            learnedThisSession.insert(key)
            let needsReplacement = old.lowercased() != new.lowercased()
            Database.shared.upsertDictionary(phrase: needsReplacement ? old : new,
                                             replacement: needsReplacement ? new : nil, source: "auto")
            learned += 1
            Notifier.notify("Learned \"\(new)\"", "Added to your dictionary from your edit.")
        }
        if learned > 0 {
            try? Database.shared.write { db in
                if var h = try HistoryEntry.fetchOne(db, key: w.historyID) {
                    h.editedText = region
                    try h.update(db)
                }
            }
        }
    }

    private static let checker = NSSpellChecker.shared

    static func isLearnable(old: String, new: String) -> Bool {
        let n = new.trimmingCharacters(in: .punctuationCharacters)
        guard n.count >= 3, n.count <= 40 else { return false }
        guard n.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return false } // no numbers, urls, code
        if n.contains("http") || n.contains("@") || n.contains("/") { return false }
        // Must look like a proper noun or a word the system dictionary doesn't know.
        let capitalized = n.first!.isUppercase
        let misspelledRange = checker.checkSpelling(of: n, startingAt: 0)
        let unknownToDictionary = misspelledRange.location != NSNotFound
        guard capitalized || unknownToDictionary else { return false }
        // Common capitalized words (sentence starts) are not names.
        if !unknownToDictionary && TextProcessor.looksLikeProperNoun(n) == false { return false }
        // The old word should be phonetically-ish similar (same first letter or similar length) to avoid learning rewrites.
        let o = old.lowercased(), nn = n.lowercased()
        guard abs(o.count - nn.count) <= 4 else { return false }
        return o.first == nn.first || TextProcessor.similarity(o, nn) > 0 || o.prefix(2) == nn.prefix(2)
    }
}
