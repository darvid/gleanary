import Foundation
import SwiftUI

@MainActor @Observable final class DocumentPreviewModel {
    var selectedID: UUID?
    private(set) var document: MarkdownDocument?
    private(set) var citation: SourceCitation?
    private(set) var generatedSummary = false
    private(set) var canGenerateSummary = false
    private(set) var loading = false
    private(set) var error: String?

    func load(from store: DocumentStore) async {
        let id = selectedID
        document = nil
        citation = nil
        generatedSummary = false
        canGenerateSummary = false
        error = nil
        guard let id else { loading = false; return }
        loading = true
        do {
            let loaded = try await store.document(id: id)
            var source: SourceCitation?
            var summary = false
            var eligible = false
            if let captureID = try await store.captureID(for: id) {
                let detail = try await store.captureDetail(id: captureID)
                summary = detail.artifacts.contains {
                    $0.name == "Summary.md" && $0.kind == .markdown &&
                        $0.hash == ContentHash.of(loaded?.markdown ?? "")
                }
                eligible = !summary && detail.document.sourceURL != nil && loaded?
                    .markdown == detail.document.markdown
                source = SourceCitation(
                    captureID: captureID, blockOrdinal: 0, page: detail.document.blocks.first?.page,
                    section: nil, url: detail.document.sourceURL
                )
            }
            guard !Task.isCancelled, selectedID == id else { return }
            citation = source
            generatedSummary = summary
            canGenerateSummary = eligible
            document = loaded
            if loaded == nil {
                selectedID = nil
            }
            loading = false
        } catch {
            guard !Task.isCancelled, selectedID == id else { return }
            self.error = "Could not load this document. Select it again to retry."
            loading = false
        }
    }
}

struct DocumentPreview: View {
    let model: DocumentPreviewModel
    var openSource: (SourceCitation) -> Void = { _ in }
    var summaryEnabled = false
    var generatingSummary = false
    var generateSummary: (MarkdownDocument) -> Void = { _ in }
    var cancelSummary: () -> Void = {}

    var body: some View {
        if model.loading {
            ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = model.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(document.name).font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    if model.citation != nil || model.canGenerateSummary || generatingSummary {
                        ViewThatFits(in: .horizontal) {
                            actions(for: document, compact: false)
                            actions(for: document, compact: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .controlSize(.small)
                    }
                    MarkdownPreview(markdown: document.markdown).textSelection(.enabled)
                    if model.generatedSummary {
                        Text("Generated with Apple Intelligence. Check the source for details.")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .accessibilityLabel("Markdown preview")
        } else {
            ContentUnavailableView(
                model.error == nil ? "Select a document" : "Preview unavailable",
                systemImage: "doc.text",
                description: Text(model
                    .error ??
                    "Read a saved summary or note here. Your original sources stay in your library.")
            )
        }
    }

    private func actions(for document: MarkdownDocument, compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let citation = model.citation {
                Button { openSource(citation) } label: {
                    actionLabel("Captured source", systemImage: "doc.text", compact: compact)
                }
                .buttonStyle(PreviewActionStyle())
                .accessibilityLabel("View captured source")
                .help("View captured source")
                if let url = citation.url {
                    Link(destination: url) {
                        actionLabel(
                            "Original link",
                            systemImage: "arrow.up.right.square",
                            compact: compact
                        )
                    }
                    .buttonStyle(PreviewActionStyle())
                    .accessibilityLabel("Open original link")
                    .help("Open original link in your browser")
                }
            }
            if generatingSummary {
                Button {} label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Generating…")
                    }
                }
                .buttonStyle(PreviewActionStyle(prominent: true))
                .disabled(true)
                .accessibilityLabel("Generating summary")
                Button("Cancel", action: cancelSummary).buttonStyle(PreviewActionStyle())
            } else if model.canGenerateSummary {
                Button("Generate summary") { generateSummary(document) }
                    .buttonStyle(PreviewActionStyle(prominent: true))
                    .disabled(!summaryEnabled)
                    .help(
                        "Summarize the retained source with Apple Intelligence. No download is needed."
                    )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document actions")
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String, compact: Bool) -> some View {
        if compact {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Text(title)
        }
    }
}

private struct PreviewActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let primary = prominent && enabled
        let dark = colorScheme == .dark
        let foreground = dark ? Color.white : Color.black
        let background =
            Color(white: dark ? (configuration.isPressed ? 0.22 : 0.13) :
                (configuration.isPressed ? 0.85 : 0.94))
        let border = Color(white: dark ? 0.42 : 0.56)
        configuration.label
            .font(.callout.weight(prominent ? .medium : .regular))
            .foregroundStyle(primary ? Color.white : foreground.opacity(enabled ? 1 : 0.55))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(primary ? Color.accentColor : background)
                    .brightness(primary ? (configuration.isPressed ? -0.18 : -0.12) : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        primary ? .clear : border,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Render local Markdown as native, selectable text. No scripts or remote images are loaded.
struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("```") {
                    Text(block.components(separatedBy: "\n").dropFirst().dropLast()
                        .joined(separator: "\n"))
                        .font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color(nsColor: .controlBackgroundColor))
                } else if block.hasPrefix("#") {
                    let heading = block.prefix(while: { $0 == "#" }).count
                    Text(Self
                        .inline(String(block.dropFirst(heading))
                            .trimmingCharacters(in: .whitespaces)))
                        .font(heading == 1 ? .title2.weight(.semibold) : .headline)
                        .padding(.top, 8).accessibilityAddTraits(.isHeader)
                } else if block.hasPrefix("- ") || block.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 10) {
                        Text("•").accessibilityHidden(true)
                        Text(Self.inline(String(block.dropFirst(2))))
                    }
                } else {
                    Text(Self.inline(block)).lineSpacing(4)
                }
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated static func blocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var lines: [String] = []
        var code = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if code {
                    lines.append(line)
                    flush(&lines, into: &blocks)
                } else {
                    flush(&lines, into: &blocks)
                    lines.append(line)
                }
                code.toggle()
            } else if code {
                lines.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush(&lines, into: &blocks)
            } else if standalone(line) {
                flush(&lines, into: &blocks)
                blocks.append(line)
            } else {
                lines.append(line)
            }
        }
        if code {
            lines.append("```")
        }
        flush(&lines, into: &blocks)
        return blocks
    }

    private nonisolated static func flush(_ lines: inout [String], into blocks: inout [String]) {
        guard !lines.isEmpty else { return }
        blocks.append(lines.joined(separator: "\n"))
        lines = []
    }

    private nonisolated static func standalone(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
