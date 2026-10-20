import Foundation
import GRDB

enum SettingsData {
    /// Archives all history and removes audio files.
    static func deleteAllHistory() {
        let db = FreeFlow.Database.shared
        let entries = (try? db.read { d in try HistoryEntry.fetchAll(d) }) ?? []
        for e in entries { if let p = e.audioPath { try? FileManager.default.removeItem(atPath: p) } }
        try? db.write { d in
            try d.execute(sql: "UPDATE history SET isArchived = 1, audioPath = NULL")
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: db.audioDirectory, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    static var supportPath: String { FreeFlow.Database.shared.supportDirectory.path }
    static var supportURL: URL { FreeFlow.Database.shared.supportDirectory }
}
