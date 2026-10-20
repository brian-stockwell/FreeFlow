import AppKit
import SwiftUI
import Observation

enum Page: String, CaseIterable, Identifiable {
    case home, meetings, scratchpad, dictionary, style, transforms, insights, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .meetings: return "Meetings"
        case .scratchpad: return "Scratchpad"
        case .dictionary: return "Dictionary"
        case .style: return "Style"
        case .transforms: return "Transforms"
        case .insights: return "Insights"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .meetings: return "person.2.wave.2"
        case .scratchpad: return "note.text"
        case .dictionary: return "character.book.closed"
        case .style: return "paintbrush"
        case .transforms: return "wand.and.stars"
        case .insights: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

/// Navigation state shared by the main window.
@Observable
final class Navigation {
    static let shared = Navigation()
    var page: Page = .home
    var newNoteRequested = false
    var selectedMeetingID: String? = nil
}

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show(page: Page? = nil, newNote: Bool = false) {
        if let page {
            Navigation.shared.page = page
        } else if MeetingRecorder.shared.isRecording, let id = MeetingRecorder.shared.currentMeetingID {
            // Opening the app mid-recording goes straight to the live meeting.
            Navigation.shared.page = .meetings
            Navigation.shared.selectedMeetingID = id
        }
        if newNote { Navigation.shared.newNoteRequested = true }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "FreeFlow"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.minSize = NSSize(width: 820, height: 520)
            w.contentView = NSHostingView(rootView: MainWindow())
            w.center()
            w.setFrameAutosaveName("FreeFlowMainWindow")
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            if !Settings.shared.showInDock { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

struct MainWindow: View {
    @Bindable private var nav = Navigation.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.page) {
                ForEach(Page.allCases) { p in
                    Label(p.title, systemImage: p.icon).tag(p)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch nav.page {
            case .home: HomeView()
            case .meetings: MeetingsView()
            case .scratchpad: ScratchpadView()
            case .dictionary: DictionaryView()
            case .style: StyleView()
            case .transforms: TransformsView()
            case .insights: InsightsView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}
