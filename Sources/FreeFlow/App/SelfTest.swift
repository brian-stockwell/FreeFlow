import Foundation
import AVFoundation

/// Developer self-tests: `FreeFlow --test-speech file.wav`, `FreeFlow --test-claude "text"`, `FreeFlow --test-context`.
enum SelfTest {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 2, args[1].hasPrefix("--test-") else { return false }
        let sem = DispatchSemaphore(value: 0)
        setvbuf(stdout, nil, _IONBF, 0)
        Task.detached {
            switch args[1] {
            case "--test-speech":
                await testSpeech(path: args.count > 2 ? args[2] : "")
            case "--test-claude":
                await testClaude(text: args.count > 2 ? args[2] : "um so I I think we should uh meet at two actually three tomorrow and bring the the report")
            case "--test-cleanup":
                await testCleanup(path: args.count > 2 ? args[2] : "", thinking: args.count > 3 ? args[3] : "off",
                                  effort: args.count > 4 ? args[4] : "low", style: args.count > 5 ? args[5] : "casual")
            case "--test-command":
                await testCommand(instruction: args.count > 2 ? args[2] : "make this into an email",
                                  selected: args.count > 3 ? args[3] : "So you did it all during a class period as well? It was really cool.",
                                  model: args.count > 4 ? args[4] : Settings.shared.commandModel)
            case "--test-transform":
                let key = args.count > 2 ? args[2] : "polish"
                let text = args.count > 3 ? args[3] : "so basically what i'm thinking is we should probably just like go ahead and build the thing and see what happens, and then if it doesn't work we can always, you know, go back and change it, i mean it's not like we have a ton of time anyway so"
                guard let t = Database.shared.transforms().first(where: { $0.builtInKey == key || $0.name.lowercased() == key.lowercased() }) else { print("no transform", key); break }
                let t0 = Date()
                do {
                    let out = try await TransformController.applyTransform(t, to: text, ctx: nil)
                    print("TRANSFORM \(t.name) (\(String(format: "%.2f", Date().timeIntervalSince(t0)))s)\nIN:  \(text)\nOUT: \(out)")
                } catch { print("ERROR:", error) }
            case "--test-import":
                print("available:", WisprImport.isAvailable)
                let r = WisprImport.run()
                print(r)
                print("dictionary now:", Database.shared.activeDictionary().map { "\($0.phrase)\($0.replacement.map { " → " + $0 } ?? "")" })
            case "--test-context":
                // Main thread is blocked by the semaphore; AX calls are fine from this thread.
                let ctx = ContextReader.capture(readText: true)
                print("app:", ctx.appName ?? "?", "(\(ctx.appBundleID ?? "?"))")
                print("url:", ctx.url ?? "-")
                print("title:", ctx.windowTitle ?? "-")
                print("category:", ctx.category.rawValue, " style:", Settings.shared.style(for: ctx.category).rawValue)
                print("focused:", ctx.hasFocusedElement, " role:", ctx.elementRole ?? "-", " editable:", ctx.isEditable, " secure:", ctx.isSecureField)
                print("field empty:", ctx.fieldIsEmpty, " selection:", ctx.selectionRange.map { "\($0)" } ?? "-")
                print("textBefore(tail):", (ctx.textBefore ?? "").suffix(100).replacingOccurrences(of: "\n", with: "⏎"))
                print("textAfter(head):", (ctx.textAfter ?? "").prefix(60).replacingOccurrences(of: "\n", with: "⏎"))
                print("screenNames:", ctx.screenNames.prefix(25))
            default:
                print("unknown test")
            }
            sem.signal()
        }
        sem.wait()
        return true
    }

    static func testSpeech(path: String) async {
        do {
            print("asset status:", await SpeechEngine.assetStatus())
            let ok = try await SpeechEngine.ensureAssets { p in print(String(format: "download %.0f%%", p * 100)) }
            print("assets ready:", ok)
            let session = SpeechSession(contextualStrings: ["Wispr", "Alex Rivera"], timeIndexed: true)
            let format = await session.bestFormat()
            print("format:", format)
            let t0 = Date()
            try await session.start()
            print("started in", Date().timeIntervalSince(t0))
            print("step: open file")
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            print("file format:", file.processingFormat, "frames:", file.length)
            let conv = AVAudioConverter(from: file.processingFormat, to: format)!
            print("step: converter ok")
            while true {
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { break }
                if file.framePosition >= file.length { break }
                do { try file.read(into: inBuf) } catch { break }
                if inBuf.frameLength == 0 { break }
                let ratio = format.sampleRate / file.processingFormat.sampleRate
                let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 32)!
                var consumed = false
                conv.convert(to: out, error: nil) { _, st in
                    if consumed { st.pointee = .noDataNow; return nil }
                    consumed = true; st.pointee = .haveData; return inBuf
                }
                session.feed(out)
            }
            print("step: fed all audio")
            let t1 = Date()
            let text = await session.finish()
            print("TRANSCRIPT (\(String(format: "%.2f", Date().timeIntervalSince(t1)))s finalize):", text)
            print("segments:", await session.segments)
        } catch { print("ERROR:", error) }
    }

    /// Runs every case in a JSON file through the cleanup prompt and prints output vs expected, latency and similarity.
    static func testCleanup(path: String, thinking: String, effort: String, style: String) async {
        guard let data = FileManager.default.contents(atPath: path),
              let cases = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { print("bad cases file"); return }
        print("config: thinking=\(thinking) effort=\(effort) model=\(Settings.shared.cleanupModel)")
        var totalSim = 0.0, totalLat = 0.0, cost = 0.0
        // Your own dictionary, so eval cases with names and product terms behave like real dictations.
        let dictionary = Database.shared.activeDictionary().filter { !$0.isSnippet }.map { $0.phrase }.joined(separator: "; ")
        for (i, c) in cases.enumerated() {
            let raw = c["raw"] ?? "", expect = c["expect"] ?? ""
            let user = "<context>\nAPP: Claude (com.anthropic.claudefordesktop)\nCATEGORY: ai\nSTYLE: \(style)\nCLEANUP LEVEL: light\nUSER NAME: \(Settings.shared.userFirstName) \(Settings.shared.userLastName)\nFIELD IS EMPTY: true\nUSER DICTIONARY: \(dictionary)\n</context>\n\n<transcript>\n\(raw)\n</transcript>"
            let t0 = Date()
            do {
                let r = try await ClaudeClient.shared.send(.init(model: Settings.shared.cleanupModel,
                    system: Prompts.cleanupSystem(level: .light), userContent: user, maxTokens: 2048, effort: effort,
                    disableThinking: thinking == "off", timeout: 60), feature: "evaltest")
                let lat = Date().timeIntervalSince(t0)
                let sim = TextProcessor.similarity(expect, r.text)
                totalSim += sim; totalLat += lat
                cost += ClaudePricing.cost(model: Settings.shared.cleanupModel, usage: r.usage)
                print("\n#\(i) sim=\(String(format: "%.2f", sim)) \(String(format: "%.2f", lat))s  (in \(r.usage.inputTokens) cached \(r.usage.cacheReadTokens) out \(r.usage.outputTokens))")
                print("RAW:    \(raw)")
                print("EXPECT: \(expect)")
                print("GOT:    \(r.text)")
            } catch { print("#\(i) ERROR: \(error)") }
        }
        print(String(format: "\nAVG similarity %.3f  avg latency %.2fs  total cost $%.5f", totalSim / Double(cases.count), totalLat / Double(cases.count), cost))
    }

    static func testClaude(text: String) async {
        print("key present:", Settings.shared.hasAPIKey)
        var ctx = InsertionContext()
        ctx.appName = "Mail"; ctx.appBundleID = "com.apple.mail"; ctx.category = .email; ctx.hasFocusedElement = true
        ctx.screenNames = ["Jordan Lee"]
        let dictionary = Database.shared.activeDictionary()
        let t0 = Date()
        let user = "<context>\nAPP: Mail\nCATEGORY: email\nSTYLE: formal\nCLEANUP LEVEL: light\nUSER NAME: \(Settings.shared.userFirstName) \(Settings.shared.userLastName)\nFIELD IS EMPTY: true\nNAMES VISIBLE ON SCREEN: Jordan Lee\nUSER DICTIONARY: \(dictionary.map { $0.phrase }.joined(separator: "; "))\n</context>\n\n<transcript>\n\(text)\n</transcript>"
        do {
            let r = try await ClaudeClient.shared.send(.init(model: Settings.shared.cleanupModel,
                system: Prompts.cleanupSystem(level: .light), userContent: user, maxTokens: 2048, effort: "low", disableThinking: true, timeout: 30), feature: "test")
            print("latency: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s  usage: \(r.usage)  cost: $\(ClaudePricing.cost(model: Settings.shared.cleanupModel, usage: r.usage))")
            print("OUTPUT:\n\(r.text)")
        } catch { print("ERROR:", error) }
    }

    /// Same request shape as Command Mode (structured output, thinking off) against the configured command model.
    static func testCommand(instruction: String, selected: String, model: String) async {
        let user = "<context>\nAPP: Claude, CATEGORY: ai\nUSER NAME: \(Settings.shared.userFirstName) \(Settings.shared.userLastName)\nSELECTED TEXT:\n\(selected)\nFULL FIELD CONTENTS:\n\(selected)\n</context>\n\n<instruction>\n\(instruction)\n</instruction>"
        let t0 = Date()
        do {
            let r = try await ClaudeClient.shared.send(.init(model: model, system: Prompts.commandSystem(), userContent: user,
                maxTokens: 8192, effort: "low", disableThinking: true, jsonSchema: Prompts.commandSchema, timeout: 30), feature: "test")
            print("model: \(model)  latency: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s  cost: $\(ClaudePricing.cost(model: model, usage: r.usage))")
            print("OUTPUT:\n\(r.text)")
        } catch { print("ERROR:", error) }
    }
}
