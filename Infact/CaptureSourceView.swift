import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension SourceCitation: Identifiable {
    var id: String {
        "\(captureID):\(blockOrdinal)"
    }
}

struct CaptureSourceView: View {
    let citation: SourceCitation
    let library: LibraryModel
    @State private var detail: CaptureDetail?
    @State private var selectedArtifact: String?
    @State private var original: Data?
    @State private var showOriginal = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var artifact: Artifact? {
        detail?.artifacts.first { $0.hash == selectedArtifact }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(detail?.document.title ?? "Capture source").font(.title2).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let detail {
                HStack {
                    Text(detail.document.coverage.label)
                    Text("· \(detail.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let url = citation.url ?? detail.document.sourceURL {
                        Link(
                            citation.startTime
                                .map { "Open at \(MediaTarget.clock($0))" } ?? "Open source",
                            destination: url
                        )
                    }
                }.font(.callout)
                if !detail.document.authors.isEmpty {
                    Text(detail.document.authors.joined(separator: ", ")).font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !detail.document.warnings.isEmpty {
                    DisclosureGroup("Extraction notes (\(detail.document.warnings.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(detail.document.warnings, id: \.self) {
                                    Text($0).font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }
                }
                Picker("View", selection: $showOriginal) {
                    Text("Extracted Markdown").tag(false)
                    Text("Retained original").tag(true)
                }.pickerStyle(.segmented)
                if showOriginal {
                    HStack {
                        Picker("Original", selection: $selectedArtifact) {
                            ForEach(detail.artifacts, id: \.hash) { artifact in
                                Text(artifact.name).tag(Optional(artifact.hash))
                            }
                        }
                        Button("Save original…") { Task { await exportOriginal() } }
                            .disabled(original == nil)
                    }
                    originalView
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(
                                    Array(detail.document.blocks.enumerated()),
                                    id: \.offset
                                ) { ordinal, block in
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let page = block.page {
                                            Text("Page \(page)").font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(Self.preview(block.markdown)).font(.system(
                                            .body,
                                            design: .monospaced
                                        ))
                                        .textSelection(.enabled).frame(
                                            maxWidth: .infinity,
                                            alignment: .leading
                                        )
                                    }.id(ordinal)
                                }
                            }.padding(12)
                        }
                        .onAppear { proxy.scrollTo(citation.blockOrdinal, anchor: .top) }
                    }
                    Text(
                        "Immutable capture, not your editable note. Edits never change this source."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else if error == nil {
                ProgressView("Loading retained source…")
            }
            if let error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(24).frame(minWidth: 650, idealWidth: 820, minHeight: 550, idealHeight: 700)
        .task {
            do {
                let loaded = try await library.captureDetail(citation.captureID)
                detail = loaded
                selectedArtifact = loaded.artifacts.first(where: { $0.kind == .pdf })?
                    .hash ?? loaded.artifacts.first(where: { $0.kind != .capture })?.hash
                showOriginal = citation.page != nil
            } catch { self.error = error.localizedDescription }
        }
        .task(id: selectedArtifact) {
            original = nil
            error = nil
            guard let artifact else { return }
            do {
                let data = try await library.originalData(artifact)
                guard !Task.isCancelled else { return }
                original = data
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder private var originalView: some View {
        if let original, let artifact {
            if artifact.kind == .pdf {
                RetainedPDFView(data: original, page: citation.page)
            } else if artifact.kind == .audio {
                ContentUnavailableView(
                    "Audio retained locally",
                    systemImage: "waveform",
                    description: Text(
                        "Use Save original to listen in your preferred player, or open the source video at the cited timestamp."
                    )
                )
            } else {
                ScrollView {
                    Text(Self.preview((try? IngestionEngine.decodeText(
                        original,
                        encoding: artifact.textEncoding,
                        html: artifact.kind == .html
                    )) ??
                        "Original bytes could not be decoded for preview. Use Save original to inspect the file."))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
        } else {
            ProgressView("Reading original…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func preview(_ text: String) -> String {
        let prefix = text.prefix(100_001)
        guard prefix.count > 100_000 else { return String(prefix) }
        return String(prefix.prefix(
            100_000
        )) + "\n\n[Preview limited to 100,000 characters. Save the original to inspect the complete source.]"
    }

    private func exportOriginal() async {
        guard let artifact, let original else { return }
        let panel = NSSavePanel()
        let suffix = switch artifact.kind {
        case .pdf: "pdf"
        case .html: "html"
        case .markdown: "md"
        case .text: "txt"
        case .capture, .json: "json"
        case .audio: "m4a"
        }
        panel.nameFieldStringValue = artifact.name.hasSuffix("." + suffix) ? artifact
            .name : artifact.name + "." + suffix
        panel.allowedContentTypes = [UTType(filenameExtension: suffix) ?? .data]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { try original.write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}

private struct RetainedPDFView: NSViewRepresentable {
    let data: Data
    let page: Int?

    func makeNSView(context _: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        if let page, let target = view.document?.page(at: page - 1) {
            view.go(to: target)
        }
        return view
    }

    func updateNSView(_: PDFView, context _: Context) {}
}
