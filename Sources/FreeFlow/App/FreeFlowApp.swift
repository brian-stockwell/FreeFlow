import SwiftUI
import AppKit

@main
struct FreeFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if SelfTest.runIfRequested() { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }
}

struct MenuBarLabel: View {
    private var controller: DictationController { DictationController.shared }
    private var meeting: MeetingRecorder { MeetingRecorder.shared }
    var body: some View {
        let name: String = {
            if meeting.isRecording { return "record.circle.fill" }
            switch controller.state {
            case .idle: return controller.hotkeysPaused ? "waveform.slash" : "waveform"
            case .recording: return "waveform.circle.fill"
            case .processing: return "ellipsis.circle"
            }
        }()
        Image(systemName: name)
    }
}

struct MenuBarContent: View {
    private var controller: DictationController { DictationController.shared }
    private var meeting: MeetingRecorder { MeetingRecorder.shared }
    @Bindable private var settings = Settings.shared

    var body: some View {
        Group {
            Text(statusLine).font(.caption)
            Divider()
            Button("Open FreeFlow") { MainWindowController.shared.show() }
                .keyboardShortcut("o")
            Button(meeting.isRecording ? "Stop Meeting Recording (\(meeting.elapsedString))" : "Start Meeting Recording   ⌥N") {
                meeting.toggle()
            }
            Button("New Scratchpad Note") { MainWindowController.shared.show(page: .scratchpad, newNote: true) }
            Divider()
            Button("Paste Last Transcript   ⌘⌃V") {
                if let t = controller.lastPastedText {
                    _ = TextInserter.paste(t, context: ContextReader.capture(readText: false))
                }
            }.disabled(controller.lastPastedText == nil)
            Button("Copy Last Transcript   ⌘⌃C") {
                if let t = controller.lastPastedText { TextInserter.copyToClipboard(t) }
            }.disabled(controller.lastPastedText == nil)
            Divider()
            Toggle("Pause hotkeys", isOn: Binding(get: { controller.hotkeysPaused }, set: { controller.hotkeysPaused = $0 }))
            Toggle("Show Flow Bar", isOn: $settings.showFlowBar)
            Divider()
            Button("Settings…") { MainWindowController.shared.show(page: .settings) }
                .keyboardShortcut(",")
            Button("Quit FreeFlow") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var statusLine: String {
        if meeting.isRecording { return "Recording meeting • \(meeting.elapsedString)" }
        switch controller.state {
        case .idle: return controller.hotkeysPaused ? "Hotkeys paused" : "Ready • hold Fn to dictate, Fn+Ctrl to clean up"
        case .recording: return "Listening (\(controller.mode.rawValue))…"
        case .processing: return "Processing…"
        }
    }
}
