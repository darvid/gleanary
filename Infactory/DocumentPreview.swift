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
    /// Items linked to this one, each with why.
    private(set) var links: [LinkedItem] = []
    private(set) var coverage: Coverage?
    private(set) var warnings: [String] = []
    private(set) var authorProvider: String?
    private(set) var details = LibraryItemDetails()
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
            categories = []; related = []; links = []; coverage = nil; warnings = []
            authorProvider = nil
            details = LibraryItemDetails()
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
            let itemLinks = try await store.linkedItems(for: id)
            let provider = try await store.libraryAuthorProvider(for: id)
            let itemDetails = try await store.libraryItemDetails(for: id)
            guard !Task.isCancelled, selectedID == id, loadToken == token else { return }
            citation = source
            generatedSummary = summary
            canGenerateSummary = eligible
            document = loaded
            categories = filing
            related = linked
            links = itemLinks
            coverage = captured?.coverage
            warnings = captured?.warnings ?? []
            authorProvider = provider
            details = itemDetails
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

/// An item's detail page, modelled on Safari's Reading List and Finder's Get Info: where it came
/// from, what you can do with it, where it's filed, then the text itself. The item's primary
/// category colours the page, as it does in the atlas.
struct DocumentPreview: View {
    let model: DocumentPreviewModel
    var openSource: (SourceCitation) -> Void = { _ in }
    var summaryEnabled = false
    var generatingSummary = false
    var generateSummary: (MarkdownDocument) -> Void = { _ in }
    /// Nil while the summary is written by the bookmark's page fetch, which can't stop here.
    var cancelSummary: (() -> Void)? = {}
    var showsLibraryDetails = false
    /// Progress of the page fetch that will replace this bookmark's note, while it runs.
    var bookmarkFetch: String?
    /// Why the last page fetch for this bookmark failed, until it's tried again.
    var bookmarkFetchFailure: String?
    var retryBookmarkFetch: () -> Void = {}
    var openDocument: (UUID) -> Void = { _ in }
    var editDocument: ((MarkdownDocument) -> Void)?
    /// Archives the item when true, unarchives it when false.
    var archiveDocument: ((MarkdownDocument, Bool) -> Void)?
    var fileDocument: ((MarkdownDocument) -> Void)?
    var showsSummaryActions = true
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool {
        colorScheme == .dark
    }

    private var categoryInk: Color? {
        model.categories.first
            .map { AtlasPalette.ink(AtlasHierarchy.hue(for: $0.code), dark: dark) }
    }

    private var sourceURL: URL? {
        model.details.sourceURL ?? model.citation?.url
    }

    var body: some View {
        if model.loading {
            ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = model.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let data = model.details.previewImage, let image = NSImage(data: data) {
                        hero(image)
                    }
                    header(document)
                    if model.citation != nil || sourceURL != nil || model.canGenerateSummary
                        || generatingSummary
                    {
                        ViewThatFits(in: .horizontal) {
                            actionBar(document, compact: false)
                            actionBar(document, compact: true)
                        }
                    }
                    infoCard(document)
                    VStack(alignment: .leading, spacing: 12) {
                        if let contentTitle {
                            Text(contentTitle).font(.title3.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                        }
                        MarkdownPreview(markdown: document.markdown, font: .system(size: 14))
                            .textSelection(.enabled)
                    }
                    if showsLibraryDetails, !model.links.isEmpty {
                        itemList("Linked", items: model.links.map { ($0.document, $0.rationale) })
                    }
                    if showsLibraryDetails, !model.related.isEmpty {
                        itemList("From the Same Sources", items: model.related.map { ($0, nil) })
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 32).padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .tint(categoryInk)
            .accessibilityLabel("Markdown preview")
            // The fetched page replaces the bookmark's note in place; fade rather than jump.
            .id(document.revision)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: document.revision)
        } else {
            ContentUnavailableView(
                model.error == nil ? "Select a document" : "Preview unavailable",
                systemImage: "doc.text",
                description: Text(model
                    .error ??
                    "Its summary or note opens here.")
            )
        }
    }

    private var contentTitle: String? {
        if model.generatedSummary {
            return "Summary"
        }
        return model.citation == nil ? nil : "Full Text"
    }

    // MARK: Header

    /// The page as it looked when captured. It repeats the title, so VoiceOver skips it.
    private func hero(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: 170, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5)
            }
            .opacity(dark ? 0.9 : 1)
            .accessibilityHidden(true)
    }

    private func header(_ document: MarkdownDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sourceIcon
                Text(sourceLine).lineLimit(1)
                Spacer(minLength: 8)
                if editDocument != nil || fileDocument != nil || archiveDocument != nil
                    || sourceURL != nil
                {
                    moreMenu(document)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(document.name)
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var sourceIcon: some View {
        if let data = model.details.favicon, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
        } else {
            Image(systemName: sourceURL == nil ? "note.text" : "globe").accessibilityHidden(true)
        }
    }

    private var sourceLine: String {
        let host = sourceURL?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let kind = model.coverage?.label ?? (sourceURL == nil ? "Note" : nil)
        return [host, kind].compactMap(\.self).joined(separator: " · ")
    }

    // MARK: Actions

    private func actionBar(_ document: MarkdownDocument, compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let url = model.citation?.url ?? sourceURL {
                Link(destination: url) {
                    actionLabel("Open Original", systemImage: "safari", compact: compact)
                }
                .buttonStyle(.borderedProminent)
                .help("Open the original page in your browser")
            }
            if let citation = model.citation {
                Button { openSource(citation) } label: {
                    actionLabel(
                        "Captured Source",
                        systemImage: "doc.text.magnifyingglass",
                        compact: compact
                    )
                }
                .buttonStyle(.bordered)
                .help("Read the text Infactory captured from the page")
            }
            if generatingSummary {
                SummarizingButton(compact: compact, cancel: cancelSummary)
            } else if model.canGenerateSummary, showsSummaryActions {
                Button { generateSummary(document) } label: {
                    actionLabel("Summarize", systemImage: "sparkles", compact: compact)
                }
                .buttonStyle(.bordered)
                .disabled(!summaryEnabled)
                .help(summaryEnabled ? "Summarize the retained source. No download is needed."
                    : bookmarkFetch != nil ? "Summarized when the page fetch finishes"
                    : "Available once the current library task finishes")
            }
        }
        .controlSize(.large)
        .fixedSize(horizontal: !compact, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document actions")
    }

    private func moreMenu(_ document: MarkdownDocument) -> some View {
        Menu {
            if let editDocument {
                Button("Edit…", systemImage: "pencil") { editDocument(document) }
            }
            if let fileDocument {
                Button(
                    model.categories.isEmpty ? "File…" : "Change Filing…",
                    systemImage: "folder"
                ) { fileDocument(document) }
            }
            if let archiveDocument {
                let archived = model.details.archived != nil
                Button(
                    archived ? "Unarchive" : "Archive",
                    systemImage: archived ? "tray.and.arrow.up" : "archivebox"
                ) { archiveDocument(document, !archived) }
            }
            if let sourceURL {
                Divider()
                Button("Copy Link", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sourceURL.absoluteString, forType: .string)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String, compact: Bool) -> some View {
        if compact {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    // MARK: Info

    /// Get Info–style facts: right-aligned labels, left-aligned values.
    private func infoCard(_ document: MarkdownDocument) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            if let archived = model.details.archived {
                infoRow("Archived") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(archived.formatted(date: .abbreviated, time: .omitted))
                            if let archiveDocument {
                                Button("Unarchive") { archiveDocument(document, false) }
                                    .buttonStyle(.link)
                            }
                        }
                        if let reason = model.details.archiveReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .help("Hidden from the library, Atlas, search and Chat until unarchived.")
                }
            }
            if let bookmarkFetch {
                infoRow("Status") {
                    // One line, so the card doesn't change height as each step reports in.
                    // The same animated symbol as library rows and Captures: it sits on the
                    // text's baseline, which a spinner doesn't.
                    let step = bookmarkFetch.isEmpty ? "Waiting to fetch the page" : bookmarkFetch
                    Label {
                        Text(step)
                            .lineLimit(1).truncationMode(.tail)
                            .fadesOnChange(step)
                    } icon: {
                        Image(systemName: "progress.indicator")
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .foregroundStyle(.secondary)
                    }
                    .help(
                        "Fetching the full page. This bookmark's notes will be replaced by the page and its summary."
                    )
                }
            } else if let bookmarkFetchFailure {
                infoRow("Status") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor).accessibilityHidden(true)
                            Text("Couldn't fetch the page")
                            Button("Try Again", action: retryBookmarkFetch).buttonStyle(.link)
                        }
                        Text(bookmarkFetchFailure).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    .help("The bookmark is kept as it was imported.")
                }
            }
            infoRow("Filed in") { filing(document) }
            if model.generatedSummary, let provider = model.authorProvider {
                infoRow("Summary") {
                    HStack(spacing: 4) {
                        Label(provider, systemImage: "sparkles")
                        Text("(check the source for details)").foregroundStyle(.secondary)
                    }
                }
            } else if let provider = model.authorProvider, provider != "user" {
                infoRow("Written by") { Label(provider, systemImage: "sparkles") }
            } else if model.canGenerateSummary {
                infoRow("Summary") {
                    Text("None yet. The full text is saved.").foregroundStyle(.secondary)
                }
            }
            if let saved = model.details.saved {
                infoRow("Saved") {
                    Text(saved.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if !model.warnings.isEmpty {
                infoRow("Notes") {
                    RowDisclosure(
                        title: "\(model.warnings.count) capture note\(model.warnings.count == 1 ? "" : "s")"
                    ) {
                        ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func filing(_ document: MarkdownDocument) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if model.categories.isEmpty {
                Text("Unfiled").foregroundStyle(.secondary)
            } else {
                ChipFlow(spacing: 6) {
                    ForEach(
                        Array(model.categories.enumerated()),
                        id: \.element.id
                    ) { index, category in
                        CategoryChip(category: category, primary: index == 0)
                    }
                }
            }
            if let fileDocument {
                Button(model.categories.isEmpty ? "File…" : "Change…") { fileDocument(document) }
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: Related

    /// Related items in a card; a link's reason shows in place of the item's kind.
    private func itemList(_ title: String, items: [(DocumentSummary, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.0.id) { index, entry in
                    let (item, reason) = entry
                    if index > 0 {
                        Divider().padding(.leading, 40)
                    }
                    Button { openDocument(item.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.kind == "source" ? "doc.text" : "note.text")
                                .foregroundStyle(.tint).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(2)
                                Text(reason ?? item.kindLabel).font(.caption)
                                    .foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// A category membership in its atlas colour. The primary home is filled; other memberships
/// are outlined.
struct CategoryChip: View {
    let category: DecimalCategory
    var primary = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let slot = AtlasHierarchy.hue(for: category.code)
        let dark = colorScheme == .dark
        let ink = AtlasPalette.ink(slot, dark: dark)
        HStack(spacing: 5) {
            Text(category.code).monospacedDigit().fontWeight(.semibold)
            Text(category.name)
        }
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(ink)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(
            AtlasPalette.fill(slot, dark: dark).opacity(primary ? (dark ? 0.24 : 0.32) : 0.08),
            in: Capsule()
        )
        .overlay { Capsule().strokeBorder(ink.opacity(primary ? 0 : 0.4), lineWidth: 1) }
        .help(primary ? "Primary home" : "Also filed here")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.label)\(primary ? ", primary home" : "")")
    }
}

/// Lays chips out in rows, wrapping when the next one doesn't fit.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat($0.count - 1) }
            .max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +)
            + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()
    ) {
        var y = bounds.minY
        var index = 0
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += (row.map(\.height).max() ?? 0) + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var used: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, used + spacing + size.width > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows
    }
}

/// Render local Markdown as native, selectable text. No scripts or remote images are loaded.
struct MarkdownPreview: View {
    let markdown: String
    var font: Font = .body

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
                        Text("•").foregroundStyle(.tint).accessibilityHidden(true)
                        Text(Self.inline(String(block.dropFirst(2)))).lineSpacing(3)
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
        .font(font)
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

/// A disclosure whose whole label toggles it, as in Finder and System Settings. SwiftUI's
/// default on macOS only responds to the small chevron.
struct RowDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // Disclosure content centres by default; notes read as left-aligned paragraphs.
            VStack(alignment: .leading, spacing: 4) { content() }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Button(title) { expanded.toggle() }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
        }
    }
}

/// Summarize's place while it runs: one button showing progress, with a stop mark that says
/// what a click does, instead of a loose spinner beside a separate Cancel button.
private struct SummarizingButton: View {
    let compact: Bool
    /// Nil shows progress only, for a summary the page fetch is writing.
    let cancel: (() -> Void)?

    var body: some View {
        Button(action: cancel ?? {}) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if !compact {
                    Text("Summarizing…")
                }
                if cancel != nil {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.bordered)
        .allowsHitTesting(cancel != nil)
        .help(cancel == nil ? "Summarizing the fetched page" : "Stop summarizing")
        .accessibilityLabel("Summarizing")
        .accessibilityHint(cancel == nil ? "" : "Stops summarizing")
    }
}
