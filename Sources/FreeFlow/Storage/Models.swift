import Foundation
import GRDB

// MARK: - Enums

enum DictationMode: String, Codable, CaseIterable, Sendable {
    case raw        // Fn: transcript only
    case clean      // Fn+Ctrl: Claude cleanup + context formatting
    case command    // Fn+Option: speak an edit instruction
    case transform  // hotkey transform of selected text (Polish, Prompt Engineer, custom)
}

enum DictationStatus: String, Codable, Sendable {
    case formatted        // Claude cleanup applied and pasted
    case rawTranscript    // raw text pasted (raw mode, or fallback)
    case dismissed        // cancelled by user
    case noAudio          // nothing transcribed
    case failed
}

/// Wispr-style app categories used to pick a writing style.
enum AppCategory: String, Codable, CaseIterable, Sendable {
    case email, work, personal, ai, documents, other

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .work: return "Work messages"
        case .personal: return "Personal messages"
        case .ai: return "AI prompts"
        case .documents: return "Documents"
        case .other: return "Other"
        }
    }
}

enum WritingStyle: String, Codable, CaseIterable, Sendable {
    case formal, casual, veryCasual, excited

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        case .excited: return "Excited!"
        }
    }
}

enum CleanupLevel: String, Codable, CaseIterable, Sendable {
    case none, light, medium
    var displayName: String {
        switch self {
        case .none: return "None (raw)"
        case .light: return "Light (fillers + grammar)"
        case .medium: return "Medium (also rewords for concision)"
        }
    }
}

// MARK: - Records

struct HistoryEntry: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "history"

    var id: String = UUID().uuidString
    var timestamp: Date = Date()
    var mode: DictationMode = .raw
    var status: DictationStatus = .rawTranscript
    var appBundleID: String? = nil
    var appName: String? = nil
    var url: String? = nil
    var category: AppCategory = .other
    var style: WritingStyle? = nil
    var asrText: String = ""            // what the speech engine heard
    var formattedText: String? = nil    // Claude output (clean / command)
    var pastedText: String? = nil       // what was actually inserted
    var editedText: String? = nil       // what the field contained after the user edited (auto-learn)
    var instruction: String? = nil      // command mode: the spoken instruction
    var audioPath: String? = nil
    var duration: Double = 0            // seconds recorded
    var speechDuration: Double = 0      // seconds of detected speech
    var numWords: Int = 0
    var numWordsCorrected: Int = 0
    var numDictionaryReplacements: Int = 0
    var e2eLatency: Double = 0          // seconds from key-up to paste
    var model: String? = nil
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var isArchived: Bool = false
    var errorMessage: String? = nil

    var displayText: String { pastedText ?? formattedText ?? asrText }
}

struct DictionaryEntry: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "dictionary"

    var id: String = UUID().uuidString
    var phrase: String                  // spoken / recognized form (or the word itself)
    var replacement: String? = nil      // nil => phrase is a vocabulary word to spell exactly this way
    var isSnippet: Bool = false         // trigger phrase -> long expansion
    var source: String = "manual"       // manual | auto | import | default
    var frequencyUsed: Int = 0
    var lastUsed: Date? = nil
    var isStarred: Bool = false
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
}

struct Note: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "notes"

    var id: String = UUID().uuidString
    var title: String = ""
    var content: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var pinned: Bool = false
    var isDeleted: Bool = false

    var displayTitle: String {
        if !title.isEmpty { return title }
        let words = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(3)
        return words.isEmpty ? "Untitled" : words.joined(separator: " ")
    }
}

struct NoteVersion: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "noteVersions"
    var id: String = UUID().uuidString
    var noteId: String
    var content: String
    var createdAt: Date = Date()
}

enum MeetingStatus: String, Codable, Sendable {
    case recording, processing, done, failed
}

/// What a recording is: a call (summary + to-dos for the user) or a class (study notes). Tap Control while recording to switch.
enum MeetingKind: String, Codable, Sendable, CaseIterable {
    case meeting, lecture

    var label: String { self == .lecture ? "Lecture" : "Meeting" }
    var toggled: MeetingKind { self == .lecture ? .meeting : .lecture }

    /// In a lecture the mic hears the whole room (mostly the instructor), not just the user.
    func speakerLabel(_ speaker: String) -> String {
        switch self {
        case .meeting: return speaker == "me" ? "Me" : "Them"
        case .lecture: return speaker == "me" ? "Room" : "Online"
        }
    }
}

struct Meeting: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meetings"

    var id: String = UUID().uuidString
    var title: String = "Untitled meeting"
    var createdAt: Date = Date()
    var endedAt: Date? = nil
    var durationMs: Int = 0
    var status: MeetingStatus = .recording
    var kind: MeetingKind = .meeting
    var platform: String? = nil          // zoom / teams / meet / in-person
    var micAudioPath: String? = nil
    var systemAudioPath: String? = nil
    var summary: String? = nil           // markdown
    var myThoughts: String = ""          // typed notes during the meeting
    var participants: String? = nil      // comma separated, from summary
    var model: String? = nil
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var errorMessage: String? = nil
}

struct MeetingSegment: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meetingSegments"

    var id: String = UUID().uuidString
    var meetingId: String
    var speaker: String                  // "me" | "them"
    var text: String
    var startMs: Int
    var endMs: Int
    var isFinal: Bool = true
}

enum TodoStatus: String, Codable, Sendable { case open, done }

struct Todo: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "todos"
    var id: String = UUID().uuidString
    var meetingId: String? = nil
    var title: String
    var status: TodoStatus = .open
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var sortOrder: Double = 0
    var isDeleted: Bool = false
}

/// Running tally of Claude API spend so the user can see what the clone costs.
struct UsageLedger: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "usageLedger"
    var id: String = UUID().uuidString
    var timestamp: Date = Date()
    var feature: String          // cleanup | command | summary | title
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var estimatedCostUSD: Double
}


/// A Wispr-style Transform: a hotkey that rewrites the selected text (or the whole field / last dictation) with a prompt.
struct Transform: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "transforms"

    var id: String = UUID().uuidString
    var name: String
    var prompt: String
    var shortcut: String? = nil      // e.g. "opt+1", "opt+shift+p"; nil = no hotkey
    var isBuiltIn: Bool = false
    var builtInKey: String? = nil    // polish | promptEngineer | list | translate | concise | grammar
    var enabled: Bool = true
    var sortOrder: Double = 0
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
}

extension Transform {
    /// Wispr's defaults: Polish ⌥1, Prompt Engineer ⌥2, plus the re-transform options as their own transforms.
    static let builtIns: [Transform] = [
        Transform(name: "Polish", prompt: "", shortcut: "opt+1", isBuiltIn: true, builtInKey: "polish"),
        Transform(name: "Prompt Engineer",
                  prompt: """
                  Turn these spoken, loosely organized thoughts into a well-structured prompt for an AI assistant. Keep every \
                  requirement, constraint, example and detail the author mentioned; do not invent new ones. Structure: a one-line \
                  goal, then "Context", "Requirements" (as a list), "Constraints" if any, and "Output format" if the author \
                  implied one. Write in the second person addressing the assistant. Plain markdown. Output the prompt only, \
                  starting with the goal line; no analysis of the input, no preface.
                  """,
                  shortcut: "opt+2", isBuiltIn: true, builtInKey: "promptEngineer"),
        Transform(name: "Turn into a list",
                  prompt: "Rewrite the text as a clean list: one item per line, \"- \" bullets (or \"1.\" numbering if the order matters), each item a short complete phrase. Keep a one-line lead-in sentence only if the text had one.",
                  shortcut: "opt+3", isBuiltIn: true, builtInKey: "list"),
        Transform(name: "Make it concise",
                  prompt: "Cut the text to roughly half its length while keeping every distinct point and the author's tone. Remove repetition, hedging and filler. Keep the same format.",
                  shortcut: "opt+4", isBuiltIn: true, builtInKey: "concise"),
        Transform(name: "Fix grammar only",
                  prompt: "Fix spelling, grammar and punctuation only. Do not change wording, tone, structure or length otherwise.",
                  shortcut: "opt+5", isBuiltIn: true, builtInKey: "grammar"),
        Transform(name: "Translate to English",
                  prompt: "Translate the text into natural, fluent English, keeping the tone, formatting and any names or technical terms. If it is already English, return it unchanged.",
                  shortcut: nil, isBuiltIn: true, builtInKey: "translate"),
        Transform(name: "Empathize",
                  prompt: "Rewrite the text so it is warmer and more empathetic toward the reader: acknowledge their situation briefly, keep the substance and any requests, and avoid sounding saccharine. Same length or shorter.",
                  shortcut: nil, isBuiltIn: true, builtInKey: "empathize"),
    ]
}
