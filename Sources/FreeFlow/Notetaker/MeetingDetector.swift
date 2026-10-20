import Foundation
import AppKit
import CoreAudio
import Observation

/// Detects a call in progress (mic in use by another app + a meeting app/site visible) and offers to record it.
@MainActor
@Observable
final class MeetingDetector {
    static let shared = MeetingDetector()

    /// Non-nil while an offer is showing on the pill ("Record Zoom meeting?").
    private(set) var offerPlatform: String?
    private var timer: Timer?
    private var micBusySince: Date?
    private var offeredForThisCall = false
    private var dismissWork: DispatchWorkItem?

    private init() {}

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard Settings.shared.autoDetectMeetings else { return }
        let recorder = MeetingRecorder.shared
        if recorder.isRecording || DictationController.shared.state != .idle { micBusySince = nil; return }

        let busy = MeetingDetector.isMicInUse()
        if !busy {
            micBusySince = nil
            offeredForThisCall = false
            if offerPlatform != nil { clearOffer() }
            return
        }
        if micBusySince == nil { micBusySince = Date() }
        guard !offeredForThisCall, let since = micBusySince, Date().timeIntervalSince(since) >= 4 else { return }
        guard let platform = MeetingDetector.visibleMeetingPlatform() else { return }
        offeredForThisCall = true
        if Settings.shared.autoStartMeetings {
            Log.write("meeting auto-start on \(platform)")
            recorder.start()
        } else {
            offer(platform)
        }
    }

    private func offer(_ platform: String) {
        offerPlatform = platform
        Sounds.play(.ready)
        Notifier.notify("Meeting detected on \(MeetingDetector.displayName(platform))",
                        "Press Option+N or use the bar to start recording.")
        FlowBarController.shared.show()
        dismissWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.clearOffer() }
        dismissWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: w)
    }

    func acceptOffer() {
        clearOffer()
        MeetingRecorder.shared.start()
    }

    func clearOffer() {
        dismissWork?.cancel()
        offerPlatform = nil
    }

    static func displayName(_ platform: String) -> String {
        switch platform {
        case "zoom": return "Zoom"
        case "teams": return "Teams"
        case "meet": return "Google Meet"
        case "webex": return "Webex"
        case "facetime": return "FaceTime"
        case "slack": return "Slack"
        case "discord": return "Discord"
        default: return platform.capitalized
        }
    }

    // MARK: - Signals

    /// True when any process has the default input device running (our own dictation excluded by the caller).
    static func isMicInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return false }
        var running: UInt32 = 0
        var rSize = UInt32(MemoryLayout<UInt32>.size)
        var rAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &rAddr, 0, nil, &rSize, &running) == noErr else { return false }
        return running != 0
    }

    /// Which meeting platform looks active: Zoom's in-meeting helper, Teams/Webex/FaceTime running, or a Meet/Teams tab.
    static func visibleMeetingPlatform() -> String? {
        let apps = NSWorkspace.shared.runningApplications
        let ids = Set(apps.compactMap { $0.bundleIdentifier?.lowercased() })
        if ids.contains(where: { $0.contains("us.zoom.cpthost") }) { return "zoom" }          // Zoom spawns CptHost only in a meeting
        if ids.contains(where: { $0.contains("com.microsoft.teams") }) && teamsHasCallWindow(apps) { return "teams" }
        if ids.contains(where: { $0.contains("webex") }) { return "webex" }
        if ids.contains("com.apple.facetime") { return "facetime" }
        // Browser tabs: look at window titles of running browsers.
        for app in apps where ContextReader.browserBundleIDs.contains(app.bundleIdentifier ?? "") {
            for title in windowTitles(pid: app.processIdentifier) {
                let t = title.lowercased()
                if t.hasPrefix("meet - ") || t.contains("google meet") { return "meet" }
                if t.contains("microsoft teams") && (t.contains("meeting") || t.contains("call")) { return "teams" }
                if t.contains("zoom meeting") { return "zoom" }
                if t.contains("huddle") && t.contains("slack") { return "slack" }
            }
        }
        if ids.contains("com.hnc.discord") && windowTitles(bundle: "com.hnc.discord", apps: apps).contains(where: { $0.lowercased().contains("voice") }) { return "discord" }
        if ids.contains("com.tinyspeck.slackmacgap") && windowTitles(bundle: "com.tinyspeck.slackmacgap", apps: apps).contains(where: { $0.lowercased().contains("huddle") }) { return "slack" }
        return nil
    }

    private static func teamsHasCallWindow(_ apps: [NSRunningApplication]) -> Bool {
        windowTitles(bundle: "com.microsoft.teams", apps: apps).contains { t in
            let l = t.lowercased()
            return l.contains("meeting") || l.contains("call") || l.contains("| microsoft teams") && l.contains("(")
        } || true // Teams exposes few titles; mic-in-use + Teams running is good enough
    }

    private static func windowTitles(bundle prefix: String, apps: [NSRunningApplication]) -> [String] {
        apps.filter { ($0.bundleIdentifier ?? "").lowercased().hasPrefix(prefix) }.flatMap { windowTitles(pid: $0.processIdentifier) }
    }

    private static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows.prefix(12).compactMap { ContextReader.stringAttr($0, kAXTitleAttribute) }
    }
}
