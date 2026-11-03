import AppKit
import SwiftUI

enum ReadingKind: String, CaseIterable, Identifiable {
    case notes, sources

    init(libraryKind: String) {
        self = libraryKind == "source" ? .sources : .notes
    }

    var id: String {
        rawValue
    }

    var title: String {
        self == .notes ? "Notes" : "Sources"
    }

    var detail: String {
        self == .notes
            ? "Personal notes, summaries, comparisons, and Writer documents."
            : "Captured articles, PDFs, transcripts, and other saved originals."
    }

    var defaultFont: ReadingFont {
        ReadingFont(family: self == .notes ? Self.noteSerif : "", size: 14)
    }

    /// Charter ships with every Mac and was drawn for reading on screens. Athelas, the old
    /// default, is a font macOS downloads on demand, so it can't be relied on.
    static var noteSerif: String {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return ["Charter", "Georgia"].first(where: families.contains) ?? "Georgia"
    }
}

struct ReadingFont: Equatable, Sendable {
    static let sizeRange = 10.0 ... 32.0
    /// Chat replies and messages: the system font a step above macOS's 13pt body, since
    /// they're read as prose rather than scanned like labels.
    static let chat = ReadingFont(family: "", size: 14)
    let family: String
    let size: Double

    init(family: String, size: Double) {
        self.family = family
        self.size = size.isFinite ? min(
            max(size, Self.sizeRange.lowerBound),
            Self.sizeRange.upperBound
        ) : 14
    }

    var readerModeFont: ReadingFont {
        ReadingFont(family: family, size: max(18, size + 2))
    }

    @MainActor var nativeFont: NSFont {
        let system = NSFont.systemFont(ofSize: size)
        guard !family.isEmpty else { return system }
        return NSFontManager.shared
            .font(withFamily: family, traits: [], weight: 5, size: size) ?? system
    }

    @MainActor var font: Font {
        Font(nativeFont)
    }

    @MainActor func scaledFont(_ scale: Double, weight: Font.Weight = .regular) -> Font {
        let base = nativeFont
        let scaled = NSFont(descriptor: base.fontDescriptor, size: size * scale) ?? base
        return Font(scaled).weight(weight)
    }

    /// Whether the family renders, which is what `nativeFont` uses. Fonts macOS loads on
    /// demand render without being listed among installed families.
    @MainActor var available: Bool {
        family.isEmpty || NSFontManager.shared.availableFontFamilies.contains(family)
            || NSFontManager.shared
            .font(withFamily: family, traits: [], weight: 5, size: size) != nil
    }
}

/// AppStorage keeps open readers, editors, and settings in sync without touching saved text.
struct ReadingAppearance: DynamicProperty {
    @AppStorage private var notesFamily: String
    @AppStorage private var notesSize: Double
    @AppStorage private var sourcesFamily: String
    @AppStorage private var sourcesSize: Double

    init(defaults: UserDefaults? = nil) {
        _notesFamily = AppStorage(
            wrappedValue: ReadingKind.notes.defaultFont.family,
            "appearance.notes.fontFamily",
            store: defaults
        )
        _notesSize = AppStorage(
            wrappedValue: ReadingKind.notes.defaultFont.size,
            "appearance.notes.fontSize", store: defaults
        )
        _sourcesFamily = AppStorage(
            wrappedValue: ReadingKind.sources.defaultFont.family,
            "appearance.sources.fontFamily",
            store: defaults
        )
        _sourcesSize = AppStorage(
            wrappedValue: ReadingKind.sources.defaultFont.size,
            "appearance.sources.fontSize", store: defaults
        )
    }

    subscript(kind: ReadingKind) -> ReadingFont {
        get {
            kind == .notes ? ReadingFont(family: notesFamily, size: notesSize)
                : ReadingFont(family: sourcesFamily, size: sourcesSize)
        }
        nonmutating set {
            switch kind {
            case .notes: notesFamily = newValue.family; notesSize = newValue.size
            case .sources: sourcesFamily = newValue.family; sourcesSize = newValue.size
            }
        }
    }
}

struct AppearanceSettingsView: View {
    private var appearance = ReadingAppearance()
    @AppStorage(GraphMarkStyle.key) private var graphMarks = GraphMarkStyle.pages
    private static let families = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    var body: some View {
        Form {
            ForEach(ReadingKind.allCases) { kind in
                Section {
                    fontControls(kind)
                } header: {
                    Text(kind.title)
                } footer: {
                    Text(kind.detail)
                }
            }
            Section {
                Picker("Notes and sources", selection: $graphMarks) {
                    ForEach(GraphMarkStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                GraphDocumentLegend().frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Graph")
            } footer: {
                Text(graphMarks.detail)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func fontControls(_ kind: ReadingKind) -> some View {
        let choice = appearance[kind]
        LabeledContent("Font") {
            FontFamilyPicker(
                family: Binding {
                    appearance[kind].family
                } set: { family in
                    appearance[kind] = ReadingFont(family: family, size: appearance[kind].size)
                },
                families: Self.families,
                available: choice.available,
                accessibilityLabel: "\(kind.title) font"
            )
        }
        Stepper(value: Binding {
            appearance[kind].size
        } set: { size in
            appearance[kind] = ReadingFont(family: appearance[kind].family, size: size)
        }, in: ReadingFont.sizeRange, step: 1) {
            LabeledContent("Size", value: "\(Int(choice.size)) pt")
        }
        .accessibilityLabel("\(kind.title) font size")
        Button("Reset \(kind.title) Font") { appearance[kind] = kind.defaultFont }
            .disabled(choice == kind.defaultFont)
        if !choice.available {
            Text("This font is not installed. Using the system font until it is available.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
