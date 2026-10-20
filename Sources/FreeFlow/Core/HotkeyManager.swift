import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Low-level key events the dictation controller cares about.
enum HotkeyEvent: Sendable {
    case fnDown(ctrlHeld: Bool, optionHeld: Bool)
    case fnUp
    case ctrlDown          // while Fn is held
    case optionDown        // while Fn is held
    case spaceWhileFn      // Fn+Space
    case escape
    case pasteLast         // Cmd+Ctrl+V
    case copyLast          // Cmd+Ctrl+C
    case startMeeting      // Option+N
    case meetingControlTap // Control tapped on its own while a meeting records (Meeting ↔ Lecture)
    case otherKeyDown      // any other key while recording (informational)
    case transform(String) // a Transform hotkey (id)
}

/// Global CGEventTap-based hotkey listener. Needs Accessibility permission.
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Identifies synthetic events we post ourselves (paste) so the tap ignores them.
    static let syntheticMarker: Int64 = 0x46_4C_4F_57 // "FLOW"

    var handler: ((HotkeyEvent) -> Void)?
    /// Set by the controller: when true, Fn/Esc/Space events are swallowed so other apps never see them.
    var isCapturing = false
    /// Set by MeetingRecorder: while true, a lone Control tap emits `.meetingControlTap`.
    var isRecordingMeeting = false
    var swallowFn = true
    /// Registered Transform hotkeys (set by TransformController.reloadShortcuts).
    var transformShortcuts: [(flags: CGEventFlags, keyCode: Int, id: String)] = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var fnDown = false
    private(set) var isRunning = false
    private var lastFnUpAt: CFAbsoluteTime = 0
    /// A Control press that may become a lone tap: when it went down, and the mouse event count at that moment.
    private var controlTap: (at: CFAbsoluteTime, mouseEvents: UInt32)?
    private(set) var tapLocation: CGEventTapLocation = .cgSessionEventTap

    private init() {}

    func start() -> Bool {
        if isRunning { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }
        // HID-level first: swallowing Fn there happens before the system decides to show the emoji picker.
        // Session-level taps see the event too late for that. Fall back if the HID tap is refused.
        var created: CFMachPort? = nil
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            if let t = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                created = t
                tapLocation = location
                Log.write("hotkeys: event tap installed at \(location == .cghidEventTap ? "HID" : "session") level")
                break
            }
        }
        guard let tap = created else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil; runLoopSource = nil; isRunning = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == HotkeyManager.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        switch type {
        case .flagsChanged:
            trackControlTap(keyCode: keyCode, flags: flags)
            if keyCode == kVK_Function || keyCode == 63 {
                let nowDown = flags.contains(.maskSecondaryFn)
                if nowDown && !fnDown {
                    fnDown = true
                    emit(.fnDown(ctrlHeld: flags.contains(.maskControl), optionHeld: flags.contains(.maskAlternate)))
                } else if !nowDown && fnDown {
                    fnDown = false
                    lastFnUpAt = CFAbsoluteTimeGetCurrent()
                    emit(.fnUp)
                }
                // Swallow Fn so the system emoji picker / dictation never fires.
                return swallowFn ? nil : Unmanaged.passUnretained(event)
            }
            // While a dictation is running (held or hands-free), tapping Control switches to cleanup mode and
            // tapping Option switches to Command Mode.
            if fnDown || isCapturing {
                if (keyCode == kVK_Control || keyCode == kVK_RightControl) && flags.contains(.maskControl) { emit(.ctrlDown) }
                if (keyCode == kVK_Option || keyCode == kVK_RightOption) && flags.contains(.maskAlternate) { emit(.optionDown) }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            controlTap = nil // Control+key is a shortcut, not a tap
            // When Fn is tapped alone, macOS immediately posts a synthetic key event that opens the emoji picker.
            // Swallow anything that lands within 40 ms of an Fn release (nobody types that fast after releasing Fn).
            // 179 = the Globe key event macOS synthesizes when Fn is tapped alone (opens the emoji picker).
            if keyCode == kVK_Function || keyCode == 63 || keyCode == 179 { return swallowFn ? nil : Unmanaged.passUnretained(event) }
            if swallowFn && CFAbsoluteTimeGetCurrent() - lastFnUpAt < 0.04 {
                Log.write("swallowed post-Fn keyDown: keyCode=\(keyCode) flags=\(flags.rawValue)")
                return nil
            }
            let cmd = flags.contains(.maskCommand), ctrl = flags.contains(.maskControl), opt = flags.contains(.maskAlternate)
            if fnDown && keyCode == kVK_Space {
                emit(.spaceWhileFn)
                return nil
            }
            if keyCode == kVK_Escape && isCapturing {
                emit(.escape)
                return nil
            }
            // Transform hotkeys (exact modifier match on cmd/ctrl/opt/shift).
            if !transformShortcuts.isEmpty && !isCapturing {
                let mods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                let pressed = flags.intersection(mods)
                if let hit = transformShortcuts.first(where: { $0.keyCode == keyCode && pressed == $0.flags.intersection(mods) }) {
                    emit(.transform(hit.id)); return nil
                }
            }
            if cmd && ctrl && !opt && keyCode == kVK_ANSI_V { emit(.pasteLast); return nil }
            if cmd && ctrl && !opt && keyCode == kVK_ANSI_C { emit(.copyLast); return nil }
            if opt && !cmd && !ctrl && keyCode == kVK_ANSI_N { emit(.startMeeting); return nil }
            if isCapturing && !fnDown { Log.write("other keyDown: keyCode=\(keyCode) flags=\(flags.rawValue)"); emit(.otherKeyDown) }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            if keyCode == kVK_Function || keyCode == 63 || keyCode == 179 { return swallowFn ? nil : Unmanaged.passUnretained(event) }
            if swallowFn && CFAbsoluteTimeGetCurrent() - lastFnUpAt < 0.08 && keyCode >= 128 { return nil }
            if fnDown && keyCode == kVK_Space { return nil }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Emits `.meetingControlTap` for a quick press and release of Control with nothing else in between: no other
    /// modifier, key, click or scroll (so Control-click and Control-scroll zoom don't switch modes).
    private func trackControlTap(keyCode: Int, flags: CGEventFlags) {
        guard isRecordingMeeting, !fnDown, !isCapturing else { controlTap = nil; return }
        let isControl = keyCode == kVK_Control || keyCode == kVK_RightControl
        let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
        if isControl && flags.contains(.maskControl) {
            controlTap = flags.intersection(others).isEmpty ? (CFAbsoluteTimeGetCurrent(), Self.mouseEventCount()) : nil
        } else if isControl, let tap = controlTap {
            controlTap = nil
            if CFAbsoluteTimeGetCurrent() - tap.at < 0.5 && Self.mouseEventCount() == tap.mouseEvents { emit(.meetingControlTap) }
        } else {
            controlTap = nil
        }
    }

    private static func mouseEventCount() -> UInt32 {
        [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            .reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }

    private func emit(_ e: HotkeyEvent) {
        Log.write("hotkey: \(e)")
        let h = handler
        DispatchQueue.main.async { h?(e) }
    }

    // MARK: - Synthetic key presses

    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
