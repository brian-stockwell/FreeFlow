import Foundation
import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// One recording: captures the mic with AVAudioEngine, writes a WAV file and streams converted buffers to a consumer.
///
/// Nothing here blocks the caller. macOS can hold AVAudioEngine calls for seconds, or forever, while it takes a Bluetooth
/// mic over from another device (AirPods in use on a phone), so every engine runs on its own queue and one that doesn't
/// produce audio is abandoned for a fresh one on the built-in mic.
final class AudioRecorder: @unchecked Sendable {
    /// How long an engine gets to produce audio before it counts as stuck.
    private static let noAudioTimeout: TimeInterval = 2.5
    /// Engines tried in a row with no audio before giving up (each device change starts a new one).
    private static let maxLaunchesWithoutAudio = 6

    /// One engine and the queue that owns it. Only `queue` touches `engine`.
    private final class Attempt {
        let queue = DispatchQueue(label: "freeflow.audio.engine", qos: .userInitiated)
        let isFallback: Bool
        var engine: AVAudioEngine?
        var observer: NSObjectProtocol?
        var heardAudio = false // guarded by `lock`
        init(isFallback: Bool) { self.isFallback = isFallback }
    }

    private let lock = NSLock()
    private var current: Attempt?
    private var stopped = false
    private var launchesWithoutAudio = 0
    private var firstAudioAt: Date?
    private var speechSeconds: Double = 0

    /// Held only by audio threads (and briefly to close the file), never by the caller of `stop()`.
    private let writeLock = NSLock()
    private var file: AVAudioFile?
    private var fileClosed = false
    private var converter: AVAudioConverter?

    private var targetFormat: AVAudioFormat?
    private var fileURL: URL?
    private var deviceUID: String?

    /// Called on the audio thread with buffers already converted to `targetFormat`.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the audio thread with a 0...1 level for the waveform UI.
    var onLevel: ((Float) -> Void)?
    /// Called on a background queue when no microphone could be made to work.
    var onFailure: ((String) -> Void)?

    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        var result: [AudioInputDevice] = []
        for id in ids {
            var inAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                    mScope: kAudioObjectPropertyScopeInput,
                                                    mElement: kAudioObjectPropertyElementMain)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &cfgSize) == noErr, cfgSize > 0 else { continue }
            let bufList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(cfgSize))
            defer { bufList.deallocate() }
            guard AudioObjectGetPropertyData(id, &inAddr, 0, nil, &cfgSize, bufList) == noErr else { continue }
            let channels = UnsafeMutableAudioBufferListPointer(bufList).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { continue }
            guard let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { continue }
            result.append(AudioInputDevice(id: id, uid: uid, name: name))
        }
        return result
    }

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }

    static func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// The Mac's own microphone, which doesn't depend on anything else being connected.
    private static func builtInInputUID() -> String? {
        inputDevices().first { device in
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &transport) == noErr
                && transport == kAudioDeviceTransportTypeBuiltIn
        }?.uid
    }

    private func selectDevice(uid: String?, on engine: AVAudioEngine) {
        guard let uid, let dev = AudioRecorder.inputDevices().first(where: { $0.uid == uid }),
              let unit = engine.inputNode.audioUnit else { return }
        var devID = dev.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Starts capture and returns immediately. `targetFormat` is what the speech engine wants (16 kHz mono, typically).
    /// Does nothing if `stop()` already ran. Problems arrive through `onFailure`.
    func start(targetFormat: AVAudioFormat, fileURL: URL?, deviceUID: String?) {
        self.targetFormat = targetFormat
        self.fileURL = fileURL
        self.deviceUID = deviceUID
        launch(isFallback: false)
    }

    /// Replaces the current engine with a new one.
    private func launch(isFallback: Bool) {
        let attempt = Attempt(isFallback: isFallback)
        var previous: Attempt?
        var gaveUp = false
        lock.withLock {
            guard !stopped else { return }
            launchesWithoutAudio += 1
            if launchesWithoutAudio > Self.maxLaunchesWithoutAudio { gaveUp = true; return }
            previous = current
            current = attempt
        }
        if gaveUp { fail("The microphone isn't responding."); return }
        guard isCurrent(attempt) else { return }
        if let previous { retire(previous) }
        let launchedAt = Date()
        attempt.queue.async { [self] in
            guard isCurrent(attempt) else { return }
            do {
                let uid = isFallback ? Self.builtInInputUID() : deviceUID
                let engine = AVAudioEngine()
                attempt.engine = engine
                selectDevice(uid: uid, on: engine)
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw NSError(domain: "FreeFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
                }
                // A nil tap format follows the hardware; a stale explicit one raises an uncatchable exception if the device just changed.
                input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self, weak attempt] buffer, _ in
                    guard let self, let attempt else { return }
                    self.process(buffer, from: attempt)
                }
                attempt.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                          object: engine, queue: nil) { [weak self, weak attempt] _ in
                    guard let self, let attempt else { return }
                    attempt.queue.async {
                        guard self.isCurrent(attempt), let engine = attempt.engine else { return }
                        // Starting on a specific device posts this too, with the engine still running as it was.
                        if engine.isRunning, engine.inputNode.outputFormat(forBus: 0) == format { return }
                        // The mic really changed (AirPods arrived or left) and the engine has stopped: follow it.
                        Log.write("mic: device changed, restarting capture")
                        self.launch(isFallback: attempt.isFallback)
                    }
                }
                engine.prepare()
                try engine.start()
                Log.write(String(format: "mic: engine started in %.2fs%@", Date().timeIntervalSince(launchedAt), isFallback ? " (built-in fallback)" : ""))
            } catch {
                Log.write("mic: engine failed: \(error.localizedDescription)")
                guard isCurrent(attempt) else { return }
                if isFallback { fail(error.localizedDescription) } else { launch(isFallback: true) }
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.noAudioTimeout) { [weak self] in
            self?.checkForAudio(attempt)
        }
    }

    private func isCurrent(_ attempt: Attempt) -> Bool {
        lock.withLock { !stopped && current === attempt }
    }

    private func checkForAudio(_ attempt: Attempt) {
        let stuck = lock.withLock { !stopped && current === attempt && !attempt.heardAudio }
        guard stuck else { return }
        if attempt.isFallback {
            fail("The microphone isn't responding.")
        } else {
            Log.write("mic: no audio after \(Self.noAudioTimeout)s, switching to the built-in mic")
            launch(isFallback: true)
        }
    }

    private func fail(_ message: String) {
        guard !lock.withLock({ stopped }) else { return }
        Log.write("mic: giving up: \(message)")
        onFailure?(message)
    }

    /// Shuts an engine down on its own queue. If that queue is stuck, this simply runs whenever it comes back.
    private func retire(_ attempt: Attempt) {
        attempt.queue.async {
            if let observer = attempt.observer { NotificationCenter.default.removeObserver(observer) }
            attempt.observer = nil
            guard let engine = attempt.engine else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            attempt.engine = nil
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, from attempt: Attempt) {
        // Level metering
        var level: Float = 0
        var rms: Float = 0
        if let data = buffer.floatChannelData, buffer.frameLength > 0 {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            let ch = data[0]
            for i in 0..<n { sum += ch[i] * ch[i] }
            rms = sqrt(sum / Float(n))
            level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50)) // -50 dB..0 dB → 0..1
        }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let live: Bool = lock.withLock {
            guard !stopped, current === attempt else { return false }
            // Exact digital silence is a device that's connected but not delivering yet; real mics always have a noise floor.
            if rms > 0 {
                attempt.heardAudio = true
                launchesWithoutAudio = 0
                if firstAudioAt == nil { firstAudioAt = Date() }
            }
            if rms > 0.01 { speechSeconds += seconds }
            return true
        }
        guard live else { return }
        onLevel?(level)
        guard let targetFormat else { return }
        let converted: AVAudioPCMBuffer? = writeLock.withLock {
            guard !fileClosed else { return nil }
            // Each device can have its own format, so the converter follows the buffers.
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: targetFormat) }
            guard let converter else { return nil }
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return nil }
            // The file uses the target format so one recording can span devices with different formats.
            if file == nil, let fileURL {
                file = try? AVAudioFile(forWriting: fileURL, settings: targetFormat.settings,
                                        commonFormat: targetFormat.commonFormat, interleaved: targetFormat.isInterleaved)
            }
            try? file?.write(from: out)
            return out
        }
        if let converted { onBuffer?(converted) }
    }

    /// Stops capture without waiting for the audio system; returns (seconds since audio first arrived, seconds with
    /// speech energy). A duration of 0 means the mic never delivered anything.
    @discardableResult
    func stop() -> (duration: Double, speech: Double) {
        var attempt: Attempt?
        var firstAudio: Date?
        var speech: Double = 0
        let alreadyStopped: Bool = lock.withLock {
            if stopped { return true }
            stopped = true
            attempt = current
            current = nil
            firstAudio = firstAudioAt
            speech = speechSeconds
            return false
        }
        if alreadyStopped { return (0, 0) }
        if let attempt { retire(attempt) }
        DispatchQueue.global(qos: .utility).async { [self] in
            writeLock.withLock { fileClosed = true; file = nil }
        }
        return (firstAudio.map { Date().timeIntervalSince($0) } ?? 0, speech)
    }
}
