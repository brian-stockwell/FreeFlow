import SwiftUI
import AppKit
import AVFoundation
import Speech

struct SettingsView: View {
    @Bindable var settings = Settings.shared
    @State private var micStatus = Permissions.microphoneStatus
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var inputGranted = Permissions.inputMonitoringGranted
    @State private var modelInstalled: Bool? = nil
    @State private var downloading = false
    @State private var downloadProgress = 0.0
    @State private var downloadError: String?
    @State private var keyText = ""
    @State private var keyResult: String?
    @State private var testingKey = false
    @State private var hotkeysRunning = HotkeyManager.shared.isRunning
    @State private var devices: [AudioInputDevice] = []
    @State private var confirmDelete = false
    @State private var poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let languages = ["en-US", "en-GB", "en-AU", "en-CA", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "zh-CN"]
    private let models: [(String, String)] = [
        ("claude-haiku-5-5", "Haiku 5.5 — $0.10/$0.50 per M tokens, fastest"),
        ("claude-sonnet-5-5", "Sonnet 5.5 — $2/$10 per M"),
        ("claude-opus-5-5", "Opus 5.5 — $4/$20 per M"),
    ]
    private let hotkeys: [(String, String)] = [
        ("Hold Fn", "Raw transcript"),
        ("Hold Fn + Ctrl", "Claude cleanup with context-aware style"),
        ("Hold Fn + Option", "Command Mode (speak an edit instruction)"),
        ("Fn + Space or double-tap Fn", "Hands-free dictation"),
        ("Esc", "Cancel"),
        ("Cmd + Ctrl + V", "Paste last transcript"),
        ("Option + N", "Start / stop meeting recording"),
        ("Transform hotkeys", "⌥1…⌥5 (configurable on the Transforms page)"),
    ]

    var body: some View {
        Form {
            setupSection
            modelsSection
            dictationSection
            meetingsSection
            hotkeysSection
            systemSection
            dataSection
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear { keyText = settings.apiKey; devices = AudioRecorder.inputDevices(); Task { await refresh() } }
        .onReceive(poll) { _ in Task { await refresh() } }
        .confirmationDialog("Delete all history?", isPresented: $confirmDelete) {
            Button("Delete all history", role: .destructive) { SettingsData.deleteAllHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("History entries are archived and all saved audio files are removed. This cannot be undone.")
        }
    }

    // MARK: Setup

    private var micOK: Bool { micStatus == .authorized }

    @ViewBuilder private var setupSection: some View {
        Section {
            row("Microphone", ok: micOK, detail: micOK ? "Allowed" : (micStatus == .notDetermined ? "Not requested yet" : "Denied")) {
                if !micOK {
                    if micStatus == .notDetermined {
                        Button("Allow") { Task { _ = await Permissions.requestMicrophone(); await refresh() } }
                    } else {
                        Button("Open System Settings") { Permissions.openSystemSettings(pane: "Privacy_Microphone") }
                    }
                }
            }
            row("Accessibility", ok: axGranted, detail: axGranted ? "Granted" : "Needed for hotkeys and reading the text field") {
                if !axGranted {
                    Button("Open System Settings") {
                        Permissions.promptAccessibility()
                        Permissions.openSystemSettings(pane: "Privacy_Accessibility")
                    }
                }
            }
            row("Input Monitoring", ok: inputGranted, detail: inputGranted ? "Granted" : "Needed to detect the Fn key") {
                if !inputGranted {
                    Button("Open System Settings") {
                        Permissions.promptInputMonitoring()
                        Permissions.openSystemSettings(pane: "Privacy_ListenEvent")
                    }
                }
            }
            LabeledContent {
                Button("Open System Settings") { Permissions.openSystemSettings(pane: "Privacy_AudioCapture") }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("System Audio Recording (meetings)", systemImage: "info.circle").foregroundStyle(.secondary)
                    Text("Requested the first time you record a meeting.").font(.caption).foregroundStyle(.secondary)
                }
            }
            row("Speech model", ok: modelInstalled == true,
                detail: modelInstalled == nil ? "Checking…" : (modelInstalled == true ? "Installed" : (downloadError ?? "Not downloaded"))) {
                if downloading {
                    ProgressView(value: downloadProgress).frame(width: 100)
                } else if modelInstalled == false {
                    Button("Download") { download() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: settings.hasAPIKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(settings.hasAPIKey ? .green : .orange)
                    Text("Claude API key")
                    Spacer()
                    if let r = keyResult {
                        Text(r).font(.caption).foregroundStyle(r.hasPrefix("Valid") ? .green : .red).lineLimit(2)
                    }
                }
                HStack {
                    SecureField("sk-ant-…", text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitKey() }
                    Button("Save") { commitKey() }
                    Button(testingKey ? "Testing…" : "Test key") { commitKey(); testKey() }
                        .disabled(testingKey || keyText.isEmpty)
                }
                Text("Stored in the macOS Keychain, never in plain text.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: hotkeysRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hotkeysRunning ? .green : .orange)
                Text(hotkeysRunning ? "Hotkeys active" : "Hotkeys inactive — grant Accessibility and Input Monitoring")
                Spacer()
                if !hotkeysRunning { Button("Retry") { DictationController.shared.restartHotkeys(); hotkeysRunning = HotkeyManager.shared.isRunning } }
            }
        } header: { Text("Setup") }
    }

    private func row<T: View>(_ title: String, ok: Bool, detail: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }

    private func commitKey() {
        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != settings.apiKey { settings.apiKey = trimmed }
        keyText = trimmed
    }

    private func testKey() {
        testingKey = true; keyResult = nil
        Task {
            let err = await ClaudeClient.shared.validateKey()
            keyResult = err ?? "Valid ✓"
            testingKey = false
        }
    }

    private func download() {
        downloading = true; downloadError = nil; downloadProgress = 0
        Task {
            do {
                let ok = try await SpeechEngine.ensureAssets { p in Task { @MainActor in downloadProgress = p } }
                if !ok { downloadError = "Language not supported on this Mac" }
            } catch {
                downloadError = error.localizedDescription
            }
            downloading = false
            await refresh()
        }
    }

    private func refresh() async {
        let wasAX = axGranted
        micStatus = Permissions.microphoneStatus
        axGranted = Permissions.accessibilityGranted
        inputGranted = Permissions.inputMonitoringGranted
        if axGranted && !wasAX { DictationController.shared.restartHotkeys() }
        hotkeysRunning = HotkeyManager.shared.isRunning
        let status = await SpeechEngine.assetStatus()
        modelInstalled = (status == .installed)
        if micOK && axGranted && settings.hasAPIKey && !settings.onboardingCompleted {
            settings.onboardingCompleted = true
        }
    }

    // MARK: Models

    private var modelsSection: some View {
        Section {
            modelPicker("Cleanup model", $settings.cleanupModel)
            modelPicker("Command Mode model", $settings.commandModel)
            modelPicker("Meeting summary model", $settings.summaryModel)
        } header: { Text("Models (cost)") } footer: {
            Text("Haiku costs about $0.0002 per dictation, so it is the right default for cleanup and commands. Use Sonnet or Opus only if you want higher quality summaries.")
        }
    }

    private func modelPicker(_ title: String, _ binding: Binding<String>) -> some View {
        Picker(title, selection: binding) {
            ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
            if !models.contains(where: { $0.0 == binding.wrappedValue }) { Text(binding.wrappedValue).tag(binding.wrappedValue) }
        }
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Section("Dictation") {
            Picker("Cleanup level", selection: $settings.cleanupLevel) {
                ForEach(CleanupLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Context awareness (reads the focused field and on-screen names)", isOn: $settings.contextAwareness)
            Toggle("Auto-learn words from your edits", isOn: $settings.autoLearnWords)
            Toggle("Command Mode (Fn + Option)", isOn: $settings.commandModeEnabled)
            Toggle("Double-tap Fn for hands-free", isOn: $settings.handsFreeDoubleTap)
            Stepper("Max dictation length: \(settings.maxDictationMinutes) min", value: $settings.maxDictationMinutes, in: 5...60)
            Picker("Language", selection: $settings.languageIdentifier) {
                ForEach(languages, id: \.self) { Text(languageLabel($0)).tag($0) }
            }
            Picker("Microphone", selection: $settings.microphoneUID) {
                Text("Auto (system default)").tag(String?.none)
                ForEach(devices) { Text($0.name).tag(Optional($0.uid)) }
                if let uid = settings.microphoneUID, !devices.contains(where: { $0.uid == uid }) {
                    Text("Unavailable device").tag(Optional(uid))
                }
            }
        }
    }

    // MARK: Meetings

    private var meetingsSection: some View {
        Section {
            Toggle("Detect meetings and offer to record", isOn: $settings.autoDetectMeetings)
            Toggle("Start recording automatically", isOn: $settings.autoStartMeetings)
                .disabled(!settings.autoDetectMeetings)
            Stepper("Meeting max length: \(settings.meetingMaxMinutes) min", value: $settings.meetingMaxMinutes, in: 30...240, step: 15)
        } header: { Text("Meetings") } footer: {
            Text("When your mic is in use by Zoom, Teams, Meet, Webex, FaceTime or a Slack huddle, the bar offers to record.")
        }
    }

    private func languageLabel(_ id: String) -> String {
        if let n = Locale.current.localizedString(forIdentifier: id) { return "\(n) (\(id))" }
        return id
    }

    // MARK: Hotkeys

    private var hotkeysSection: some View {
        Section {
            ForEach(hotkeys, id: \.0) { k in
                LabeledContent(k.0) { Text(k.1).foregroundStyle(.secondary) }
            }
        } header: { Text("Hotkeys") } footer: {
            Text("Shortcuts are fixed in this version. FreeFlow swallows the Fn key so the emoji picker does not open.")
        }
    }

    // MARK: System

    private var systemSection: some View {
        Section("System") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .onChange(of: settings.launchAtLogin) { _, v in Permissions.setLaunchAtLogin(v) }
            Toggle("Sounds", isOn: $settings.soundsEnabled)
            SoundsSettingsSection()
            Toggle("Show Flow Bar (floating pill)", isOn: $settings.showFlowBar)
            Toggle("Show icon in Dock", isOn: $settings.showInDock)
                .onChange(of: settings.showInDock) { _, v in NSApp.setActivationPolicy(v ? .regular : .accessory) }
            Stepper(settings.audioRetentionDays == 0 ? "Keep audio: don't keep" : "Keep audio: \(settings.audioRetentionDays) days",
                    value: $settings.audioRetentionDays, in: 0...90)
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section("Data") {
            LabeledContent("Data folder") {
                Text(SettingsData.supportPath).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            HStack {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([SettingsData.supportURL]) }
                Spacer()
                Button("Delete all history", role: .destructive) { confirmDelete = true }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("FreeFlow", value: "Version 1.0")
            Text("A native macOS voice dictation app with Claude-powered cleanup, Command Mode and meeting notes.")
                .foregroundStyle(.secondary)
            Text("You pay only for Claude API usage: roughly $0.0002 per dictation with Haiku. Speech recognition runs on-device for free.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
