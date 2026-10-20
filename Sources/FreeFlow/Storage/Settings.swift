import Foundation
import Observation
import Security

/// User settings, persisted in UserDefaults (API key in Keychain).
@Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // MARK: Models (cost-efficient defaults: Haiku everywhere except meeting summaries)
    var cleanupModel: String { didSet { d.set(cleanupModel, forKey: "cleanupModel") } }
    var commandModel: String { didSet { d.set(commandModel, forKey: "commandModel") } }
    var summaryModel: String { didSet { d.set(summaryModel, forKey: "summaryModel") } }

    // MARK: Dictation behaviour
    var cleanupLevel: CleanupLevel { didSet { d.set(cleanupLevel.rawValue, forKey: "cleanupLevel") } }
    var contextAwareness: Bool { didSet { d.set(contextAwareness, forKey: "contextAwareness") } }
    var autoLearnWords: Bool { didSet { d.set(autoLearnWords, forKey: "autoLearnWords") } }
    var commandModeEnabled: Bool { didSet { d.set(commandModeEnabled, forKey: "commandModeEnabled") } }
    var handsFreeDoubleTap: Bool { didSet { d.set(handsFreeDoubleTap, forKey: "handsFreeDoubleTap") } }
    var languageIdentifier: String { didSet { d.set(languageIdentifier, forKey: "languageIdentifier") } }
    var microphoneUID: String? { didSet { d.set(microphoneUID, forKey: "microphoneUID") } }
    var maxDictationMinutes: Int { didSet { d.set(maxDictationMinutes, forKey: "maxDictationMinutes") } }

    // MARK: Styles per category (Wispr "Writing Styles")
    var styleEmail: WritingStyle { didSet { d.set(styleEmail.rawValue, forKey: "styleEmail") } }
    var styleWork: WritingStyle { didSet { d.set(styleWork.rawValue, forKey: "styleWork") } }
    var stylePersonal: WritingStyle { didSet { d.set(stylePersonal.rawValue, forKey: "stylePersonal") } }
    var styleOther: WritingStyle { didSet { d.set(styleOther.rawValue, forKey: "styleOther") } }
    var emailSignature: String { didSet { d.set(emailSignature, forKey: "emailSignature") } }
    var emailSignatureEnabled: Bool { didSet { d.set(emailSignatureEnabled, forKey: "emailSignatureEnabled") } }
    var userFirstName: String { didSet { d.set(userFirstName, forKey: "userFirstName") } }
    var userLastName: String { didSet { d.set(userLastName, forKey: "userLastName") } }
    /// Extra app names (lowercased bundle ids or domains) mapped to a category by the user.
    var customAppCategories: [String: String] { didSet { d.set(customAppCategories, forKey: "customAppCategories") } }

    // MARK: Transforms
    var transformsEnabled: Bool { didSet { d.set(transformsEnabled, forKey: "transformsEnabled") } }
    /// Wispr Polish rules (name → on/off).
    var polishRules: [String: Bool] { didSet { d.set(polishRules, forKey: "polishRules") } }
    /// Transform id to run automatically on every cleaned (Fn+Ctrl) dictation before pasting; nil = off.
    var autoApplyTransformID: String? { didSet { d.set(autoApplyTransformID, forKey: "autoApplyTransformID") } }

    // MARK: Meetings
    var autoDetectMeetings: Bool { didSet { d.set(autoDetectMeetings, forKey: "autoDetectMeetings") } }
    var autoStartMeetings: Bool { didSet { d.set(autoStartMeetings, forKey: "autoStartMeetings") } }

    // MARK: System
    var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }
    var soundsEnabled: Bool { didSet { d.set(soundsEnabled, forKey: "soundsEnabled") } }
    var soundVolume: Double { didSet { d.set(soundVolume, forKey: "soundVolume") } }
    var soundTheme: String { didSet { d.set(soundTheme, forKey: "soundTheme") } }
    /// Per-event sound override: cue rawValue → sound id ("theme:wood/start", "system:Tink", "file:/path", "none"); missing = theme default.
    var cueSounds: [String: String] { didSet { d.set(cueSounds, forKey: "cueSounds") } }
    var showFlowBar: Bool { didSet { d.set(showFlowBar, forKey: "showFlowBar") } }
    var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    var onboardingCompleted: Bool { didSet { d.set(onboardingCompleted, forKey: "onboardingCompleted") } }
    var wisprImported: Bool { didSet { d.set(wisprImported, forKey: "wisprImported") } }
    var audioRetentionDays: Int { didSet { d.set(audioRetentionDays, forKey: "audioRetentionDays") } }
    var meetingMaxMinutes: Int { didSet { d.set(meetingMaxMinutes, forKey: "meetingMaxMinutes") } }

    private init() {
        let d = UserDefaults.standard
        func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }

        cleanupModel = str("cleanupModel", "claude-haiku-5-5")
        commandModel = str("commandModel", "claude-haiku-5-5")
        summaryModel = str("summaryModel", "claude-sonnet-5-5")
        cleanupLevel = CleanupLevel(rawValue: str("cleanupLevel", "light")) ?? .light
        contextAwareness = bool("contextAwareness", true)
        autoLearnWords = bool("autoLearnWords", true)
        commandModeEnabled = bool("commandModeEnabled", true)
        handsFreeDoubleTap = bool("handsFreeDoubleTap", true)
        languageIdentifier = str("languageIdentifier", "en-US")
        microphoneUID = d.string(forKey: "microphoneUID")
        maxDictationMinutes = int("maxDictationMinutes", 20)
        styleEmail = WritingStyle(rawValue: str("styleEmail", "formal")) ?? .formal
        styleWork = WritingStyle(rawValue: str("styleWork", "formal")) ?? .formal
        stylePersonal = WritingStyle(rawValue: str("stylePersonal", "casual")) ?? .casual
        styleOther = WritingStyle(rawValue: str("styleOther", "casual")) ?? .casual
        emailSignature = str("emailSignature", "")
        emailSignatureEnabled = bool("emailSignatureEnabled", true)
        userFirstName = str("userFirstName", NSFullUserName().components(separatedBy: " ").first ?? "")
        userLastName = str("userLastName", NSFullUserName().components(separatedBy: " ").dropFirst().joined(separator: " "))
        customAppCategories = (d.dictionary(forKey: "customAppCategories") as? [String: String]) ?? [:]
        transformsEnabled = bool("transformsEnabled", true)
        polishRules = (d.dictionary(forKey: "polishRules") as? [String: Bool]) ?? Settings.defaultPolishRules
        autoApplyTransformID = d.string(forKey: "autoApplyTransformID")
        autoDetectMeetings = bool("autoDetectMeetings", true)
        autoStartMeetings = bool("autoStartMeetings", false)
        launchAtLogin = bool("launchAtLogin", true)
        soundsEnabled = bool("soundsEnabled", true)
        soundVolume = d.object(forKey: "soundVolume") == nil ? 0.15 : d.double(forKey: "soundVolume")
        soundTheme = str("soundTheme", "wood")
        cueSounds = (d.dictionary(forKey: "cueSounds") as? [String: String]) ?? ["done": "none"]
        showFlowBar = bool("showFlowBar", true)
        showInDock = bool("showInDock", false)
        onboardingCompleted = bool("onboardingCompleted", false)
        wisprImported = bool("wisprImported", false)
        audioRetentionDays = int("audioRetentionDays", 14)
        meetingMaxMinutes = int("meetingMaxMinutes", 120)
    }

    /// Same rule set (and defaults) as Wispr's Polish transform.
    static let polishRuleOrder = ["Make more concise", "Clarify main point", "Maintain your tone", "Reword for clarity",
                                  "Reorder for readability", "Refine phrasing for impact", "Add structure for readability"]
    static let defaultPolishRules: [String: Bool] = ["Make more concise": true, "Clarify main point": false,
        "Maintain your tone": true, "Reword for clarity": true, "Reorder for readability": true,
        "Refine phrasing for impact": false, "Add structure for readability": true]

    func style(for category: AppCategory) -> WritingStyle {
        switch category {
        case .email: return styleEmail
        case .work: return styleWork
        case .personal: return stylePersonal
        case .ai, .documents, .other: return styleOther
        }
    }

    func setStyle(_ style: WritingStyle, for category: AppCategory) {
        switch category {
        case .email: styleEmail = style
        case .work: styleWork = style
        case .personal: stylePersonal = style
        case .ai, .documents, .other: styleOther = style
        }
    }

    // MARK: API key (Keychain)

    private let keychainService = "com.brianstockwell.freeflow"
    private let keychainAccount = "anthropic-api-key"

    var apiKey: String {
        get {
            let stored = Keychain.read(service: keychainService, account: keychainAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stored.isEmpty { return stored }
            // Fallback: environment variable (handy when launched from a terminal).
            return (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            // Keys pasted from the console often carry a trailing newline or quotes; strip them.
            var v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            Keychain.write(service: keychainService, account: keychainAccount, value: v)
            apiKeyRevision += 1
        }
    }
    /// Bumped on every key change so views observing it refresh.
    private(set) var apiKeyRevision: Int = 0
    var hasAPIKey: Bool { _ = apiKeyRevision; return !apiKey.isEmpty }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(service: String, account: String, value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)!
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
