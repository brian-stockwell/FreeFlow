import Foundation
import AppKit
import Carbon.HIToolbox

/// Inserts text into the focused app by pasting (like Wispr), then restores the clipboard.
enum TextInserter {
    private static var savedItems: [NSPasteboardItem] = []
    private static var savedChangeCount = 0
    private static var restoreWork: DispatchWorkItem?

    /// Pastes `text`. Returns false when there is clearly nowhere to paste (text is left on the clipboard).
    /// Accessibility can miss a focused field (Chromium and Electron apps often do), so without one we still paste,
    /// but leave the text on the clipboard in case the paste landed nowhere.
    @MainActor
    static func paste(_ text: String, context: InsertionContext, restoreClipboard: Bool = true) -> Bool {
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        restoreWork?.cancel()
        let restoreLater = restoreClipboard && context.hasFocusedElement
        if restoreLater { snapshot(pb) }
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard context.hasFocusedElement || NSWorkspace.shared.frontmostApplication != nil else { return false }
        // Make sure the target app is frontmost (it should be; we never activate ourselves).
        HotkeyManager.postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        if restoreLater {
            let work = DispatchWorkItem { restore(pb) }
            restoreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        return true
    }

    @MainActor
    static func selectAll() {
        HotkeyManager.postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
    }

    @MainActor
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func snapshot(_ pb: NSPasteboard) {
        savedItems = (pb.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types {
                // Skip huge binary payloads (files, images) – Wispr does the same.
                if let data = item.data(forType: type), data.count < 2_000_000 {
                    copy.setData(data, forType: type); any = true
                }
            }
            return any ? copy : nil
        }
        savedChangeCount = pb.changeCount
    }

    private static func restore(_ pb: NSPasteboard) {
        // If someone else wrote to the clipboard since our paste, leave it alone.
        guard pb.changeCount == savedChangeCount + 1 || pb.string(forType: .string) != nil else { return }
        guard !savedItems.isEmpty else { return }
        pb.clearContents()
        pb.writeObjects(savedItems)
        savedItems = []
    }
}
