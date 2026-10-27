import SwiftUI

/// What a capture does beyond saving the source's text. Read at capture time, so a change
/// applies to the next capture.
struct CaptureSettings: Sendable, Equatable {
    static let summarizeKey = "captureSummaries"
    static let previewsKey = "capturePreviews"
    static let acquisitionKey = "sourceAcquisition"
    static let overridesKey = "sourceAcquisitionOverrides"

    /// Writes a brief summary of each saved link. Off keeps the full text; Generate Summary
    /// still works on demand.
    var summarize = true
    /// Fetches page screenshots, share images and video stills for previews. Off makes no
    /// requests for them at all.
    var previews = true
    /// How eagerly links inside saved sources are followed. Off unless chosen; the app's
    /// own default, Balanced, comes from `current()`.
    var acquisition = SourceAcquisitionLevel.off
    /// Levels for sources filed in particular categories, by category code.
    var overrides: [String: SourceAcquisitionLevel] = [:]

    /// The level for a source whose primary home has this code: its own override, then its
    /// parent category's, then the overall level.
    func acquisition(forCategory code: String?) -> SourceAcquisitionLevel {
        guard let code else { return acquisition }
        if let level = overrides[code] {
            return level
        }
        if let dot = code.firstIndex(of: "."), let level = overrides[String(code[..<dot])] {
            return level
        }
        return acquisition
    }

    /// The person's choices; summaries and previews default to on, acquisition to Balanced.
    static func current() -> CaptureSettings {
        let defaults = UserDefaults.standard
        return CaptureSettings(
            summarize: defaults.object(forKey: summarizeKey) as? Bool ?? true,
            previews: defaults.object(forKey: previewsKey) as? Bool ?? true,
            acquisition: (defaults.object(forKey: acquisitionKey) as? Int)
                .flatMap(SourceAcquisitionLevel.init(rawValue:)) ?? .balanced,
            overrides: ((defaults.dictionary(forKey: overridesKey) as? [String: Int]) ?? [:])
                .compactMapValues(SourceAcquisitionLevel.init(rawValue:))
        )
    }
}

struct CaptureSettingsView: View {
    var store: DocumentStore?
    var categories: [DecimalCategory] = []
    @State private var muted: [String] = []
    @State private var overrides: [String: Int] = [:]
    @AppStorage(CaptureSettings.summarizeKey) private var summarize = true
    @AppStorage(CaptureSettings.previewsKey) private var previews = true
    @AppStorage(CaptureSettings.acquisitionKey) private var acquisition =
        SourceAcquisitionLevel.balanced.rawValue

    private var level: SourceAcquisitionLevel {
        SourceAcquisitionLevel(rawValue: acquisition) ?? .balanced
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $summarize) {
                    Text("Summarize saved links")
                    Text(
                        "Write a brief summary with the AI provider when a link is saved. When off, the full text is saved and Generate Summary still works on any item."
                    )
                }
                Toggle(isOn: $previews) {
                    Text("Save page previews")
                    Text(
                        "Keep a screenshot, the page's share image or a video thumbnail for the library and Atlas. When off, none of these are fetched; existing previews stay."
                    )
                }
            } footer: {
                Text("Changes apply to the next capture.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Follow links in saved sources") {
                        Text(level.title).foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(acquisition) },
                            set: { acquisition = Int($0.rounded()) }
                        ),
                        in: 0 ... Double(SourceAcquisitionLevel.allCases.count - 1),
                        step: 1
                    ) {
                        Text("Follow links in saved sources")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise").accessibilityLabel("Lazy")
                    } maximumValueLabel: {
                        Image(systemName: "hare").accessibilityLabel("Eager")
                    }
                    .labelsHidden()
                    .accessibilityValue(level.title)
                    Text(level.explanation)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !muted.isEmpty {
                    DisclosureGroup("Sites you muted (\(muted.count))") {
                        ForEach(muted, id: \.self) { host in
                            HStack {
                                Text(host)
                                Spacer()
                                Button("Unmute") {
                                    Task {
                                        try? await store?.unmuteAcquisitionHost(host)
                                        await loadMuted()
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                overridesEditor
            } header: {
                Text("Source acquisition")
            } footer: {
                Text(
                    "Following links fetches those pages from this Mac. Social profiles, sign-ups and sponsor links are skipped, and automatic saves skip the AI summary."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await loadMuted()
            overrides = UserDefaults.standard.dictionary(forKey: CaptureSettings.overridesKey)
                as? [String: Int] ?? [:]
        }
    }

    /// Levels for sources filed in a category, overriding the one above.
    @ViewBuilder private var overridesEditor: some View {
        let shown = categories.filter { overrides[$0.code] != nil }
        ForEach(shown) { category in
            HStack {
                Text(category.label).lineLimit(1)
                Spacer()
                Picker("Level for \(category.label)", selection: Binding(
                    get: { overrides[category.code] ?? acquisition },
                    set: { setOverride(category.code, $0) }
                )) {
                    ForEach(SourceAcquisitionLevel.allCases, id: \.rawValue) { level in
                        Text(level.title).tag(level.rawValue)
                    }
                }
                .labelsHidden().fixedSize()
                Button("Remove override for \(category.label)", systemImage: "minus.circle") {
                    setOverride(category.code, nil)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        let available = categories.filter { overrides[$0.code] == nil }
        if !available.isEmpty {
            LabeledContent {
                Menu("Add Category") {
                    ForEach(available) { category in
                        Button(category.label) { setOverride(category.code, acquisition) }
                    }
                }
                .fixedSize()
            } label: {
                Text("Levels for categories")
                Text(
                    "Sources filed there use their own level; subcategories follow their parent's."
                )
            }
        }
    }

    private func setOverride(_ code: String, _ level: Int?) {
        overrides[code] = level
        UserDefaults.standard.set(overrides, forKey: CaptureSettings.overridesKey)
    }

    private func loadMuted() async {
        muted = await (try? store?.mutedAcquisitionHosts()) ?? []
    }
}
