import SwiftUI

struct TransformsEditSheet: View {
    let original: Transform
    let all: [Transform]
    let onClose: () -> Void

    @Bindable private var settings = Settings.shared
    @State private var name: String
    @State private var prompt: String
    @State private var shortcut: String

    init(transform: Transform, all: [Transform], onClose: @escaping () -> Void) {
        self.original = transform
        self.all = all
        self.onClose = onClose
        _name = State(initialValue: transform.name)
        _prompt = State(initialValue: transform.prompt)
        _shortcut = State(initialValue: transform.shortcut ?? "")
    }

    private var isPolish: Bool { original.builtInKey == "polish" }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedShortcut: String { shortcut.trimmingCharacters(in: .whitespaces) }
    private var isNew: Bool { !all.contains(where: { $0.id == original.id }) }

    private enum ShortcutState { case none, valid(String), invalid, duplicate(String) }
    private var shortcutState: ShortcutState {
        if trimmedShortcut.isEmpty { return .none }
        guard TransformController.parse(trimmedShortcut) != nil else { return .invalid }
        let norm = TransformController.display(trimmedShortcut)
        if let other = all.first(where: { $0.id != original.id && TransformController.display($0.shortcut) == norm }) {
            return .duplicate(other.name)
        }
        return .valid(norm)
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, trimmedName.count <= 40 else { return false }
        if !isPolish && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        switch shortcutState {
        case .invalid, .duplicate: return false
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                    if trimmedName.count > 40 {
                        Text("Keep the name to 40 characters or fewer.").font(.caption).foregroundStyle(.red)
                    }
                }
                if isPolish {
                    Section {
                        ForEach(Settings.polishRuleOrder, id: \.self) { rule in
                            Toggle(rule, isOn: Binding(
                                get: { settings.polishRules[rule] ?? Settings.defaultPolishRules[rule] ?? false },
                                set: { settings.polishRules[rule] = $0 }))
                        }
                    } header: { Text("Polish rules") }
                } else {
                    Section("Prompt") {
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 140)
                        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("A prompt is required.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    TextField("Shortcut, e.g. opt+6", text: $shortcut)
                        .font(.system(.body, design: .monospaced))
                    switch shortcutState {
                    case .none:
                        Text("Optional. Leave empty for no hotkey.").font(.caption).foregroundStyle(.secondary)
                    case .valid(let d):
                        Text("Shortcut: \(d)").font(.caption).foregroundStyle(.secondary)
                    case .invalid:
                        Text("Use modifier+key, e.g. opt+6").font(.caption).foregroundStyle(.red)
                    case .duplicate(let other):
                        Text("Already used by \(other).").font(.caption).foregroundStyle(.red)
                    }
                } header: { Text("Hotkey") }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 480, height: isPolish ? 560 : 520)
    }

    private func save() {
        var t = original
        t.name = trimmedName
        if !isPolish { t.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
        t.shortcut = trimmedShortcut.isEmpty ? nil : trimmedShortcut.lowercased()
        Database.shared.saveTransform(t)
        onClose()
    }
}
