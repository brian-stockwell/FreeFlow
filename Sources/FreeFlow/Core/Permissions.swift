import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    static func promptInputMonitoring() {
        CGRequestListenEventAccess()
    }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openSystemSettings(pane: String) {
        // pane: Privacy_Accessibility | Privacy_ListenEvent | Privacy_Microphone | Privacy_AudioCapture
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }

    static var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
}
