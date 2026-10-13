import Speech
import SwiftUI

struct AudioOptionsView: View {
    let job: CaptureJob
    let library: LibraryModel
    @State private var locales: [Locale] = []
    @State private var modelReady: Bool?
    @State private var selection = "en-US"
    @State private var downloadModel = false
    @State private var error: String?
    @State private var submitting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe locally").font(.title2)
            Text(
                "Infactory will download the video's audio (up to 50 MB / two hours), retain it locally, and generate a timestamped transcript with Apple's on-device speech model. No audio is sent to a transcription service."
            )
            if !locales.isEmpty {
                Picker("Spoken language", selection: $selection) {
                    ForEach(locales, id: \.identifier) { locale in
                        Text(Locale.current
                            .localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
            }
            Text(modelReady
                .map {
                    $0 ? "This speech model is installed." : "This speech model requires a download."
                } ??
                "Checking speech model availability…")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Allow Apple's speech model to download if needed", isOn: $downloadModel)
            Text(
                "Model downloads may be large. Captions are preferred; this option generates new text and can contain recognition errors."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                Spacer()
                Button("Download audio and transcribe") {
                    submitting = true
                    Task {
                        defer { submitting = false }
                        do {
                            try await library.transcribeAudio(
                                job,
                                locale: selection,
                                downloadModel: downloadModel
                            )
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(locales
                        .isEmpty || submitting || modelReady == nil ||
                        (modelReady == false && !downloadModel))
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(submitting)
            .task(id: selection) {
                modelReady = nil
                guard let locale = await SpeechTranscriber
                    .supportedLocale(equivalentTo: Locale(identifier: selection)) else { return }
                let module = SpeechTranscriber(
                    locale: locale,
                    preset: .timeIndexedTranscriptionWithAlternatives
                )
                let ready = await AssetInventory.status(forModules: [module]) == .installed
                guard !Task.isCancelled else { return }
                modelReady = ready
            }
            .task {
                guard SpeechTranscriber.isAvailable
                else { error = MediaError.speechUnavailable.localizedDescription; return }
                locales = await SpeechTranscriber.supportedLocales
                    .sorted { $0.identifier < $1.identifier }
                if let equivalent = await SpeechTranscriber
                    .supportedLocale(equivalentTo: .current)
                {
                    selection = equivalent.identifier
                } else if let first = locales.first {
                    selection = first.identifier
                }
            }
    }
}
