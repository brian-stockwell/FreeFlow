import Foundation
import AVFoundation
import Speech

/// Wraps Apple's on-device SpeechAnalyzer (macOS 26). One `SpeechSession` per recording.
enum SpeechEngine {
    static func locale() -> Locale { Locale(identifier: Settings.shared.languageIdentifier) }

    /// Makes sure the on-device model for the selected language is downloaded. Reports progress 0...1.
    static func ensureAssets(progress: ((Double) -> Void)? = nil) async throws -> Bool {
        let transcriber = SpeechTranscriber(locale: locale(), preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported { return false }
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let p = request.progress
                let watcher = Task {
                    while !Task.isCancelled {
                        progress?(p.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
                defer { watcher.cancel() }
                try await request.downloadAndInstall()
            }
        }
        _ = try? await AssetInventory.reserve(locale: locale())
        progress?(1)
        return true
    }

    static func assetStatus() async -> AssetInventory.Status {
        let transcriber = SpeechTranscriber(locale: locale(), preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [transcriber])
    }

    /// Loads the model into memory so the first dictation is fast.
    static func warmUp() async {
        let session = SpeechSession(contextualStrings: [], timeIndexed: false)
        try? await session.prepare()
        await session.cancel()
    }
}

/// A single live transcription. Feed PCM buffers, then `finish()` for the final text.
actor SpeechSession {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var inputStream: AsyncStream<AnalyzerInput>?
    private var resultsTask: Task<Void, Never>?
    private(set) var finalizedText = ""
    private(set) var volatileText = ""
    private(set) var segments: [(text: String, startMs: Int, endMs: Int)] = []
    nonisolated let audioFormat: AVAudioFormat?
    /// Called (on the main thread) whenever the live text changes.
    var onUpdate: (@Sendable (String, String) -> Void)?
    private var started = false

    init(contextualStrings: [String], timeIndexed: Bool) {
        let attrs: Set<SpeechTranscriber.ResultAttributeOption> = timeIndexed ? [.audioTimeRange] : []
        transcriber = SpeechTranscriber(locale: SpeechEngine.locale(),
                                        transcriptionOptions: [],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: attrs)
        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings = [.general: Array(contextualStrings.prefix(300))]
        }
        self.context = context
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        inputStream = stream
        continuation = cont
        analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        audioFormat = nil
    }
    private let context: AnalysisContext

    /// Best audio format for feeding this session. Call before `start`.
    func bestFormat() async -> AVAudioFormat {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    func prepare() async throws {
        let f = await bestFormat()
        try await analyzer.prepareToAnalyze(in: f)
    }

    func start() async throws {
        guard !started else { return }
        started = true
        let f = await bestFormat()
        try? await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: f)
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    await self.consume(result)
                }
            } catch {
                // stream ended or cancelled
            }
        }
        // The analyzer was constructed with the input sequence; analysis begins as soon as audio arrives.
        try await analyzer.start(inputSequence: inputStream!)
    }

    private func consume(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                finalizedText = join(finalizedText, text)
                let start = Int(result.range.start.seconds * 1000)
                let end = Int(result.range.end.seconds * 1000)
                segments.append((text.trimmingCharacters(in: .whitespaces), start, end))
            }
            volatileText = ""
        } else {
            volatileText = text
        }
        let f = finalizedText, v = volatileText
        if let cb = onUpdate { DispatchQueue.main.async { cb(f, v) } }
    }

    private func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b.trimmingCharacters(in: .whitespaces) }
        let bt = b.trimmingCharacters(in: .whitespaces)
        if bt.isEmpty { return a }
        if a.hasSuffix(" ") || b.hasPrefix(" ") { return a + " " + bt }
        return a + " " + bt
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        Task { await self.yield(buffer) }
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends input and waits for the final transcript.
    func finish() async -> String {
        continuation?.finish()
        continuation = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
        if !volatileText.isEmpty { // anything not finalized still counts
            finalizedText = join(finalizedText, volatileText)
            volatileText = ""
        }
        return finalizedText
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    var liveText: String { join(finalizedText, volatileText) }
}
