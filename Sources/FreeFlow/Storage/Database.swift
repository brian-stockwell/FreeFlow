import Foundation
import GRDB

/// Single SQLite database for history, dictionary, notes, meetings, todos and usage.
final class Database: Sendable {
    static let shared = Database()

    let dbQueue: DatabaseQueue
    let supportDirectory: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeFlow", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        for sub in ["audio", "meetings"] {
            try? fm.createDirectory(at: base.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        supportDirectory = base
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try! DatabaseQueue(path: base.appendingPathComponent("freeflow.sqlite").path, configuration: config)
        try! migrator.migrate(dbQueue)
    }

    var audioDirectory: URL { supportDirectory.appendingPathComponent("audio") }
    var meetingsDirectory: URL { supportDirectory.appendingPathComponent("meetings") }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "history") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("mode", .text).notNull()
                t.column("status", .text).notNull()
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("url", .text)
                t.column("category", .text).notNull()
                t.column("style", .text)
                t.column("asrText", .text).notNull()
                t.column("formattedText", .text)
                t.column("pastedText", .text)
                t.column("editedText", .text)
                t.column("instruction", .text)
                t.column("audioPath", .text)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("speechDuration", .double).notNull().defaults(to: 0)
                t.column("numWords", .integer).notNull().defaults(to: 0)
                t.column("numWordsCorrected", .integer).notNull().defaults(to: 0)
                t.column("numDictionaryReplacements", .integer).notNull().defaults(to: 0)
                t.column("e2eLatency", .double).notNull().defaults(to: 0)
                t.column("model", .text)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheReadTokens", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("errorMessage", .text)
            }
            try db.create(table: "dictionary") { t in
                t.primaryKey("id", .text)
                t.column("phrase", .text).notNull()
                t.column("replacement", .text)
                t.column("isSnippet", .boolean).notNull().defaults(to: false)
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("frequencyUsed", .integer).notNull().defaults(to: 0)
                t.column("lastUsed", .datetime)
                t.column("isStarred", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_dictionary_phrase", on: "dictionary", columns: ["phrase"])
            try db.create(table: "notes") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("content", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull().indexed()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "noteVersions") { t in
                t.primaryKey("id", .text)
                t.column("noteId", .text).notNull().indexed().references("notes", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "meetings") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull()
                t.column("platform", .text)
                t.column("micAudioPath", .text)
                t.column("systemAudioPath", .text)
                t.column("summary", .text)
                t.column("myThoughts", .text).notNull().defaults(to: "")
                t.column("participants", .text)
                t.column("model", .text)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("errorMessage", .text)
            }
            try db.create(table: "meetingSegments") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("isFinal", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "todos") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text).indexed()
                t.column("title", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "open")
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("sortOrder", .double).notNull().defaults(to: 0)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "usageLedger") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("feature", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("cacheReadTokens", .integer).notNull()
                t.column("cacheWriteTokens", .integer).notNull()
                t.column("estimatedCostUSD", .double).notNull()
            }
        }
        m.registerMigration("v2-transforms") { db in
            try db.create(table: "transforms") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("shortcut", .text)
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("builtInKey", .text)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("sortOrder", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
            for (i, t) in Transform.builtIns.enumerated() {
                var row = t
                row.sortOrder = Double(i)
                try row.insert(db)
            }
        }
        m.registerMigration("v3-meeting-kind") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "kind", .text).notNull().defaults(to: MeetingKind.meeting.rawValue)
            }
        }
        return m
    }

    /// Active transforms in display order.
    func transforms() -> [Transform] {
        (try? read { db in
            try Transform.filter(Column("isDeleted") == false).order(Column("sortOrder")).fetchAll(db)
        }) ?? []
    }

    func saveTransform(_ t: Transform) {
        var row = t
        row.modifiedAt = Date()
        try? write { db in try row.save(db) }
        Task { @MainActor in TransformController.shared.reloadShortcuts() }
    }

    func deleteTransform(id: String) {
        try? write { db in
            if var t = try Transform.fetchOne(db, key: id) { t.isDeleted = true; t.modifiedAt = Date(); try t.update(db) }
        }
        Task { @MainActor in TransformController.shared.reloadShortcuts() }
    }

    /// Restores the built-in transforms (prompts and default shortcuts) without touching custom ones.
    func resetBuiltInTransforms() {
        try? write { db in
            for (i, t) in Transform.builtIns.enumerated() {
                if var existing = try Transform.filter(Column("builtInKey") == t.builtInKey).fetchOne(db) {
                    existing.name = t.name; existing.prompt = t.prompt; existing.shortcut = t.shortcut
                    existing.enabled = true; existing.isDeleted = false; existing.sortOrder = Double(i); existing.modifiedAt = Date()
                    try existing.update(db)
                } else {
                    var row = t; row.sortOrder = Double(i); try row.insert(db)
                }
            }
        }
        Task { @MainActor in TransformController.shared.reloadShortcuts() }
    }

    // MARK: - Convenience

    func write<T>(_ block: @escaping (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    func read<T>(_ block: @escaping (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    /// Active (non-deleted) dictionary entries, longest phrase first (for greedy matching).
    func activeDictionary() -> [DictionaryEntry] {
        (try? read { db in
            try DictionaryEntry.filter(Column("isDeleted") == false).fetchAll(db)
        }) ?? []
    }

    func upsertDictionary(phrase: String, replacement: String?, isSnippet: Bool = false, source: String = "manual") {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? write { db in
            if var existing = try DictionaryEntry
                .filter(Column("phrase").collating(.nocase) == trimmed)
                .filter(Column("isSnippet") == isSnippet)
                .fetchOne(db) {
                existing.replacement = replacement
                existing.isDeleted = false
                existing.modifiedAt = Date()
                try existing.update(db)
            } else {
                var e = DictionaryEntry(phrase: trimmed, replacement: replacement, isSnippet: isSnippet, source: source)
                e.modifiedAt = Date()
                try e.insert(db)
            }
        }
    }

    func recordUsage(feature: String, model: String, usage: ClaudeUsage) {
        let cost = ClaudePricing.cost(model: model, usage: usage)
        let row = UsageLedger(feature: feature, model: model,
                              inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                              cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: usage.cacheWriteTokens,
                              estimatedCostUSD: cost)
        try? write { db in try row.insert(db) }
    }

    /// Delete audio files older than `days` and clear their paths.
    func pruneAudio(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let fm = FileManager.default
        let entries = (try? read { db in
            try HistoryEntry.filter(Column("timestamp") < cutoff).filter(Column("audioPath") != nil).fetchAll(db)
        }) ?? []
        for var e in entries {
            if let p = e.audioPath { try? fm.removeItem(atPath: p) }
            e.audioPath = nil
            try? write { db in try e.update(db) }
        }
    }
}
