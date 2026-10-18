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
        let serif = NSFont(name: "Athelas", size: 14) != nil ? "Athelas" : "Georgia"
        return ReadingFont(family: self == .notes ? serif : "", size: 14)
    }
}

struct ReadingFont: Equatable, Sendable {
    static let sizeRange = 10.0 ... 32.0
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

    @MainActor var available: Bool {
        family.isEmpty || NSFontManager.shared.availableFontFamilies.contains(family)
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
    private static let families = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    var body: some View {
        Form {
            ForEach(ReadingKind.allCases) { kind in
                Section {
                    fontControls(kind)
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(appearance[kind].font)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .accessibilityLabel("\(kind.title) font preview")
                } header: {
                    Text(kind.title)
                } footer: {
                    Text(kind.detail)
                }
            }
            Section {
                Text(
                    "Applies immediately to document reading and editing. Navigation, controls, and chat keep the system font; code stays monospaced."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func fontControls(_ kind: ReadingKind) -> some View {
        let choice = appearance[kind]
        Picker("Font", selection: Binding {
            appearance[kind].family
        } set: { family in
            appearance[kind] = ReadingFont(family: family, size: appearance[kind].size)
        }) {
            Text("System").tag("")
            Divider()
            if !choice.available {
                Text("\(choice.family) (unavailable)").tag(choice.family)
            }
            ForEach(Self.families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .accessibilityLabel("\(kind.title) font")
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
