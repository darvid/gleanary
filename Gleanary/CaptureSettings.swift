import SwiftUI

/// What a capture does beyond saving the source's text. Read at capture time, so a change
/// applies to the next capture.
struct CaptureSettings: Sendable, Equatable {
    static let summarizeKey = "captureSummaries"
    static let previewsKey = "capturePreviews"

    /// Writes a brief summary of each saved link. Off keeps the full text; Generate Summary
    /// still works on demand.
    var summarize = true
    /// Fetches page screenshots, share images and video stills for previews. Off makes no
    /// requests for them at all.
    var previews = true

    /// The person's choices; both default to on.
    static func current() -> CaptureSettings {
        let defaults = UserDefaults.standard
        return CaptureSettings(
            summarize: defaults.object(forKey: summarizeKey) as? Bool ?? true,
            previews: defaults.object(forKey: previewsKey) as? Bool ?? true
        )
    }
}

struct CaptureSettingsView: View {
    @AppStorage(CaptureSettings.summarizeKey) private var summarize = true
    @AppStorage(CaptureSettings.previewsKey) private var previews = true

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
        }
        .formStyle(.grouped)
    }
}
