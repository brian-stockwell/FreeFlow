import SwiftUI
import GRDB

@MainActor @Observable
final class TransformsViewModel {
    var transforms: [Transform] = []
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?

    func start() {
        guard cancellable == nil else { return }
        let obs = ValueObservation.tracking { db in
            try Transform.filter(Column("isDeleted") == false).order(Column("sortOrder")).fetchAll(db)
        }
        cancellable = obs.start(in: Database.shared.dbQueue, scheduling: .immediate,
                                onError: { _ in },
                                onChange: { [weak self] rows in
            MainActor.assumeIsolated { self?.transforms = rows }
        })
    }
}

struct TransformsView: View {
    @Bindable var settings = Settings.shared
    @State private var model = TransformsViewModel()
    @State private var editing: Transform?
    @State private var pendingDelete: Transform?
    @State private var confirmReset = false

    private static let maxCustom = 8
    private var customCount: Int { model.transforms.filter { !$0.isBuiltIn }.count }

    var body: some View {
        Form {
            Section {
                Text("Select text and press a transform's hotkey to rewrite it in place. With nothing selected it uses the whole field, or your last dictation (60 s).")
                    .foregroundStyle(.secondary)
                Toggle("Enable transform hotkeys", isOn: $settings.transformsEnabled)
                    .onChange(of: settings.transformsEnabled) { _, _ in TransformController.shared.reloadShortcuts() }
            }

            Section {
                ForEach(model.transforms) { t in row(t) }
                HStack {
                    Button {
                        editing = Transform(name: "", prompt: "", sortOrder: (model.transforms.map(\.sortOrder).max() ?? 0) + 1)
                    } label: { Label("Add custom transform", systemImage: "plus") }
                        .disabled(customCount >= Self.maxCustom)
                    Spacer()
                    Button("Reset built-ins") { confirmReset = true }
                }
                if customCount >= Self.maxCustom {
                    Text("You've reached the limit of \(Self.maxCustom) custom transforms. Delete one to add another.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Transforms") }

            Section {
                ForEach(Settings.polishRuleOrder, id: \.self) { rule in
                    Toggle(rule, isOn: Binding(
                        get: { settings.polishRules[rule] ?? Settings.defaultPolishRules[rule] ?? false },
                        set: { settings.polishRules[rule] = $0 }))
                }
            } header: { Text("Polish rules") }

            Section {
                Picker("Transform", selection: $settings.autoApplyTransformID) {
                    Text("Off").tag(String?.none)
                    ForEach(model.transforms.filter { $0.enabled || $0.id == settings.autoApplyTransformID }) { t in
                        Text(t.name).tag(Optional(t.id))
                    }
                }
            } header: { Text("Auto apply after dictation") } footer: {
                Text("Runs the chosen transform on every Fn+Ctrl cleanup before pasting. Adds about a second.")
            }

            Section {
                LabeledContent("Polish") { hotkeyText("⌥1") }
                LabeledContent("Prompt Engineer") { hotkeyText("⌥2") }
                LabeledContent("Turn into a list") { hotkeyText("⌥3") }
                LabeledContent("Make it concise") { hotkeyText("⌥4") }
                LabeledContent("Fix grammar only") { hotkeyText("⌥5") }
            } header: { Text("Default hotkeys") }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .sheet(item: $editing) { t in
            TransformsEditSheet(transform: t, all: model.transforms) { editing = nil }
        }
        .confirmationDialog("Delete this transform?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { t in
            Button("Delete \"\(t.name)\"", role: .destructive) {
                if settings.autoApplyTransformID == t.id { settings.autoApplyTransformID = nil }
                Database.shared.deleteTransform(id: t.id)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Reset built-in transforms?", isPresented: $confirmReset) {
            Button("Reset built-ins", role: .destructive) { Database.shared.resetBuiltInTransforms() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the names, prompts, hotkeys and enabled state of the built-in transforms. Custom transforms are not changed.")
        }
    }

    private func hotkeyText(_ s: String) -> some View {
        Text(s).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
    }

    private func row(_ t: Transform) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t.name).fontWeight(.medium)
                    if t.isBuiltIn {
                        Text("Built-in").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    shortcutBadge(t)
                }
                Text(preview(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button("Edit") { editing = t }.buttonStyle(.borderless)
            if !t.isBuiltIn {
                Button { pendingDelete = t } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete")
            }
            Toggle("Enabled", isOn: Binding(
                get: { t.enabled },
                set: { v in var c = t; c.enabled = v; Database.shared.saveTransform(c) }))
                .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = t }
    }

    @ViewBuilder private func shortcutBadge(_ t: Transform) -> some View {
        let d = TransformController.display(t.shortcut)
        if d.isEmpty {
            Text("no hotkey").font(.caption).foregroundStyle(.tertiary)
        } else {
            Text(d).font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
        }
    }

    private func preview(_ t: Transform) -> String {
        if t.builtInKey == "polish" { return "Uses the Polish rules below" }
        let one = t.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? t.prompt
        return one.isEmpty ? "No prompt" : one
    }
}
