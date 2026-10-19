import SwiftUI

/// One selection controls both the default style and the rules shown beneath it.
struct WritingSettingsView: View {
    @State private var choice: WritingStyleChoice
    @State private var showingRules: Bool
    @State private var replacingCustom = false
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard, initiallyShowingRules: Bool = false) {
        self.preferences = preferences
        var saved = WritingStyleChoice.current(preferences)
        saved.defaultID = saved.defaultStyle.id
        _choice = State(initialValue: saved)
        _showingRules = State(initialValue: initiallyShowingRules || !saved.defaultStyle.isPreset)
    }

    var body: some View {
        Form {
            Section {
                Picker("Writing style", selection: $choice.defaultID) {
                    ForEach(choice.styles) { style in
                        Text(style.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty ? "Custom" : style.name).tag(style.id)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(choice.defaultStyle.settingsSummary)
                        .fixedSize(horizontal: false, vertical: true)
                    if choice.defaultStyle.isPreset {
                        Button("Customize…", action: customize)
                            .help("Copy this preset to your custom style and make it the default")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } footer: {
                Text(
                    "Used for new writing unless you request another style, such as “in Blog style”."
                )
            }
            if !choice.defaultStyle.isPreset {
                Section("Custom style") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").font(.callout).foregroundStyle(.secondary)
                        TextField("Name", text: $choice.custom.name)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                DisclosureGroup("Style rules", isExpanded: $showingRules) {
                    if choice.defaultStyle.isPreset {
                        presetRules(choice.defaultStyle)
                    } else {
                        customRules
                    }
                }
            } footer: {
                Text(
                    "Styles change wording and layout, not source access, tools, or grounding checks."
                )
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .onChange(of: choice) { choice.save(preferences) }
        .onChange(of: choice.defaultID) {
            showingRules = !choice.defaultStyle.isPreset
        }
        .confirmationDialog(
            "Replace your custom style?",
            isPresented: $replacingCustom,
            titleVisibility: .visible
        ) {
            Button("Replace Custom Style", role: .destructive) { copySelectedStyle() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You can save one custom style. This replaces its saved rules with a copy of \(choice.defaultStyle.name) and makes that copy the default."
            )
        }
    }

    private func customize() {
        if choice.custom != .starterCustom {
            replacingCustom = true
        } else {
            copySelectedStyle()
        }
    }

    private func copySelectedStyle() {
        choice.customizeDefaultStyle()
        showingRules = true
    }

    private func presetRules(_ style: WritingStyle) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            rule("Tone", value: style.tone)
            rule("Reading level", value: style.readingLevel)
            rule("Structure", value: style.structure)
            rule("Conventions", value: style.conventions)
            rule("Avoid", value: style.avoid)
            rule("Citations", value: style.citations.label)
            rule("Instructions", value: style.instructions)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rule(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customRules: some View {
        VStack(alignment: .leading, spacing: 16) {
            editor("Tone", text: $choice.custom.tone, prompt: "Neutral, conversational, technical")
            editor("Reading level", text: $choice.custom.readingLevel, prompt: "General or expert")
            editor(
                "Structure",
                text: $choice.custom.structure,
                prompt: "How the writing is organized"
            )
            editor(
                "Conventions",
                text: $choice.custom.conventions,
                prompt: "Spelling, units, and dates"
            )
            editor("Avoid", text: $choice.custom.avoid, prompt: "Words or habits to leave out")
            VStack(alignment: .leading, spacing: 6) {
                Text("Citations").font(.callout).foregroundStyle(.secondary)
                Picker("Citations", selection: $choice.custom.citations) {
                    ForEach(WritingStyle.Citations.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize(horizontal: false, vertical: true)
            }
            editor(
                "Instructions",
                text: $choice.custom.instructions,
                prompt: "Additional writing preferences"
            )
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editor(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(prompt), axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
