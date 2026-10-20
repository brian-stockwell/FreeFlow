import Foundation
import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Captures microphone audio with AVAudioEngine, writes a WAV file and streams converted buffers to a consumer.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private var speechFrames: Double = 0
    private var totalFrames: Double = 0

    /// Called on the audio thread with buffers already converted to `targetFormat`.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the audio thread with a 0...1 level for the waveform UI.
    var onLevel: ((Float) -> Void)?

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

    private func selectDevice(uid: String?) {
        guard let uid, let dev = AudioRecorder.inputDevices().first(where: { $0.uid == uid }),
              let unit = engine.inputNode.audioUnit else { return }
        var devID = dev.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Starts capture. `targetFormat` is what the speech engine wants (16 kHz mono float, typically).
    func start(targetFormat: AVAudioFormat, fileURL: URL?, deviceUID: String?) throws {
        if isRunning { return }
        selectDevice(uid: deviceUID)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "FreeFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        self.targetFormat = targetFormat
        converter = AVAudioConverter(from: inFormat, to: targetFormat)
        if let url = fileURL {
            file = try AVAudioFile(forWriting: url, settings: inFormat.settings)
        }
        speechFrames = 0; totalFrames = 0
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        startedAt = Date()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        try? file?.write(from: buffer)
        // Level metering
        if let data = buffer.floatChannelData, buffer.frameLength > 0 {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            let ch = data[0]
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(n))
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50)) // -50 dB..0 dB → 0..1
            totalFrames += Double(n)
            if rms > 0.01 { speechFrames += Double(n) }
            onLevel?(level)
        }
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { onBuffer?(out) }
    }

    /// Stops capture; returns (total seconds, seconds with speech energy).
    @discardableResult
    func stop() -> (duration: Double, speech: Double) {
        guard isRunning else { return (0, 0) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        let rate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        file = nil
        let dur = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let speech = rate > 0 ? speechFrames / rate : 0
        return (dur, speech)
    }
}
