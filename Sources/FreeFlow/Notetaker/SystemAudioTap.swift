import Foundation
import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (the other side of a call) via a CoreAudio process tap (macOS 14.2+).
/// Needs the "System Audio Recording Only" permission (NSAudioCaptureUsageDescription).
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "freeflow.systemtap")
    private(set) var isRunning = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    enum TapError: LocalizedError {
        case create(OSStatus), aggregate(OSStatus), format, start(OSStatus), noOutputDevice
        var errorDescription: String? {
            switch self {
            case .create(let s): return "Could not create system audio tap (\(s)). Grant System Audio Recording permission."
            case .aggregate(let s): return "Could not create aggregate audio device (\(s))."
            case .format: return "Could not read system audio format."
            case .start(let s): return "Could not start system audio capture (\(s))."
            case .noOutputDevice: return "No default output device."
            }
        }
    }

    func start(targetFormat: AVAudioFormat, fileURL: URL?) throws {
        guard !isRunning else { return }
        self.targetFormat = targetFormat

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "FreeFlow Meeting Tap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != kAudioObjectUnknown else { throw TapError.create(st) }
        tapID = tap

        // Tap stream format
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd) == noErr,
              let fmt = AVAudioFormat(streamDescription: &asbd) else {
            teardown(); throw TapError.format
        }
        tapFormat = fmt
        converter = AVAudioConverter(from: fmt, to: targetFormat)
        if let url = fileURL {
            // The tap delivers interleaved stereo; AVAudioFile defaults to non-interleaved and would reject every write.
            file = try? AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        }

        guard let outputUID = AudioRecorder.defaultOutputDeviceUID() else { teardown(); throw TapError.noOutputDevice }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FreeFlow Meeting Capture",
            kAudioAggregateDeviceUIDKey: "com.brianstockwell.freeflow.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let ast = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard ast == noErr else { teardown(); throw TapError.aggregate(ast) }
        aggregateID = agg

        let pst = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard pst == noErr, let proc = ioProcID else { teardown(); throw TapError.start(pst) }
        let sst = AudioDeviceStart(aggregateID, proc)
        guard sst == noErr else { teardown(); throw TapError.start(sst) }
        isRunning = true
    }

    private func handle(_ list: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let targetFormat, let converter else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first, first.mDataByteSize > 0 else { return }
        let bytesPerFrame = Int(tapFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        // Copy channel data
        let dst = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for (i, src) in abl.enumerated() where i < dst.count {
            if let s = src.mData, let d = dst[i].mData {
                memcpy(d, s, Int(min(src.mDataByteSize, dst[i].mDataByteSize)))
            }
        }
        try? file?.write(from: pcm)
        if let ch = pcm.floatChannelData, pcm.frameLength > 0 {
            var sum: Float = 0
            let n = Int(pcm.frameLength)
            for i in 0..<n { sum += ch[0][i] * ch[0][i] }
            let rms = sqrt(sum / Float(n))
            onLevel?(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50)))
        }
        let ratio = targetFormat.sampleRate / tapFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 32) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return pcm
        }
        if err == nil, out.frameLength > 0 { onBuffer?(out) }
    }

    func stop() {
        guard isRunning else { teardown(); return }
        isRunning = false
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        file = nil
    }
}
