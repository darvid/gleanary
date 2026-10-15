import SwiftUI

/// Settings › Writing: the default style for the Writer, the presets read-only, and one custom
/// style to edit. A request can still name a style ("in Blog style").
struct WritingSettingsView: View {
    @State private var choice = WritingStyleChoice.current()
    @State private var shownID = WritingStyleChoice.current().defaultID

    private var shown: WritingStyle {
        choice.styles.first { $0.id == shownID } ?? choice.defaultStyle
    }

    var body: some View {
        Form {
            Section {
                Picker("Default style", selection: $choice.defaultID) {
                    ForEach(choice.styles) { Text($0.name).tag($0.id) }
                }
                Picker("Details for", selection: $shownID) {
                    ForEach(choice.styles) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text(
                    "Ask for another style in a request, such as “in Blog style”. A style changes wording only, never which sources or tools the Writer uses."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            if shown.isPreset {
                presetSection(shown)
            } else {
                customSection
            }
        }
        .formStyle(.grouped)
        .onChange(of: choice) { choice.save() }
    }

    private func presetSection(_ style: WritingStyle) -> some View {
        Section {
            LabeledContent("Tone", value: style.tone)
            LabeledContent("Reading level", value: style.readingLevel)
            LabeledContent("Structure", value: style.structure)
            LabeledContent("Conventions", value: style.conventions)
            LabeledContent("Avoid", value: style.avoid)
            LabeledContent("Citations", value: style.citations.label)
            LabeledContent("Instructions", value: style.instructions)
        } header: {
            Text(style.name)
        } footer: {
            HStack {
                Text("Presets can't be edited.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Copy to Custom") {
                    var copy = style
                    copy.id = WritingStyle.customID
                    copy.name = "Custom"
                    choice.custom = copy
                    shownID = WritingStyle.customID
                }
            }
        }
    }

    private var customSection: some View {
        Section {
            TextField("Name", text: $choice.custom.name)
            TextField(
                "Tone",
                text: $choice.custom.tone,
                prompt: Text("Neutral, conversational, technical")
            )
            TextField(
                "Reading level",
                text: $choice.custom.readingLevel,
                prompt: Text("Plain language, general, expert")
            )
            TextField(
                "Structure",
                text: $choice.custom.structure,
                prompt: Text("Summary first, tables first, short sections")
            )
            TextField(
                "Conventions",
                text: $choice.custom.conventions,
                prompt: Text("US or UK spelling, units, currency, dates")
            )
            TextField(
                "Avoid",
                text: $choice.custom.avoid,
                prompt: Text("Banned words, marketing tone, emoji")
            )
            Picker("Citations", selection: $choice.custom.citations) {
                ForEach(WritingStyle.Citations.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField(
                "Instructions",
                text: $choice.custom.instructions,
                prompt: Text("Explain jargon on first use"),
                axis: .vertical
            )
            .lineLimit(2 ... 5)
        } header: {
            Text("Custom")
        } footer: {
            Text("Every statement still cites its source, whatever the style asks.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
