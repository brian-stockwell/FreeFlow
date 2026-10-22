import AppKit
import SwiftUI
import Observation

/// The floating pill at the bottom of the screen ("Flow Bar").
/// The panel is a fixed-size, click-through window; only the SwiftUI content animates, which keeps hover
/// expansion smooth and bouncy. Mouse events are accepted only while the pointer is over the visible pill.
@MainActor
final class FlowBarController {
    static let shared = FlowBarController()

    @Observable final class Model {
        var message: String? = nil
        var isError = false
        var doneFlash = false
        var hovering = false
        var processingLabel: String? = nil
    }

    let model = Model()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var hiddenUntil: Date?
    private var contentSize = CGSize(width: 52, height: 14)
    private var pointerTimer: Timer?
    private var hoverStart: Date?
    private var hoverEnd: Date?
    static let panelSize = CGSize(width: 480, height: 72)

    private init() {}

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: FlowBarController.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true   // click-through until the pointer is over the pill
        panel.sharingType = .none
        let host = NSHostingView(rootView: FlowBarView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    func show() {
        guard Settings.shared.showFlowBar else { return }
        if let until = hiddenUntil, until > Date(), DictationController.shared.state == .idle { return }
        if panel == nil { panel = makePanel(); startPointerTracking() }
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func hideForAnHour() {
        hiddenUntil = Date().addingTimeInterval(3600)
        hide()
    }

    func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        contentSize = size
    }

    func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let full = screen.frame
        let size = FlowBarController.panelSize
        panel.setFrame(NSRect(x: full.midX - size.width / 2, y: full.minY, width: size.width, height: size.height), display: true)
    }

    /// Screen rect of the visible pill content (bottom-center of the panel).
    private var pillRect: NSRect {
        guard let panel else { return .zero }
        let f = panel.frame
        return NSRect(x: f.midX - contentSize.width / 2, y: f.minY, width: contentSize.width, height: contentSize.height)
    }

    /// Polls the pointer: toggles click-through and drives hover expansion with small enter/leave delays.
    private func startPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pointerTick() }
        }
    }

    private func pointerTick() {
        guard let panel, panel.isVisible else { return }
        let p = NSEvent.mouseLocation
        let inside = pillRect.insetBy(dx: -4, dy: -3).contains(p)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        let now = Date()
        if inside {
            hoverEnd = nil
            if hoverStart == nil { hoverStart = now }
            if !model.hovering, now.timeIntervalSince(hoverStart!) >= 0.22 { model.hovering = true }
        } else {
            hoverStart = nil
            if model.hovering {
                if hoverEnd == nil { hoverEnd = now }
                if now.timeIntervalSince(hoverEnd!) >= 0.35 { model.hovering = false }
            }
        }
    }

    func clearMessage() {
        hideWork?.cancel()
        model.message = nil
        model.isError = false
        model.doneFlash = false
        model.processingLabel = nil
        show()
    }

    func showProcessing(_ label: String) {
        clearMessage()
        model.processingLabel = label
    }

    func flash(message: String, isError: Bool = false) {
        model.processingLabel = nil
        model.message = message
        model.isError = isError
        show()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.model.message = nil
            self?.model.isError = false
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 2.5), execute: w)
    }

    func flashDone() {
        model.processingLabel = nil
        model.doneFlash = true
        Sounds.play(.done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.model.doneFlash = false }
    }
}

struct FlowBarView: View {
    @Bindable var model: FlowBarController.Model
    private var controller: DictationController { DictationController.shared }
    private var meeting: MeetingRecorder { MeetingRecorder.shared }
    private var detector: MeetingDetector { MeetingDetector.shared }
    @State private var levels: [Float] = Array(repeating: 0.05, count: 14)

    private let timer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    private let bouncy = Animation.spring(response: 0.38, dampingFraction: 0.58, blendDuration: 0.1)

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    FlowBarController.shared.contentSizeChanged(size)
                }
                .animation(bouncy, value: model.hovering)
                .animation(bouncy, value: controller.state)
                .animation(bouncy, value: meeting.isRecording)
                .animation(bouncy, value: meeting.kind)
                .animation(bouncy, value: detector.offerPlatform)
                .animation(.easeInOut(duration: 0.18), value: model.message)
                .animation(.easeInOut(duration: 0.18), value: model.processingLabel)
                .contextMenu {
                    Button("Hide for 1 hour") { FlowBarController.shared.hideForAnHour() }
                    Button("Open FreeFlow") { MainWindowController.shared.show() }
                }
        }
        .frame(width: FlowBarController.panelSize.width, height: FlowBarController.panelSize.height, alignment: .bottom)
        .onReceive(timer) { _ in
            if controller.state == .recording {
                levels.removeFirst()
                levels.append(max(0.05, controller.level))
            }
        }
    }

    // MARK: - States

    @ViewBuilder private var content: some View {
        if let msg = model.message {
            bar {
                HStack(spacing: 6) {
                    Image(systemName: model.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.isError ? .orange : .green)
                    Text(msg).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.white)
                }
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else if let label = model.processingLabel {
            transparentBar {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                }
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else if model.doneFlash {
            bar { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green).frame(width: 36, height: 14) }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            switch controller.state {
            case .idle:
                if meeting.isRecording {
                    recordingMeetingBar.transition(.scale(scale: 0.85).combined(with: .opacity))
                } else if let platform = detector.offerPlatform {
                    offerBar(platform).transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                } else if model.hovering {
                    expandedIdle.transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                } else {
                    collapsedIdle.transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                }
            case .recording:
                transparentBar {
                    HStack(spacing: 8) {
                        Circle().fill(modeColor).frame(width: 6, height: 6)
                        waveform
                        if controller.handsFree {
                            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9)).help("Hands-free: tap Fn or click ✓ to finish")
                            pillButton("checkmark", help: "Done") { controller.finishAndProcess() }
                        }
                    }
                }
                .contentShape(Capsule())
                .onTapGesture { if controller.handsFree { controller.finishAndProcess() } }
                .help(modeLabel)
                .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
            case .processing:
                transparentBar {
                    HStack(spacing: 6) {
                        Circle().fill(modeColor).frame(width: 6, height: 6)
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                }
                .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
            }
        }
    }

    private var collapsedIdle: some View {
        Capsule()
            .fill(Color(white: 0.55).opacity(0.9))
            .frame(width: 40, height: 6)
            .padding(.horizontal, 6)
            .padding(.top, 5)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
            .onTapGesture { controller.beginHandsFree() }
            .help("Hold Fn to dictate • click for hands-free")
    }

    private var expandedIdle: some View {
        bar {
            HStack(spacing: 4) {
                actionButton("mic.fill", "Dictate", tint: .white) { controller.beginHandsFree() }
                divider
                actionButton("record.circle", "Record meeting", tint: .red) { meeting.toggle() }
                divider
                actionButton("note.text", "Scratchpad", tint: .white) { MainWindowController.shared.show(page: .scratchpad, newNote: true) }
                divider
                actionButton("rectangle.and.text.magnifyingglass", "Open", tint: .white) { MainWindowController.shared.show() }
            }
        }
    }

    /// Kept small since it sits on screen for a whole meeting or lecture; the controls appear on hover.
    private var recordingMeetingBar: some View {
        bar(compact: true) {
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Image(systemName: meeting.kind == .lecture ? "graduationcap.fill" : "person.2.fill")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Text(meeting.elapsedString)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white).monospacedDigit()
                if model.hovering {
                    pillButton(meeting.kind == .lecture ? "person.2.fill" : "graduationcap.fill", size: 14,
                               help: "Switch to \(meeting.kind.toggled.label) mode (or tap Control)") { meeting.switchKind() }
                    pillButton("stop.fill", size: 14, help: "Stop recording") { meeting.stop() }
                }
            }
            .frame(height: 14)
        }
        .help(meeting.kind == .lecture ? "Recording lecture" : "Recording meeting")
    }

    private func offerBar(_ platform: String) -> some View {
        bar {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(.red).font(.system(size: 11, weight: .semibold))
                Text("Record \(MeetingDetector.displayName(platform)) meeting?").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                actionButton("checkmark", "Record", tint: .green) { detector.acceptOffer() }
                pillButton("xmark", help: "Not this time") { detector.clearOffer() }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 16)
    }

    private func actionButton(_ icon: String, _ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(FlowBarButtonStyle())
    }

    private func pillButton(_ icon: String, size: CGFloat = 18, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.55, weight: .bold))
                .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).help(help)
    }

    private func bar<Content: View>(compact: Bool = false, @ViewBuilder _ inner: () -> Content) -> some View {
        inner()
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 4 : 7)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func transparentBar<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        inner()
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .frame(width: 3, height: CGFloat(4 + l * 16))
            }
        }
        .frame(height: 20)
    }

    private var modeLabel: String {
        switch controller.mode {
        case .raw: return controller.handsFree ? "RAW • HANDS-FREE" : "RAW"
        case .clean: return controller.handsFree ? "CLEAN • HANDS-FREE" : "CLEAN"
        case .command: return "COMMAND"
        case .transform: return "TRANSFORM"
        }
    }

    private var modeColor: Color {
        switch controller.mode {
        case .raw: return .white.opacity(0.85)
        case .clean: return .cyan
        case .command, .transform: return .orange
        }
    }
}

struct FlowBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.25 : 0.0)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
