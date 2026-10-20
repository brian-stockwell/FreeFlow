import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.shared
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        _ = Database.shared
        Notifier.requestAuthorization()

        if !settings.wisprImported && WisprImport.isAvailable {
            let r = WisprImport.run()
            NSLog("Imported from Wispr Flow: \(r.dictionaryCount) words, \(r.snippetCount) snippets")
        }

        DictationController.shared.start()
        FlowBarController.shared.show()
        MeetingDetector.shared.start()
        Database.shared.pruneAudio(olderThan: settings.audioRetentionDays)
        MeetingRecorder.shared.deleteLeftoverAudio()

        if !settings.onboardingCompleted || !Permissions.accessibilityGranted || settings.apiKey.isEmpty {
            MainWindowController.shared.show(page: .settings)
        }

        // Re-check the event tap when the app becomes active (permission may have been granted meanwhile).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if Permissions.accessibilityGranted && !HotkeyManager.shared.isRunning {
                DictationController.shared.restartHotkeys()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            FlowBarController.shared.reposition()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
        if MeetingRecorder.shared.isRecording { MeetingRecorder.shared.stop() }
    }
}
