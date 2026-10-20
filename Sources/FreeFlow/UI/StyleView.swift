import SwiftUI

struct StyleView: View {
    @Bindable var settings = Settings.shared
    @State private var newKey = ""
    @State private var newCategory: AppCategory = .work

    private func examples(_ c: AppCategory) -> String {
        switch c {
        case .email: return "Mail, Gmail, Outlook, Superhuman"
        case .work: return "Slack, Teams, Discord"
        case .personal: return "Messages, WhatsApp, Telegram"
        case .ai: return "Claude, ChatGPT, Cursor, Terminal"
        case .documents: return "Word, Pages, Google Docs, Notion"
        case .other: return "Everything else"
        }
    }

    private func styles(_ c: AppCategory) -> [WritingStyle] {
        switch c {
        case .personal: return [.formal, .casual, .veryCasual]
        default: return [.formal, .casual, .excited]
        }
    }

    private func description(_ s: WritingStyle) -> String {
        switch s {
        case .formal: return "Standard capitalization and punctuation."
        case .casual: return "Lighter punctuation; may drop the final period."
        case .veryCasual: return "Lowercase with minimal punctuation."
        case .excited: return "More exclamation points."
        }
    }

    private func binding(_ c: AppCategory) -> Binding<WritingStyle> {
        Binding(get: {
            let s = settings.style(for: c)
            return styles(c).contains(s) ? s : .casual
        }, set: { settings.setStyle($0, for: c) })
    }

    var body: some View {
        Form {
            Section {
                Text("When you hold Fn+Ctrl, FreeFlow cleans up your words and matches the style to where you're typing.")
                    .foregroundStyle(.secondary)
            }

            ForEach(AppCategory.allCases, id: \.self) { c in
                Section {
                    Text(examples(c)).font(.callout).foregroundStyle(.secondary)
                    Picker("Style", selection: binding(c)) {
                        ForEach(styles(c), id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(description(settings.style(for: c))).font(.caption).foregroundStyle(.secondary)
                } header: { Text(c.displayName).font(.headline) }
                footer: {
                    if c == .ai || c == .documents { Text("Shares one style with Other.") }
                }
            }

            Section {
                Toggle("Add my signature to emails", isOn: $settings.emailSignatureEnabled)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $settings.emailSignature)
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                    if settings.emailSignature.isEmpty {
                        Text("Best,\nAlex").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                TextField("First name", text: $settings.userFirstName)
                TextField("Last name", text: $settings.userLastName)
            } header: { Text("Email signature") }

            Section("Cleanup level") {
                Picker("Cleanup level", selection: $settings.cleanupLevel) {
                    ForEach(CleanupLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                let keys = settings.customAppCategories.keys.sorted()
                if keys.isEmpty {
                    Text("No overrides yet.").foregroundStyle(.secondary)
                }
                ForEach(keys, id: \.self) { k in
                    HStack {
                        Text(k).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { AppCategory(rawValue: settings.customAppCategories[k] ?? "") ?? .other },
                            set: { settings.customAppCategories[k] = $0.rawValue })) {
                            ForEach(AppCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 170)
                        Button { settings.customAppCategories.removeValue(forKey: k) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Bundle id or website domain", text: $newKey).onSubmit(add)
                    Picker("", selection: $newCategory) {
                        ForEach(AppCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                    Button("Add", action: add).disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("App overrides") } footer: {
                Text("Find a bundle id with: osascript -e 'id of app \"Slack\"'")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let k = newKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return }
        settings.customAppCategories[k] = newCategory.rawValue
        newKey = ""
    }
}
