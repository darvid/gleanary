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
    private(set) var categories: [DecimalCategory] = []
    private(set) var related: [DocumentSummary] = []
    private(set) var coverage: Coverage?
    private(set) var warnings: [String] = []
    private(set) var authorProvider: String?
    private var loadToken = UUID()

    func load(from store: DocumentStore) async {
        guard !Task.isCancelled else { return }
        loadToken = UUID()
        let token = loadToken
        let id = selectedID
        let retainingPreview = document?.id == id && id != nil
        if !retainingPreview {
            document = nil
            citation = nil
            generatedSummary = false
            canGenerateSummary = false
            categories = []; related = []; coverage = nil; warnings = []; authorProvider = nil
        }
        error = nil
        guard let id else { loading = false; return }
        loading = !retainingPreview
        do {
            let loaded = try await store.document(id: id)
            var source: SourceCitation?
            var summary = false
            var eligible = false
            var captured: CapturedDocument?
            if let captureID = try await store.captureID(for: id) {
                let detail = try await store.captureDetail(id: captureID)
                captured = detail.document
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
            let filing = try await store.categories(for: id)
            let linked = try await store.relatedLibraryDocuments(to: id)
            let provider = try await store.libraryAuthorProvider(for: id)
            guard !Task.isCancelled, selectedID == id, loadToken == token else { return }
            citation = source
            generatedSummary = summary
            canGenerateSummary = eligible
            document = loaded
            categories = filing
            related = linked
            coverage = captured?.coverage
            warnings = captured?.warnings ?? []
            authorProvider = provider
            if loaded == nil {
                selectedID = nil
            }
            loading = false
        } catch {
            guard !Task.isCancelled, selectedID == id, loadToken == token else { return }
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
    var showsLibraryDetails = false
    var openDocument: (UUID) -> Void = { _ in }
    var editDocument: ((MarkdownDocument) -> Void)?
    var fileDocument: ((MarkdownDocument) -> Void)?
    var showsSummaryActions = true

    var body: some View {
        if model.loading {
            ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = model.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(document.name).font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    if showsLibraryDetails {
                        libraryMetadata(document)
                    }
                    if model.citation != nil || model.canGenerateSummary || generatingSummary {
                        ViewThatFits(in: .horizontal) {
                            actions(for: document, compact: false)
                            actions(for: document, compact: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .controlSize(.small)
                    }
                    MarkdownPreview(markdown: document.markdown).textSelection(.enabled)
                    if model.generatedSummary, !showsLibraryDetails {
                        Text("Generated with Apple Intelligence. Check the source for details.")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if showsLibraryDetails, !model.related.isEmpty {
                        Divider().padding(.top, 8)
                        Text("From the same sources").font(.headline)
                        ForEach(model.related) { item in
                            Button { openDocument(item.id) } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: item
                                        .kind == "source" ? "doc.text" : "note.text")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).lineLimit(2)
                                        Text(item.kindLabel).font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }.buttonStyle(.borderless).padding(.vertical, 4)
                        }
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

    private func libraryMetadata(_ document: MarkdownDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let coverage = model.coverage {
                Text(coverage.label).font(.callout).foregroundStyle(.secondary)
            }
            if !model.categories.isEmpty {
                Text(model.categories.map(\.label).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let provider = model.authorProvider, provider != "user" {
                Text("Generated with \(provider)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let editDocument {
                    Button("Edit", systemImage: "pencil") { editDocument(document) }
                }
                if let fileDocument {
                    Button(
                        model.categories.isEmpty ? "File…" : "Change filing…",
                        systemImage: "folder"
                    ) { fileDocument(document) }
                }
            }.buttonStyle(.borderless).controlSize(.small)
            if !model.warnings.isEmpty {
                DisclosureGroup("Capture limitations") {
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }.font(.caption)
            }
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
            } else if model.canGenerateSummary, showsSummaryActions {
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
                } else if let rows = Self.tableRows(block) {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        Text(Self.inline(cell))
                                            .fontWeight(index == 0 ? .semibold : .regular)
                                            .frame(width: 150, alignment: .leading)
                                    }
                                }.padding(.vertical, 8)
                                if index < rows.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                } else if block.hasPrefix("#") {
                    let heading = block.prefix(while: { $0 == "#" }).count
                    Text(Self
                        .inline(String(block.dropFirst(heading))
                            .trimmingCharacters(in: .whitespaces)))
                        .font(heading == 1 ? .title2.weight(.semibold) : .headline)
                        .padding(.top, 8).accessibilityAddTraits(.isHeader)
                } else if block.hasPrefix("- ") || block.hasPrefix("* ") || block.hasPrefix("+ ") {
                    HStack(alignment: .top, spacing: 10) {
                        Text("•").accessibilityHidden(true)
                        Text(Self.inline(String(block.dropFirst(2))))
                    }
                } else if block.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil,
                          let marker = block.firstIndex(of: ".")
                {
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(block[...marker])).foregroundStyle(.secondary)
                        Text(Self
                            .inline(String(block[block.index(after: marker)...])
                                .trimmingCharacters(in: .whitespaces)))
                    }
                } else if let quote = Self.quoteText(block) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "quote.opening").font(.caption).accessibilityHidden(true)
                        Text(Self.inline(quote)).lineSpacing(4)
                    }.foregroundStyle(.secondary).padding(.leading, 12)
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
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = code ? rawLine : normalizedBlockLine(rawLine)
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
            } else if isQuoteLine(line) {
                if lines.first.map(isQuoteLine) != true {
                    flush(&lines, into: &blocks)
                }
                lines.append(line)
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
        line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            || line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }

    private nonisolated static func normalizedBlockLine(_ line: String) -> String {
        let leading = line.prefix(while: { $0 == " " }).count
        guard leading <= 3 else { return line }
        let trimmed = String(line.dropFirst(leading))
        return isQuoteLine(trimmed) || standalone(trimmed) || trimmed
            .hasPrefix("```") ? trimmed : line
    }

    private nonisolated static func isQuoteLine(_ line: String) -> Bool {
        line == ">" || line.hasPrefix("> ") || line.hasPrefix(">\t") || line.hasPrefix(">>")
    }

    nonisolated static func quoteText(_ block: String) -> String? {
        guard let first = block.components(separatedBy: "\n").first,
              isQuoteLine(normalizedBlockLine(first)) else { return nil }
        return block.components(separatedBy: "\n").map { line in
            var text = normalizedBlockLine(line)
            while isQuoteLine(text) {
                text.removeFirst()
                if text.first == " " || text.first == "\t" {
                    text.removeFirst()
                }
            }
            return text
        }.joined(separator: "\n")
    }

    nonisolated static func tableRows(_ block: String) -> [[String]]? {
        let lines = block.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].contains("|"),
              lines[1].range(
                  of: #"^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$"#,
                  options: .regularExpression
              ) != nil else { return nil }
        return lines.enumerated().filter { $0.offset != 1 }.map { _, line in
            var cells: [String] = []
            var cell = ""
            var escaped = false
            for character in line {
                if character == "|", !escaped {
                    cells.append(cell); cell = ""
                } else {
                    cell.append(character)
                }
                escaped = character == "\\" && !escaped
            }
            cells.append(cell)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                cells.removeFirst()
            }
            if line.trimmingCharacters(in: .whitespaces).hasSuffix("|") {
                cells.removeLast()
            }
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
