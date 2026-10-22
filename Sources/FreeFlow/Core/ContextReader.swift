import Foundation
import AppKit
import ApplicationServices

/// What we know about where the text will be inserted.
/// Box so an AXUIElement can ride along in a Sendable struct (we only touch it on the main thread).
final class AXElementBox: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

struct InsertionContext: Sendable {
    var focusedElement: AXElementBox?
    var appBundleID: String?
    var appName: String?
    var pid: pid_t = 0
    var url: String?
    var windowTitle: String?
    var category: AppCategory = .other
    var elementRole: String?
    var isSecureField = false
    var hasFocusedElement = false
    var isEditable = false
    var fieldText: String?          // full contents of the focused field
    var textBefore: String?         // up to ~600 chars before the cursor/selection
    var textAfter: String?          // up to ~300 chars after
    var selectedText: String?
    var selectionRange: NSRange?
    var screenNames: [String] = []  // capitalized words / emails visible in the window

    var fieldIsEmpty: Bool { (fieldText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Reads the frontmost app and focused text field through the Accessibility API.
enum ContextReader {

    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.google.Chrome.canary", "org.chromium.Chromium", "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]

    static func capture(readText: Bool) -> InsertionContext {
        var ctx = InsertionContext()
        guard let app = NSWorkspace.shared.frontmostApplication else { return ctx }
        ctx.appBundleID = app.bundleIdentifier
        ctx.appName = app.localizedName
        ctx.pid = app.processIdentifier

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let focused = focusedElement(appEl, pid: app.processIdentifier, bundleID: app.bundleIdentifier)

        var windowRef: CFTypeRef?
        var window: AXUIElement?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &windowRef) == .success, let w = windowRef {
            window = (w as! AXUIElement)
            ctx.windowTitle = stringAttr(window!, kAXTitleAttribute)
        }

        if let el = focused {
            ctx.hasFocusedElement = true
            ctx.focusedElement = AXElementBox(el)
            ctx.elementRole = stringAttr(el, kAXRoleAttribute)
            let subrole = stringAttr(el, kAXSubroleAttribute)
            ctx.isSecureField = subrole == "AXSecureTextField"
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
            let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
            ctx.isEditable = settable.boolValue || textRoles.contains(ctx.elementRole ?? "")
                || boolAttr(el, "AXEditable") == true
            if readText && !ctx.isSecureField {
                let value = stringAttr(el, kAXValueAttribute) ?? ""
                let limited = String(value.suffix(20_000))
                ctx.fieldText = limited
                ctx.selectedText = stringAttr(el, kAXSelectedTextAttribute)
                if let range = rangeAttr(el, kAXSelectedTextRangeAttribute) {
                    ctx.selectionRange = range
                    let ns = value as NSString
                    let loc = min(range.location, ns.length)
                    let end = min(loc + range.length, ns.length)
                    let beforeStart = max(0, loc - 600)
                    ctx.textBefore = ns.substring(with: NSRange(location: beforeStart, length: loc - beforeStart))
                    let afterLen = min(300, ns.length - end)
                    ctx.textAfter = ns.substring(with: NSRange(location: end, length: afterLen))
                    if ctx.selectedText == nil, range.length > 0 {
                        ctx.selectedText = ns.substring(with: NSRange(location: loc, length: end - loc))
                    }
                } else if !value.isEmpty {
                    ctx.textBefore = String(value.suffix(600))
                }
            }
        }

        // URL for browsers
        if let bid = ctx.appBundleID, browserBundleIDs.contains(bid) {
            ctx.url = findURL(startingAt: focused, window: window)
        }

        ctx.category = classify(bundleID: ctx.appBundleID, appName: ctx.appName, url: ctx.url, title: ctx.windowTitle)

        if readText, let window {
            ctx.screenNames = collectScreenNames(window: window, exclude: focused)
        }
        return ctx
    }

    /// The app's focused element. Chromium and Electron apps (Chrome, Claude, Slack…) build their accessibility tree
    /// lazily and can drop it when idle, so the first query sometimes fails even with a text field focused.
    /// Asking for the tree explicitly and falling back to the system-wide element covers most of those misses.
    static func focusedElement(_ appEl: AXUIElement, pid: pid_t, bundleID: String?) -> AXUIElement? {
        let (el, err) = copyFocused(appEl)
        if let el { return el }
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let el = copyFocused(appEl).element { return el }
        var owner: pid_t = 0
        if let el = copyFocused(AXUIElementCreateSystemWide()).element,
           AXUIElementGetPid(el, &owner) == .success, owner == pid {
            return el
        }
        Log.write("ax: no focused element in \(bundleID ?? "pid \(pid)") (error \(err.rawValue))")
        return nil
    }

    private static func copyFocused(_ el: AXUIElement) -> (element: AXUIElement?, error: AXError) {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXFocusedUIElementAttribute as CFString, &ref)
        guard err == .success, let f = ref, CFGetTypeID(f) == AXUIElementGetTypeID() else { return (nil, err) }
        return ((f as! AXUIElement), err)
    }

    // MARK: - Classification

    static func classify(bundleID: String?, appName: String?, url: String?, title: String?) -> AppCategory {
        let bid = (bundleID ?? "").lowercased()
        let host = url.flatMap { URL(string: $0)?.host?.lowercased() } ?? ""
        let t = (title ?? "").lowercased()
        let custom = Settings.shared.customAppCategories
        for (key, value) in custom {
            let k = key.lowercased()
            if !k.isEmpty, (bid == k || host.hasSuffix(k) || (appName ?? "").lowercased() == k), let c = AppCategory(rawValue: value) {
                return c
            }
        }
        let emailApps = ["com.apple.mail", "com.microsoft.outlook", "com.superhuman.electron", "com.readdle.smartemail-macos",
                         "com.airmail", "com.missiveapp.missive", "com.mimestream.mimestream", "com.freron.mailmate", "com.sparkmailapp",
                         "com.apple.mail.compose", "com.tinyspeck.slackmacgap.mail"]
        let workApps = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.discord",
                        "com.linear", "com.notion.id", "com.atlassian"]
        let personalApps = ["com.apple.mobilesms", "net.whatsapp.whatsapp", "com.facebook.archon", "ru.keepcoder.telegram",
                            "org.whispersystems.signal-desktop", "com.tencent.xinwechat", "com.apple.facetime"]
        let aiApps = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.todesktop.230313mzl4w4u92" /*Cursor*/,
                     "com.exafunction.windsurf", "com.microsoft.vscode", "com.apple.terminal", "com.googlecode.iterm2",
                     "dev.warp.warp-stable", "com.mitchellh.ghostty", "com.google.gemini", "com.perplexity"]
        let docApps = ["com.microsoft.word", "com.apple.iwork.pages", "com.microsoft.powerpoint", "com.apple.iwork.keynote",
                       "com.apple.notes", "md.obsidian", "com.craft", "com.bear-writer", "net.shinyfrog.bear", "com.ulyssesapp.mac",
                       "com.apple.textedit", "abnerworks.typora", "com.google.docs"]
        func any(_ list: [String]) -> Bool { list.contains { bid.hasPrefix($0) } }
        if any(emailApps) { return .email }
        if any(workApps) { return .work }
        if any(personalApps) { return .personal }
        if any(aiApps) { return .ai }
        if any(docApps) { return .documents }

        // Browsers: classify by site
        if !host.isEmpty || browserBundleIDs.contains(bundleID ?? "") {
            if host.contains("mail.google.com") || host.contains("outlook.") || host.contains("mail.superhuman.com")
                || host.contains("mail.yahoo.com") || host.contains("mail.proton.me") || host.contains("fastmail.com")
                || host.contains("hey.com") || t.contains("gmail") || t.contains("outlook") || t.contains("- mail") {
                return .email
            }
            if host.contains("slack.com") || host.contains("teams.microsoft.com") || host.contains("discord.com")
                || host.contains("linear.app") || host.contains("atlassian.net") || t.contains("slack") {
                return .work
            }
            if host.contains("web.whatsapp.com") || host.contains("messenger.com") || host.contains("web.telegram.org")
                || host.contains("instagram.com") || host.contains("x.com") || host.contains("twitter.com") {
                return .personal
            }
            if host.contains("claude.ai") || host.contains("chatgpt.com") || host.contains("chat.openai.com")
                || host.contains("gemini.google.com") || host.contains("perplexity.ai") || host.contains("grok.com")
                || host.contains("copilot.microsoft.com") || t.contains("claude") || t.contains("chatgpt") {
                return .ai
            }
            if host.contains("docs.google.com") || host.contains("notion.so") || host.contains("notion.site")
                || host.contains("coda.io") || host.contains("quip.com") || t.contains("google docs") {
                return .documents
            }
        }
        return .other
    }

    // MARK: - AX helpers

    static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let v = ref else { return nil }
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        if let u = v as? URL { return u.absoluteString }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! URL).absoluteString }
        return nil
    }

    static func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let v = ref else { return nil }
        return (v as? Bool) ?? (v as? NSNumber)?.boolValue
    }

    static func rangeAttr(_ el: AXUIElement, _ attr: String) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let v = ref,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    static func parent(_ el: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &ref) == .success, let p = ref else { return nil }
        return (p as! AXUIElement)
    }

    private static func findURL(startingAt focused: AXUIElement?, window: AXUIElement?) -> String? {
        // Walk up from the focused element looking for a web area with a URL.
        var cur = focused
        var hops = 0
        while let el = cur, hops < 25 {
            if stringAttr(el, kAXRoleAttribute) == "AXWebArea" {
                if let u = stringAttr(el, "AXURL") { return u }
                if let u = stringAttr(el, kAXDocumentAttribute) { return u }
            }
            cur = parent(el); hops += 1
        }
        // Breadth-first from the window (shallow) for a web area.
        if let window {
            var queue = [window]; var seen = 0
            while !queue.isEmpty && seen < 300 {
                let el = queue.removeFirst(); seen += 1
                if stringAttr(el, kAXRoleAttribute) == "AXWebArea" {
                    if let u = stringAttr(el, "AXURL") ?? stringAttr(el, kAXDocumentAttribute) { return u }
                }
                queue.append(contentsOf: children(el))
            }
            if let u = stringAttr(window, kAXDocumentAttribute) { return u }
        }
        return nil
    }

    private static let stopWords: Set<String> = ["The", "This", "That", "These", "Those", "There", "Here", "What", "When", "Where",
        "Who", "Why", "How", "And", "But", "For", "Not", "With", "From", "Your", "You", "Our", "Are", "Was", "Were", "Has", "Have",
        "Had", "Will", "Can", "May", "Just", "New", "All", "Any", "Some", "More", "Most", "Other", "Into", "Over", "Also", "Then",
        "Than", "Only", "Very", "Back", "Next", "Last", "First", "Home", "Search", "Settings", "File", "Edit", "View", "Window", "Help",
        "Send", "Reply", "Forward", "Delete", "Archive", "Compose", "Inbox", "Sent", "Drafts", "Subject", "Today", "Yesterday",
        "Tomorrow", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January", "February", "March",
        "April", "June", "July", "August", "September", "October", "November", "December", "Yes", "Okay", "Cancel", "Done", "Save",
        "Close", "Open", "Share", "Copy", "Paste", "Undo", "Redo", "Select", "Format", "Insert", "Tools", "Message", "Messages",
        "Email", "Chat", "Thread", "Channel", "Direct", "Unread", "Online", "Offline", "Loading", "Error", "Warning", "Note", "Notes",
        "Meeting", "Call", "Video", "Audio", "Mute", "Unmute", "Leave", "Join", "Start", "Stop", "Record", "Recording", "Play",
        "Pause", "Previous", "Page", "Pages", "Tab", "Tabs", "Bookmarks", "History", "Downloads", "Extensions", "Profile", "Account",
        "Sign", "Log", "Out", "Menu", "Toolbar", "Sidebar", "Main", "Content", "Title", "Name", "Date", "Time", "Status", "Type",
        "Size", "None", "Default", "Draft", "Reply", "Everyone", "Someone", "Anyone", "Nothing", "Something", "Everything"]

    /// Collects likely names (capitalized tokens, emails) from visible text in the window. Bounded work.
    static func collectScreenNames(window: AXUIElement, exclude: AXUIElement?) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        var queue = [window]
        var visited = 0
        let deadline = Date().addingTimeInterval(0.15)
        let textAttrs = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        while !queue.isEmpty && visited < 500 && Date() < deadline {
            let el = queue.removeFirst(); visited += 1
            let role = stringAttr(el, kAXRoleAttribute) ?? ""
            if role == "AXMenuBar" || role == "AXToolbar" || role == "AXScrollBar" { continue }
            if let exclude, CFEqual(el, exclude) { continue }
            for attr in textAttrs {
                guard let s = stringAttr(el, attr), !s.isEmpty, s.count < 4000 else { continue }
                extractNames(from: s, into: &names, seen: &seen)
                if names.count >= 60 { return names }
            }
            queue.append(contentsOf: children(el))
        }
        return names
    }

    private static let emailRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

    static func extractNames(from s: String, into names: inout [String], seen: inout Set<String>) {
        for m in emailRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let r = Range(m.range, in: s) {
                let e = String(s[r])
                if seen.insert(e.lowercased()).inserted { names.append(e) }
            }
        }
        let tokens = s.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
        var prevWasSentenceStart = true
        for tok in tokens {
            let w = String(tok)
            defer { prevWasSentenceStart = false }
            guard w.count >= 2, w.count <= 30, let f = w.first, f.isUppercase else { continue }
            if stopWords.contains(w) { continue }
            if w == w.uppercased() && w.count <= 2 { continue }
            // Skip words that only look capitalized because they start a sentence, unless they repeat.
            if prevWasSentenceStart && w.count < 4 { continue }
            if seen.insert(w.lowercased()).inserted { names.append(w) }
        }
    }
}
