import Foundation

/// Local, on-device text post-processing: dictionary/snippet substitution, spacing and casing.
enum TextProcessor {

    struct Result {
        var text: String
        var dictionaryReplacements: Int
    }

    /// Applies snippet expansions and dictionary replacements. Case-insensitive, whole-word, longest phrase first.
    static func applyDictionary(_ input: String, entries: [DictionaryEntry]) -> Result {
        var text = input
        var count = 0
        let candidates = entries
            .filter { !$0.isDeleted && $0.phrase.count >= 2 }
            .sorted { $0.phrase.count > $1.phrase.count }

        for e in candidates {
            let phrase = e.phrase.trimmingCharacters(in: .whitespaces)
            // Vocabulary words with no replacement: enforce the user's casing/spelling for case-insensitive matches.
            let replacement = e.replacement?.isEmpty == false ? e.replacement! : phrase
            if replacement == phrase && !e.isSnippet && phrase.lowercased() == phrase {
                continue // lowercase vocab word with no replacement changes nothing
            }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = re.matches(in: text, range: range)
            guard !matches.isEmpty else { continue }
            // Replace from the end so ranges stay valid.
            for m in matches.reversed() {
                guard let r = Range(m.range, in: text) else { continue }
                let original = String(text[r])
                if original == replacement { continue }
                // Snippets expand fully; a standalone trigger yields exactly the expansion.
                text.replaceSubrange(r, with: replacement)
                count += 1
            }
        }
        return Result(text: text, dictionaryReplacements: count)
    }

    /// Adjusts the first character's case and adds a leading/trailing space to fit the surrounding text.
    static func fitToContext(_ text: String, before: String?, after: String?) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        let b = before ?? ""
        let a = after ?? ""

        // Mid-sentence insertion → lowercase first letter unless it looks like a proper noun / "I".
        if let lastNonSpace = b.reversed().first(where: { !$0.isWhitespace }) {
            let endsSentence = ".!?\n:".contains(lastNonSpace) || b.hasSuffix("\n")
            let opensQuoteOrBracket = "([\"'“‘".contains(lastNonSpace)
            if !endsSentence && !opensQuoteOrBracket {
                let firstWord = t.split(separator: " ").first.map(String.init) ?? t
                if firstWord != "I" && !firstWord.hasPrefix("I'") && !looksLikeProperNoun(firstWord) {
                    t = t.prefix(1).lowercased() + t.dropFirst()
                }
            }
        }

        // Text after the cursor continues the sentence → drop our trailing period.
        if let firstAfter = a.first(where: { !$0.isWhitespace }), !".!?\n".contains(firstAfter),
           firstAfter.isLetter, firstAfter.isLowercase, t.hasSuffix(".") {
            t.removeLast()
        }

        // Leading space if the previous char is not whitespace or an opening bracket/quote.
        if let last = b.last, !last.isWhitespace, !"([\"'“‘/-".contains(last) {
            t = " " + t
        }
        // Trailing space if the next char is a letter/number (we are inserting in the middle of a word boundary).
        if let next = a.first, next.isLetter || next.isNumber {
            t += " "
        }
        return t
    }

    private static let commonCapitalized: Set<String> = ["The", "A", "An", "This", "That", "It", "We", "You", "They", "He", "She",
        "So", "And", "But", "Or", "If", "When", "What", "Why", "How", "Where", "Who", "Yes", "No", "Okay", "Ok", "Hey", "Hi",
        "Hello", "Thanks", "Thank", "Please", "Let", "Let's", "Can", "Could", "Would", "Should", "Do", "Does", "Did", "Is",
        "Are", "Was", "Were", "Will", "Just", "Also", "Then", "Now", "Here", "There", "Not", "My", "Your", "Our", "Their",
        "For", "In", "On", "At", "To", "Of", "With", "By", "From", "As", "Be", "Have", "Has", "Had", "Get", "Got", "Make",
        "One", "Two", "Three", "First", "Second", "Next", "Last", "Maybe", "Actually", "Basically", "Well", "Right", "Sure"]

    static func looksLikeProperNoun(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        guard let f = w.first, f.isUppercase else { return false }
        if commonCapitalized.contains(w) { return false }
        // All-caps acronyms and CamelCase count as proper nouns.
        if w.count > 1 && w == w.uppercased() { return true }
        return true
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// 0...1 similarity of word sequences (LCS / max length). Used to detect runaway rewrites.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wb = b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if wa.isEmpty || wb.isEmpty { return wa.isEmpty && wb.isEmpty ? 1 : 0 }
        var prev = [Int](repeating: 0, count: wb.count + 1)
        for i in 1...wa.count {
            var cur = [Int](repeating: 0, count: wb.count + 1)
            for j in 1...wb.count {
                cur[j] = wa[i-1] == wb[j-1] ? prev[j-1] + 1 : max(prev[j], cur[j-1])
            }
            prev = cur
        }
        return Double(prev[wb.count]) / Double(max(wa.count, wb.count))
    }

    /// Words in `after` that replaced words in `before` (simple LCS diff); used by auto-learn.
    static func substitutions(before: String, after: String) -> [(old: String, new: String)] {
        let wa = before.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        let wb = after.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        guard !wa.isEmpty, !wb.isEmpty, wa.count < 600, wb.count < 600 else { return [] }
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: wb.count + 1), count: wa.count + 1)
        for i in stride(from: wa.count - 1, through: 0, by: -1) {
            for j in stride(from: wb.count - 1, through: 0, by: -1) {
                lcs[i][j] = wa[i].lowercased() == wb[j].lowercased() ? lcs[i+1][j+1] + 1 : max(lcs[i+1][j], lcs[i][j+1])
            }
        }
        var i = 0, j = 0
        var result: [(String, String)] = []
        var pendingOld: [String] = [], pendingNew: [String] = []
        func flush() {
            if pendingOld.count == 1 && pendingNew.count == 1 { result.append((pendingOld[0], pendingNew[0])) }
            else if pendingOld.count == pendingNew.count && pendingOld.count <= 3 {
                for k in 0..<pendingOld.count { result.append((pendingOld[k], pendingNew[k])) }
            }
            pendingOld = []; pendingNew = []
        }
        while i < wa.count && j < wb.count {
            if wa[i].lowercased() == wb[j].lowercased() { flush(); i += 1; j += 1 }
            else if lcs[i+1][j] >= lcs[i][j+1] { pendingOld.append(wa[i]); i += 1 }
            else { pendingNew.append(wb[j]); j += 1 }
        }
        while i < wa.count { pendingOld.append(wa[i]); i += 1 }
        while j < wb.count { pendingNew.append(wb[j]); j += 1 }
        flush()
        return result.filter { !$0.0.isEmpty && !$0.1.isEmpty && $0.0.lowercased() != $0.1.lowercased() }
    }
}
