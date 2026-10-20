import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sound theme picker with previews, per-event sound pickers (any theme sound, macOS sound, your own file, or none), volume.
struct SoundsSettingsSection: View {
    @Bindable private var settings = Settings.shared
    @State private var showEvents = true
    @State private var catalog: [Sounds.Option] = Sounds.catalog()

    private func preview(_ theme: String) {
        Sounds.play(.start, theme: theme, volume: Float(settings.soundVolume))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            Sounds.play(.stop, theme: theme, volume: Float(settings.soundVolume))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Theme")
                Spacer()
                Picker("", selection: $settings.soundTheme) {
                    ForEach(Sounds.themes) { t in Text(t.name).tag(t.id) }
                }
                .labelsHidden()
                .frame(width: 140)
                .onChange(of: settings.soundTheme) { _, new in preview(new) }
            }
            if let t = Sounds.themes.first(where: { $0.id == settings.soundTheme }) {
                Text(t.description).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Sounds.themes.filter { $0.id != "none" }) { t in
                    Button(t.name) { preview(t.id) }.controlSize(.small)
                }
                Text("← preview").font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                Text("Volume")
                Slider(value: $settings.soundVolume, in: 0...1) { EmptyView() }
                    .onChange(of: settings.soundVolume) { _, v in
                        Sounds.play(id: Sounds.resolvedID(for: .stop, theme: settings.soundTheme, overrides: settings.cueSounds), volume: Float(v))
                    }
                Text("\(Int(settings.soundVolume * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            DisclosureGroup("Sound per event", isExpanded: $showEvents) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Each event can use the theme's sound, any other sound, a file of your own, or nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Sounds.Cue.allCases) { cue in
                        HStack {
                            Text(cue.title).frame(width: 230, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { settings.cueSounds[cue.rawValue] ?? "" },
                                set: { v in
                                    var m = settings.cueSounds
                                    if v.isEmpty { m.removeValue(forKey: cue.rawValue) } else { m[cue.rawValue] = v }
                                    settings.cueSounds = m
                                    if v != "none" { Sounds.play(cue) }
                                })) {
                                Text("Theme default").tag("")
                                Text("None").tag("none")
                                Divider()
                                ForEach(catalog) { o in Text(o.label).tag(o.id) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                            Button { Sounds.play(cue) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.borderless).help("Play")
                        }
                        .controlSize(.small)
                    }
                    HStack {
                        Button("Import sound file…") { importFile() }.controlSize(.small)
                        Text("WAV, AIFF, MP3, M4A or CAF. Imported sounds appear in the pickers as “Custom”.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Button("Reset all events to theme default") { settings.cueSounds = [:] }.controlSize(.small)
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
        .disabled(!settings.soundsEnabled)
        .opacity(settings.soundsEnabled ? 1 : 0.5)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff, .mp3, .mpeg4Audio, UTType("com.apple.coreaudio-format") ?? .audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a short sound file"
        if panel.runModal() == .OK, let url = panel.url, let id = Sounds.importCustomFile(url) {
            catalog = Sounds.catalog()
            Sounds.play(id: id, volume: Float(settings.soundVolume))
        }
    }
}
