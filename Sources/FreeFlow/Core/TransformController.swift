import Foundation
import AppKit
import Carbon.HIToolbox

/// Runs hotkey Transforms (Polish, Prompt Engineer, custom) on the selection / field / last dictation.
@MainActor
final class TransformController {
    static let shared = TransformController()
    private(set) var isRunning = false
    private var lastDictation: (text: String, at: Date)?

    private init() {}

    func noteDictation(_ text: String) { lastDictation = (text, Date()) }

    // MARK: - Shortcuts

    struct Shortcut: Equatable { let flags: CGEventFlags; let keyCode: Int }

    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
        "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "`": kVK_ANSI_Grave, "\\": kVK_ANSI_Backslash,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    /// Parses "opt+1", "ctrl+opt+p", "cmd+shift+l". Requires at least one modifier and exactly one key.
    static func parse(_ text: String) -> Shortcut? {
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard parts.count >= 2, let key = parts.last, let code = keyCodes[key] else { return nil }
        var flags = CGEventFlags()
        for m in parts.dropLast() {
            switch m {
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            default: return nil
            }
        }
        guard !flags.isEmpty else { return nil }
        return Shortcut(flags: flags, keyCode: code)
    }

    static func display(_ text: String?) -> String {
        guard let text, let _ = parse(text) else { return "" }
        return text.lowercased().split(separator: "+").map { part -> String in
            switch part {
            case "opt", "option", "alt": return "⌥"
            case "ctrl", "control": return "⌃"
            case "cmd", "command": return "⌘"
            case "shift": return "⇧"
            default: return part.uppercased()
            }
        }.joined()
    }

    func reloadShortcuts() {
        var table: [(Shortcut, String)] = []
        if Settings.shared.transformsEnabled {
            for t in Database.shared.transforms() where t.enabled && !t.isDeleted {
                if let sc = t.shortcut, let parsed = TransformController.parse(sc) { table.append((parsed, t.id)) }
            }
        }
        HotkeyManager.shared.transformShortcuts = table.map { (flags: $0.0.flags, keyCode: $0.0.keyCode, id: $0.1) }
    }

    // MARK: - Run

    func run(transformID: String) {
        guard !isRunning, DictationController.shared.state == .idle else { return }
        guard let transform = Database.shared.transforms().first(where: { $0.id == transformID }) else { return }
        let ctx = ContextReader.capture(readText: true)

        // Input: selection → whole field → last dictation (60 s).
        var input = ctx.selectedText ?? ""
        var scope = "selection"
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = ctx.fieldText ?? ""
            scope = "field"
        }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let last = lastDictation, Date().timeIntervalSince(last.at) < 60 {
            input = last.text
            scope = "lastDictation"
        }
        let words = TextProcessor.wordCount(input)
        guard words >= 1 else { Notifier.notify("Nothing to transform", "Select some text first."); return }
        guard words <= 3000 else { Notifier.notify("Too much text", "Transforms work on up to 3,000 words."); return }

        isRunning = true
        FlowBarController.shared.showProcessing("\(transform.name)…")
        Sounds.play(.start)
        Log.write("transform \(transform.name) on \(scope) (\(words) words)")

        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            do {
                let output = try await self.apply(transform, to: input, ctx: ctx)
                guard !output.isEmpty, output != input else {
                    FlowBarController.shared.flash(message: "No changes"); return
                }
                if scope == "field" {
                    self.selectAll(ctx)
                    try? await Task.sleep(for: .milliseconds(60))
                }
                var entry = HistoryEntry()
                entry.mode = .transform
                entry.instruction = transform.name
                entry.appBundleID = ctx.appBundleID; entry.appName = ctx.appName; entry.url = ctx.url
                entry.category = ctx.category
                entry.asrText = input
                entry.formattedText = output
                entry.pastedText = output
                entry.numWords = TextProcessor.wordCount(output)
                if ctx.hasFocusedElement {
                    _ = TextInserter.paste(output, context: ctx)
                    entry.status = .formatted
                    FlowBarController.shared.flashDone()
                } else {
                    TextInserter.copyToClipboard(output)
                    entry.status = .formatted
                    FlowBarController.shared.flash(message: "Result copied to clipboard")
                }
                try? Database.shared.write { db in try entry.insert(db) }
                DictationController.shared.setLastPasted(output)
            } catch {
                FlowBarController.shared.flash(message: error.localizedDescription, isError: true)
                Sounds.play(.error)
            }
        }
    }

    /// Applies a transform and returns the text (used by hotkeys and by "auto-apply after dictation").
    func apply(_ transform: Transform, to input: String, ctx: InsertionContext?) async throws -> String {
        try await TransformController.applyTransform(transform, to: input, ctx: ctx)
    }

    /// Actor-free worker so self-tests (which block the main thread) can call it too.
    nonisolated static func applyTransform(_ transform: Transform, to input: String, ctx: InsertionContext?) async throws -> String {
        let instruction = transform.builtInKey == "polish" ? Prompts.polishInstruction(rules: Settings.shared.polishRules) : transform.prompt
        var lines: [String] = []
        if let ctx {
            lines.append("APP: \(ctx.appName ?? "unknown"), CATEGORY: \(ctx.category.rawValue)")
            if let u = ctx.url { lines.append("URL: \(u)") }
        }
        lines.append("USER NAME: \(Settings.shared.userFirstName) \(Settings.shared.userLastName)")
        let user = "<context>\n\(lines.joined(separator: "\n"))\n</context>\n\n<transform name=\"\(transform.name)\">\n\(instruction)\n</transform>\n\n<input>\n\(input)\n</input>"
        let req = ClaudeClient.Request(model: Settings.shared.commandModel, system: Prompts.transformSystem(),
                                       userContent: user, maxTokens: 8192, effort: "low", disableThinking: true, timeout: 45)
        let resp = try await ClaudeClient.shared.send(req, feature: "transform")
        var text = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") && !input.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func selectAll(_ ctx: InsertionContext) {
        if let box = ctx.focusedElement, let text = ctx.fieldText {
            var range = CFRange(location: 0, length: (text as NSString).length)
            if let v = AXValueCreate(.cfRange, &range),
               AXUIElementSetAttributeValue(box.element, kAXSelectedTextRangeAttribute as CFString, v) == .success { return }
        }
        TextInserter.selectAll()
    }
}
