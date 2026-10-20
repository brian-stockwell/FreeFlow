import Foundation
import GRDB

/// One-time import of the user's existing Wispr Flow dictionary, snippets, styles and signature.
enum WisprImport {
    static var wisprSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: wisprSupportDir.appendingPathComponent("flow.sqlite").path)
    }

    struct Report { var dictionaryCount = 0; var snippetCount = 0; var importedStyles = false; var importedSignature = false; var error: String? }

    static func run() -> Report {
        var report = Report()
        let dbPath = wisprSupportDir.appendingPathComponent("flow.sqlite").path
        do {
            // Wispr keeps the DB in WAL mode while running; copy the trio to a temp folder and read the copy.
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("freeflow-wispr-import-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            for suffix in ["", "-wal", "-shm"] {
                let from = dbPath + suffix
                if fm.fileExists(atPath: from) { try fm.copyItem(atPath: from, toPath: tmp.appendingPathComponent("flow.sqlite" + suffix).path) }
            }
            let src = try DatabaseQueue(path: tmp.appendingPathComponent("flow.sqlite").path)
            let rows: [Row] = try src.read { db in
                try Row.fetchAll(db, sql: "SELECT phrase, replacement, isSnippet, source, isStarred FROM Dictionary WHERE isDeleted = 0")
            }
            for r in rows {
                let phrase: String = r["phrase"]
                let replacement: String? = r["replacement"]
                let isSnippet: Bool = (r["isSnippet"] as Int? ?? 0) != 0
                // Skip Wispr's own promotional defaults.
                if phrase.lowercased().contains("flow referral") || phrase == "Wispr Flow" { continue }
                Database.shared.upsertDictionary(phrase: phrase, replacement: replacement, isSnippet: isSnippet, source: "import")
                if isSnippet { report.snippetCount += 1 } else { report.dictionaryCount += 1 }
            }
        } catch {
            report.error = "\(error)"
            NSLog("Wispr dictionary import failed: \(error)")
        }
        let configURL = wisprSupportDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prefs = json["prefs"] as? [String: Any],
           let user = prefs["user"] as? [String: Any] {
            let s = Settings.shared
            if let first = user["firstName"] as? String, !first.isEmpty { s.userFirstName = first }
            if let last = user["lastName"] as? String, !last.isEmpty { s.userLastName = last }
            if let sig = user["emailAutoSignature"] as? String, !sig.isEmpty {
                s.emailSignature = sig
                report.importedSignature = true
            }
            if let styles = user["personalizationStyles"] as? [String: String] {
                func map(_ v: String?) -> WritingStyle? {
                    switch v { case "formal": return .formal; case "casual": return .casual
                    case "very_casual", "veryCasual", "genz": return .veryCasual; case "excited": return .excited
                    default: return nil }
                }
                if let v = map(styles["email"]) { s.styleEmail = v }
                if let v = map(styles["work"]) { s.styleWork = v }
                if let v = map(styles["personal"]) { s.stylePersonal = v }
                if let v = map(styles["other"]) { s.styleOther = v }
                report.importedStyles = true
            }
            if let level = (user["autoCleanup"] as? [String: Any])?["level"] as? String,
               let l = CleanupLevel(rawValue: level) { s.cleanupLevel = l }
        }
        Settings.shared.wisprImported = true
        return report
    }
}
