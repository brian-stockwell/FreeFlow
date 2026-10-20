import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Sound cues: themes (bundled WAVs), per-event overrides (any theme sound, macOS system sound, or your own file), volume.
enum Sounds {
    enum Cue: String, CaseIterable, Identifiable {
        case start, stop, ready, modeSwitch, cancel, error, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .start: return "Fn pressed (start listening)"
            case .stop: return "Fn released (stop listening)"
            case .ready: return "Hands-free locked"
            case .modeSwitch: return "Mode switched (Control / Option)"
            case .cancel: return "Cancelled"
            case .error: return "Error"
            case .done: return "Pasted"
            }
        }
        /// Which bundled file a cue uses inside a theme (modeSwitch shares the "ready" tap).
        var fileName: String { self == .modeSwitch ? "ready" : rawValue }
    }

    struct Theme: Identifiable, Hashable { let id: String; let name: String; let description: String }

    static let themes: [Theme] = [
        Theme(id: "wood", name: "Wood", description: "Muted marimba taps"),
        Theme(id: "click", name: "Click", description: "Tiny mechanical ticks"),
        Theme(id: "soft", name: "Soft", description: "Warm low tones"),
        Theme(id: "bubble", name: "Bubble", description: "Quick little sweeps"),
        Theme(id: "system", name: "System", description: "macOS alert sounds (Tink / Pop)"),
        Theme(id: "none", name: "None", description: "Silent; the bar shows everything"),
    ]

    static let systemSoundNames = ["Tink", "Pop", "Glass", "Purr", "Ping", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Sosumi", "Submarine", "Basso"]

    /// A selectable sound: id is "theme:<theme>/<file>", "system:<Name>", "file:<path>".
    struct Option: Identifiable, Hashable { let id: String; let label: String }

    static var customDirectory: URL {
        let d = Database.shared.supportDirectory.appendingPathComponent("sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Everything the per-event pickers can choose from.
    static func catalog() -> [Option] {
        var out: [Option] = []
        for t in themes where t.id != "system" && t.id != "none" {
            for f in ["start", "stop", "ready", "done", "cancel", "error"] {
                out.append(Option(id: "theme:\(t.id)/\(f)", label: "\(t.name) · \(f)"))
            }
        }
        for n in systemSoundNames { out.append(Option(id: "system:\(n)", label: "macOS · \(n)")) }
        let files = (try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where ["wav", "aiff", "aif", "mp3", "m4a", "caf"].contains(f.pathExtension.lowercased()) {
            out.append(Option(id: "file:\(f.path)", label: "Custom · \(f.deletingPathExtension().lastPathComponent)"))
        }
        return out
    }

    /// Copies a user-chosen audio file into the custom sounds folder; returns its option id.
    static func importCustomFile(_ url: URL) -> String? {
        let dest = customDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        cache.removeAll()
        return "file:\(dest.path)"
    }

    private static var cache: [String: NSSound] = [:]

    static func play(_ cue: Cue) {
        let s = Settings.shared
        guard s.soundsEnabled else { return }
        let id = resolvedID(for: cue, theme: s.soundTheme, overrides: s.cueSounds)
        play(id: id, volume: Float(s.soundVolume))
    }

    /// Preview helper for Settings (theme-level).
    static func play(_ cue: Cue, theme: String, volume: Float) {
        play(id: resolvedID(for: cue, theme: theme, overrides: [:]), volume: volume)
    }

    static func resolvedID(for cue: Cue, theme: String, overrides: [String: String]) -> String {
        if let o = overrides[cue.rawValue], !o.isEmpty { return o }   // "none" or an explicit sound
        switch theme {
        case "none": return "none"
        case "system":
            let names: [Cue: String] = [.start: "Tink", .stop: "Pop", .ready: "Glass", .modeSwitch: "Glass", .cancel: "Bottle", .error: "Basso", .done: "Morse"]
            return "system:\(names[cue] ?? "Pop")"
        default: return "theme:\(theme)/\(cue.fileName)"
        }
    }

    static func play(id: String, volume: Float) {
        guard id != "none", volume > 0.01, let snd = sound(id: id) else { return }
        snd.stop()
        snd.volume = volume
        snd.play()
    }

    private static func sound(id: String) -> NSSound? {
        if let s = cache[id] { return s }
        var s: NSSound?
        if id.hasPrefix("system:") {
            s = NSSound(named: NSSound.Name(String(id.dropFirst(7))))
        } else if id.hasPrefix("theme:") {
            let rest = String(id.dropFirst(6)).split(separator: "/")
            if rest.count == 2, let url = Bundle.module.url(forResource: String(rest[1]), withExtension: "wav", subdirectory: "sounds/\(rest[0])") {
                s = NSSound(contentsOf: url, byReference: true)
            }
        } else if id.hasPrefix("file:") {
            s = NSSound(contentsOf: URL(fileURLWithPath: String(id.dropFirst(5))), byReference: true)
        }
        if let s { cache[id] = s }
        return s
    }
}
