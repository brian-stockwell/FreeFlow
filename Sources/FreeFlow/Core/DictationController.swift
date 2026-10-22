import Foundation
import AppKit
import AVFoundation
import Observation

/// The state machine behind the hotkeys: record → transcribe → (Claude) → paste.
@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()

    enum State: Equatable {
        case idle
        case recording
        case processing
    }

    private(set) var state: State = .idle
    private(set) var mode: DictationMode = .raw
    private(set) var handsFree = false
    private(set) var level: Float = 0
    private(set) var liveText = ""
    private(set) var recordingStart: Date?
    private(set) var lastPastedText: String?
    private(set) var lastError: String?
    var hotkeysPaused = false { didSet { HotkeyManager.shared.swallowFn = !hotkeysPaused } }

    private let recorder = AudioRecorder()
    private var session: SpeechSession?
    private var contextTask: Task<InsertionContext, Never>?
    private var pendingFinish: DispatchWorkItem?
    private var fnDownAt: Date?
    private var handsFreeSince: Date?
    private var maxDurationTimer: Timer?
    private var warnTimer: Timer?
    private var currentAudioURL: URL?
    private var keyPressesSinceStart = 0
    /// Incremented every time a recording is finalized; a processing task whose generation is stale drops its result.
    private var generation = 0
    private var lastShortTapEndedAt: Date?

    private init() {}

    // MARK: - Lifecycle

    func setLastPasted(_ text: String) { lastPastedText = text }

    func start() {
        HotkeyManager.shared.handler = { [weak self] e in self?.handle(e) }
        TransformController.shared.reloadShortcuts()
        if !HotkeyManager.shared.start() {
            lastError = "Could not install the global hotkey listener. Grant Accessibility permission and relaunch."
            Log.write("hotkeys: tap creation FAILED (accessibility trusted: \(Permissions.accessibilityGranted))")
        }
        Task { await SpeechEngine.warmUp() }
    }

    func restartHotkeys() {
        HotkeyManager.shared.stop()
        _ = HotkeyManager.shared.start()
    }

    // MARK: - Hotkey events

    private func handle(_ e: HotkeyEvent) {
        if hotkeysPaused { return }
        switch e {
        case .fnDown(let ctrl, let opt):
            keyPressesSinceStart = 0
            let m: DictationMode = opt && Settings.shared.commandModeEnabled ? .command : (ctrl ? .clean : .raw)
            // A second tap shortly after a short tap = double-tap, even if the first tap already finalized.
            if state != .recording, let t = lastShortTapEndedAt, Date().timeIntervalSince(t) < 0.7 {
                lastShortTapEndedAt = nil
                generation += 1            // discard the short tap's in-flight result
                state = .idle
                fnDownAt = Date()
                beginRecording(mode: m, handsFree: true)
                handsFreeSince = Date()
                Log.write("double-tap → hands-free (takeover)")
                return
            }
            switch state {
            case .idle:
                fnDownAt = Date()
                beginRecording(mode: m, handsFree: false)
            case .recording:
                if handsFree {
                    // Hands-free: a Fn press always finishes (Esc cancels).
                    finishAndProcess()
                } else if pendingFinish != nil {
                    // Second tap within 0.5 s → lock into hands-free.
                    pendingFinish?.cancel(); pendingFinish = nil
                    handsFree = true
                    handsFreeSince = Date()
                    Sounds.play(.ready)
                    Log.write("double-tap → hands-free")
                }
            case .processing:
                break
            }
        case .fnUp:
            guard state == .recording, !handsFree else { return }
            let held = fnDownAt.map { Date().timeIntervalSince($0) } ?? 1
            if Settings.shared.handsFreeDoubleTap && held < 0.6 { lastShortTapEndedAt = Date() }
            if Settings.shared.handsFreeDoubleTap && held < 0.6 {
                // Short tap: wait for a possible second tap (double-tap = hands-free) before finalizing.
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingFinish = nil
                    self?.finishAndProcess()
                }
                pendingFinish = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            } else {
                finishAndProcess()
            }
        case .ctrlDown:
            if state == .recording && mode != .clean { mode = .clean; Sounds.play(.modeSwitch); Log.write("mode → clean") }
        case .optionDown:
            if state == .recording && Settings.shared.commandModeEnabled && mode != .command { mode = .command; Sounds.play(.modeSwitch); Log.write("mode → command") }
        case .spaceWhileFn:
            if state == .recording {
                if handsFree { finishAndProcess() }
                else { pendingFinish?.cancel(); pendingFinish = nil; handsFree = true; handsFreeSince = Date(); Sounds.play(.ready) }
            }
        case .escape:
            cancel()
        case .pasteLast:
            if let t = lastPastedText {
                let ctx = ContextReader.capture(readText: false)
                _ = TextInserter.paste(t, context: ctx)
            }
        case .copyLast:
            if let t = lastPastedText { TextInserter.copyToClipboard(t); Notifier.notify("Copied last transcript") }
        case .startMeeting:
            MeetingRecorder.shared.toggle()
        case .meetingControlTap:
            if state == .idle { MeetingRecorder.shared.switchKind() }
        case .otherKeyDown:
            keyPressesSinceStart += 1   // informational only; other keys never cancel a dictation
        case .transform(let id):
            TransformController.shared.run(transformID: id)
        }
    }

    // MARK: - Recording

    func beginHandsFree(mode: DictationMode = .raw) {
        guard state == .idle else { return }
        beginRecording(mode: mode, handsFree: true)
        handsFreeSince = Date()
    }

    private func beginRecording(mode: DictationMode, handsFree: Bool) {
        guard state == .idle else { return }
        self.mode = mode
        self.handsFree = handsFree
        self.liveText = ""
        self.lastError = nil
        state = .recording
        FlowBarController.shared.clearMessage()
        recordingStart = Date()
        HotkeyManager.shared.isCapturing = true
        Sounds.play(.start)

        // Capture context off the main thread while the mic spins up.
        let readText = Settings.shared.contextAwareness || mode == .command
        contextTask = Task.detached(priority: .userInitiated) {
            await MainActor.run { ContextReader.capture(readText: readText) }
        }

        let dictionary = Database.shared.activeDictionary()
        var contextual = dictionary.filter { !$0.isSnippet }.map { $0.replacement ?? $0.phrase }
        contextual.append(contentsOf: [Settings.shared.userFirstName, Settings.shared.userLastName].filter { !$0.isEmpty })

        let session = SpeechSession(contextualStrings: contextual, timeIndexed: false)
        self.session = session
        let audioURL = Database.shared.audioDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        currentAudioURL = audioURL

        Task { [weak self] in
            guard let self else { return }
            let format = await session.bestFormat()
            await session.setUpdateHandler { [weak self] final, volatile in
                Task { @MainActor in
                    self?.liveText = volatile.isEmpty ? final : (final.isEmpty ? volatile : final + " " + volatile)
                }
            }
            recorder.onBuffer = { buf in session.feed(buf) }
            recorder.onLevel = { [weak self] l in
                DispatchQueue.main.async { self?.level = l }
            }
            do {
                try recorder.start(targetFormat: format, fileURL: audioURL, deviceUID: Settings.shared.microphoneUID)
                try await session.start()
            } catch {
                self.fail("Microphone error: \(error.localizedDescription)")
            }
        }

        FlowBarController.shared.show()
        let maxMin = Double(Settings.shared.maxDictationMinutes)
        warnTimer = Timer.scheduledTimer(withTimeInterval: max(30, (maxMin - 1) * 60), repeats: false) { _ in
            Task { @MainActor in Notifier.notify("One minute left", "Dictation stops automatically at \(Int(maxMin)) minutes.") }
        }
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxMin * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishAndProcess() }
        }
    }

    func cancel() {
        pendingFinish?.cancel(); pendingFinish = nil
        guard state != .idle else { return }
        Log.write("cancel (state=\(state))")
        state = .idle
        HotkeyManager.shared.isCapturing = false
        stopTimers()
        recorder.stop()
        if let s = session { Task { await s.cancel() } }
        session = nil
        if let url = currentAudioURL { try? FileManager.default.removeItem(at: url) }
        currentAudioURL = nil
        Sounds.play(.cancel)
        FlowBarController.shared.flash(message: "Cancelled")
    }

    private func stopTimers() {
        maxDurationTimer?.invalidate(); maxDurationTimer = nil
        warnTimer?.invalidate(); warnTimer = nil
    }

    func finishAndProcess() {
        pendingFinish?.cancel(); pendingFinish = nil
        guard state == .recording, let session else { return }
        Log.write("finish (mode=\(mode) handsFree=\(handsFree))")
        state = .processing
        HotkeyManager.shared.isCapturing = false
        stopTimers()
        Sounds.play(.stop)
        let keyUpAt = Date()
        let (duration, speech) = recorder.stop()
        let mode = self.mode
        let audioURL = currentAudioURL
        let contextTask = self.contextTask
        self.session = nil
        generation += 1
        let myGeneration = generation

        Task { [weak self] in
            guard let self else { return }
            let asr = await session.finish()
            guard myGeneration == self.generation else {
                // Superseded by a double-tap takeover: drop this short tap silently.
                if let url = audioURL { try? FileManager.default.removeItem(at: url) }
                return
            }
            let ctx = await contextTask?.value ?? ContextReader.capture(readText: false)
            await self.process(asr: asr, mode: mode, ctx: ctx, duration: duration, speech: speech,
                               audioURL: audioURL, keyUpAt: keyUpAt)
        }
    }

    private func fail(_ message: String) {
        lastError = message
        state = .idle
        HotkeyManager.shared.isCapturing = false
        stopTimers()
        recorder.stop()
        session = nil
        Sounds.play(.error)
        Notifier.notify("FreeFlow", message)
    }

    // MARK: - Processing pipeline

    private func process(asr rawAsr: String, mode: DictationMode, ctx: InsertionContext,
                         duration: Double, speech: Double, audioURL: URL?, keyUpAt: Date) async {
        // The key-down capture can miss the field in Chromium apps; by now their accessibility tree has had time to build.
        let ctx = ctx.hasFocusedElement ? ctx : await refocus(ctx, mode: mode)
        var entry = HistoryEntry()
        entry.mode = mode
        entry.appBundleID = ctx.appBundleID
        entry.appName = ctx.appName
        entry.url = ctx.url
        entry.category = ctx.category
        entry.style = Settings.shared.style(for: ctx.category)
        entry.asrText = rawAsr
        entry.duration = duration
        entry.speechDuration = speech
        entry.audioPath = audioURL?.path

        let asr = rawAsr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asr.isEmpty else {
            if let url = audioURL { try? FileManager.default.removeItem(at: url) }
            entry.audioPath = nil
            if duration < 0.8 {
                // An accidental tap: no history row, no error flash (Wispr stays quiet here too).
                finishUI(message: nil, success: true, silent: true)
                return
            }
            entry.status = .noAudio
            save(entry)
            finishUI(message: "No speech detected", success: false)
            return
        }

        let dictionary = Database.shared.activeDictionary()
        let dict = TextProcessor.applyDictionary(asr, entries: dictionary)
        entry.numDictionaryReplacements = dict.dictionaryReplacements
        var toPaste = dict.text
        var status: DictationStatus = .rawTranscript

        switch mode {
        case .raw, .transform:
            toPaste = TextProcessor.fitToContext(dict.text, before: ctx.textBefore, after: ctx.textAfter)
            status = .rawTranscript

        case .clean:
            if Settings.shared.cleanupLevel == .none {
                toPaste = TextProcessor.fitToContext(dict.text, before: ctx.textBefore, after: ctx.textAfter)
            } else {
                do {
                    let (cleaned, usage, model) = try await cleanup(dict.text, ctx: ctx, dictionary: dictionary)
                    entry.model = model
                    entry.inputTokens = usage.inputTokens; entry.outputTokens = usage.outputTokens
                    entry.cacheReadTokens = usage.cacheReadTokens
                    let sim = TextProcessor.similarity(dict.text, cleaned)
                    let allowRewrite = ctx.category == .email || Settings.shared.cleanupLevel == .medium
                    if cleaned.isEmpty || (!allowRewrite && sim < 0.3) {
                        toPaste = TextProcessor.fitToContext(dict.text, before: ctx.textBefore, after: ctx.textAfter)
                        entry.errorMessage = cleaned.isEmpty ? "Empty cleanup result" : "Cleanup diverged too much (\(Int(sim*100))%)"
                    } else {
                        var finalText = cleaned
                        // Wispr "Auto Apply After Dictation": run the chosen transform before pasting; fall back on failure.
                        if let autoID = Settings.shared.autoApplyTransformID,
                           let t = Database.shared.transforms().first(where: { $0.id == autoID && $0.enabled }) {
                            if let out = try? await TransformController.shared.apply(t, to: cleaned, ctx: ctx), !out.isEmpty {
                                finalText = out
                                entry.instruction = "auto: \(t.name)"
                            }
                        }
                        entry.formattedText = finalText
                        toPaste = spacingOnly(finalText, before: ctx.textBefore, after: ctx.textAfter)
                        status = .formatted
                        entry.numWordsCorrected = max(0, TextProcessor.wordCount(dict.text) - TextProcessor.wordCount(cleaned))
                    }
                } catch {
                    entry.errorMessage = error.localizedDescription
                    toPaste = TextProcessor.fitToContext(dict.text, before: ctx.textBefore, after: ctx.textAfter)
                    Notifier.notify("Pasted raw transcript", error.localizedDescription)
                }
            }

        case .command:
            entry.instruction = asr
            do {
                let (action, text, usage, model) = try await command(instruction: dict.text, ctx: ctx)
                entry.model = model
                entry.inputTokens = usage.inputTokens; entry.outputTokens = usage.outputTokens
                entry.cacheReadTokens = usage.cacheReadTokens
                guard !text.isEmpty else {
                    entry.status = .failed
                    entry.errorMessage = "Nothing to apply"
                    save(entry)
                    finishUI(message: "Nothing to change", success: false)
                    return
                }
                entry.formattedText = text
                if !ctx.isEditable && !ctx.hasFocusedElement {
                    TextInserter.copyToClipboard(text)
                    entry.pastedText = text
                    entry.status = .formatted
                    save(entry)
                    lastPastedText = text
                    finishUI(message: "Result copied to clipboard", success: true)
                    return
                }
                if action == "replace_all" {
                    selectAllInField(ctx)
                    try? await Task.sleep(for: .milliseconds(60))
                }
                toPaste = text
                status = .formatted
            } catch {
                entry.status = .failed
                entry.errorMessage = error.localizedDescription
                save(entry)
                finishUI(message: error.localizedDescription, success: false)
                return
            }
        }

        entry.numWords = TextProcessor.wordCount(toPaste)
        TransformController.shared.noteDictation(toPaste)
        let pasted = TextInserter.paste(toPaste, context: ctx)
        entry.pastedText = toPaste
        entry.status = pasted ? status : .failed
        entry.e2eLatency = Date().timeIntervalSince(keyUpAt)
        lastPastedText = toPaste
        if !pasted {
            entry.errorMessage = "No text field focused; transcript left on clipboard"
            Notifier.notify("No text field focused", "Your transcript is on the clipboard. Press Cmd+Ctrl+V to paste it.")
        }
        save(entry)
        if pasted, mode != .command, let box = ctx.focusedElement {
            AutoLearn.schedule(AutoLearn.Watch(historyID: entry.id, element: box.element, pasted: toPaste,
                                               before: ctx.textBefore ?? "", after: ctx.textAfter ?? ""))
        }
        finishUI(message: nil, success: pasted)
    }

    /// Looks for the focused element again, a few times. Only a capture from the same app is used, so switching apps
    /// mid-dictation doesn't change the context the cleanup was meant for.
    private func refocus(_ ctx: InsertionContext, mode: DictationMode) async -> InsertionContext {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(80)) }
            let probe = ContextReader.capture(readText: false)
            guard probe.pid == ctx.pid else { return ctx }
            if probe.hasFocusedElement {
                Log.write("ax: found focused element on retry \(attempt + 1)")
                guard Settings.shared.contextAwareness || mode == .command else { return probe }
                let full = ContextReader.capture(readText: true)
                return full.hasFocusedElement ? full : probe
            }
        }
        return ctx
    }

    private func spacingOnly(_ text: String, before: String?, after: String?) -> String {
        var t = text
        if let last = before?.last, !last.isWhitespace, !"([\"'“‘/-".contains(last) { t = " " + t }
        if let next = after?.first, next.isLetter || next.isNumber { t += " " }
        return t
    }

    private func selectAllInField(_ ctx: InsertionContext) {
        if let box = ctx.focusedElement, let text = ctx.fieldText {
            var range = CFRange(location: 0, length: (text as NSString).length)
            if let v = AXValueCreate(.cfRange, &range),
               AXUIElementSetAttributeValue(box.element, kAXSelectedTextRangeAttribute as CFString, v) == .success {
                return
            }
        }
        TextInserter.selectAll()
    }

    private func finishUI(message: String?, success: Bool, silent: Bool = false) {
        if state == .recording { return }   // a newer recording took over; leave its UI alone
        state = .idle
        level = 0
        if silent { return }
        if let message {
            if success { FlowBarController.shared.flash(message: message) } else {
                FlowBarController.shared.flash(message: message, isError: true); Sounds.play(.error)
            }
        } else {
            FlowBarController.shared.flashDone()
        }
    }

    private func save(_ entry: HistoryEntry) {
        try? Database.shared.write { db in try entry.insert(db) }
    }

    // MARK: - Claude calls

    private func contextBlock(_ ctx: InsertionContext, dictionary: [DictionaryEntry]) -> String {
        let s = Settings.shared
        var lines: [String] = []
        lines.append("APP: \(ctx.appName ?? "unknown") (\(ctx.appBundleID ?? "?"))")
        if let u = ctx.url { lines.append("URL: \(u)") }
        if let t = ctx.windowTitle, !t.isEmpty { lines.append("WINDOW TITLE: \(t.prefix(120))") }
        lines.append("CATEGORY: \(ctx.category.rawValue)")
        lines.append("STYLE: \(s.style(for: ctx.category).rawValue)")
        lines.append("CLEANUP LEVEL: \(s.cleanupLevel.rawValue)")
        lines.append("USER NAME: \(s.userFirstName) \(s.userLastName)")
        lines.append("FIELD IS EMPTY: \(ctx.fieldIsEmpty)")
        if ctx.category == .email, s.emailSignatureEnabled, !s.emailSignature.isEmpty {
            lines.append("EMAIL SIGNATURE BLOCK:\n\(s.emailSignature)")
        }
        if let b = ctx.textBefore, !b.isEmpty { lines.append("TEXT BEFORE CURSOR (last 600 chars):\n\(b)") }
        if let a = ctx.textAfter, !a.isEmpty { lines.append("TEXT AFTER CURSOR:\n\(a)") }
        if let sel = ctx.selectedText, !sel.isEmpty { lines.append("SELECTED TEXT (will be replaced by the paste):\n\(sel.prefix(2000))") }
        if !ctx.screenNames.isEmpty { lines.append("NAMES VISIBLE ON SCREEN: " + ctx.screenNames.prefix(40).joined(separator: ", ")) }
        let words = dictionary.filter { !$0.isSnippet }.map { e in
            e.replacement.map { "\(e.phrase) → \($0)" } ?? e.phrase
        }
        if !words.isEmpty { lines.append("USER DICTIONARY: " + words.prefix(150).joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    private func cleanup(_ transcript: String, ctx: InsertionContext, dictionary: [DictionaryEntry]) async throws
        -> (String, ClaudeUsage, String) {
        let model = Settings.shared.cleanupModel
        let user = "<context>\n\(contextBlock(ctx, dictionary: dictionary))\n</context>\n\n<transcript>\n\(transcript)\n</transcript>"
        // Adaptive thinking at low effort measured faster and more robust than thinking-off on Haiku 5.5 (eval in .scratch).
        let req = ClaudeClient.Request(model: model,
                                       system: Prompts.cleanupSystem(level: Settings.shared.cleanupLevel),
                                       userContent: user,
                                       maxTokens: 8192, effort: "low", disableThinking: false,
                                       timeout: 20)
        let resp = try await ClaudeClient.shared.send(req, feature: "cleanup")
        var text = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") { // defensive: strip code fences
            text = text.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (text, resp.usage, model)
    }

    private func command(instruction: String, ctx: InsertionContext) async throws -> (String, String, ClaudeUsage, String) {
        let model = Settings.shared.commandModel
        var lines: [String] = []
        lines.append("APP: \(ctx.appName ?? "unknown"), CATEGORY: \(ctx.category.rawValue)")
        if let u = ctx.url { lines.append("URL: \(u)") }
        lines.append("USER NAME: \(Settings.shared.userFirstName) \(Settings.shared.userLastName)")
        lines.append("SELECTED TEXT:\n\(ctx.selectedText ?? "(none)")")
        lines.append("FULL FIELD CONTENTS:\n\(ctx.fieldText ?? "(empty)")")
        if !ctx.screenNames.isEmpty { lines.append("NAMES VISIBLE ON SCREEN: " + ctx.screenNames.prefix(30).joined(separator: ", ")) }
        let user = "<context>\n\(lines.joined(separator: "\n"))\n</context>\n\n<instruction>\n\(instruction)\n</instruction>"
        let req = ClaudeClient.Request(model: model, system: Prompts.commandSystem(), userContent: user,
                                       maxTokens: 8192, effort: "low", disableThinking: true,
                                       jsonSchema: Prompts.commandSchema, timeout: 30)
        let resp = try await ClaudeClient.shared.send(req, feature: "command")
        guard let data = resp.text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("insert", resp.text, resp.usage, model)
        }
        let action = obj["action"] as? String ?? "insert"
        let text = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (action, text, resp.usage, model)
    }
}

extension SpeechSession {
    func setUpdateHandler(_ h: @escaping @Sendable (String, String) -> Void) {
        onUpdate = h
    }
}
