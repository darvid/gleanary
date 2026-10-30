import Foundation
import SwiftUI

@MainActor @Observable final class DocumentPreviewModel {
    var selectedID: UUID? {
        didSet {
            if selectedID != oldValue {
                showsCapturedSource = false
                // Opening an automatic save ends its probation.
                if let id = selectedID, let store {
                    Task { try? await store.recordAcquisitionOpened(id) }
                }
            }
        }
    }

    var showsCapturedSource = false
    private(set) var retainedSource: CapturedDocument?
    private(set) var store: DocumentStore?

    var displayedMarkdown: String? {
        showsCapturedSource ? retainedSource?.markdown ?? document?.markdown : document?.markdown
    }

    var identity: DocumentIdentity {
        DocumentIdentity(kind: details.kind, showsCapturedSource: showsCapturedSource)
    }

    var canViewCapturedSource: Bool {
        guard citation != nil, !showsCapturedSource else { return false }
        return details.kind != "source" || document?.markdown != retainedSource?.markdown
    }

    private(set) var document: MarkdownDocument?
    private(set) var citation: SourceCitation?
    private(set) var generatedSummary = false
    private(set) var canGenerateSummary = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var categories: [DecimalCategory] = []
    private(set) var related: [DocumentSummary] = []
    private(set) var sources: [DocumentSummary] = []
    private(set) var summaries: [DocumentSummary] = []
    /// Items linked to this one, each with why.
    private(set) var links: [LinkedItem] = []
    private(set) var coverage: Coverage?
    private(set) var warnings: [String] = []
    private(set) var authorProvider: String?
    private(set) var details = LibraryItemDetails()
    /// Composed by the Writer, so Refresh can re-run its request.
    private(set) var composed = false
    private var loadToken = UUID()

    func load(from store: DocumentStore) async {
        self.store = store
        guard !Task.isCancelled else { return }
        loadToken = UUID()
        let token = loadToken
        let id = selectedID
        let retainingPreview = document?.id == id && id != nil
        if !retainingPreview {
            document = nil
            citation = nil
            retainedSource = nil
            generatedSummary = false
            canGenerateSummary = false
            categories = []; related = []; sources = []; summaries = []
            links = []; coverage = nil; warnings = []
            authorProvider = nil
            details = LibraryItemDetails()
            composed = false
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
                eligible = !summary && loaded?.markdown == detail.document.markdown
                source = SourceCitation(
                    captureID: captureID, blockOrdinal: 0, page: detail.document.blocks.first?.page,
                    section: nil, url: detail.document.sourceURL
                )
            }
            let filing = try await store.categories(for: id)
            let linked = try await store.relatedLibraryDocuments(to: id)
            let provenance = try await store.librarySources(for: id)
            let itemLinks = try await store.linkedItems(for: id)
            let provider = try await store.libraryAuthorProvider(for: id)
            let itemDetails = try await store.libraryItemDetails(for: id)
            let summaries = itemDetails.kind == "source" || showsCapturedSource
                ? try await store.librarySummaries(for: id)
                .filter { showsCapturedSource || $0.id != id } : []
            let featuredIDs = Set((provenance + summaries).map(\.id))
            let isComposed = try await store.isComposedDocument(id)
            guard !Task.isCancelled, selectedID == id, loadToken == token else { return }
            citation = source
            retainedSource = captured
            generatedSummary = summary
            canGenerateSummary = eligible && summaries.isEmpty
            document = loaded
            categories = filing
            sources = provenance
            self.summaries = summaries
            related = linked.filter { !featuredIDs.contains($0.id) }
            links = itemLinks
            coverage = captured?.coverage
            warnings = captured?.warnings ?? []
            authorProvider = provider
            details = itemDetails
            composed = isComposed
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

/// Text-only reading shared by saved notes and immutable captured sources.
struct ReaderTextView: View {
    let title: String
    let markdown: String
    let readingFont: ReadingFont
    var notice: String?
    var notebookBackground = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(readingFont.scaledFont(1.4, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                }
                MarkdownPreview(markdown: markdown, readingFont: readingFont)
            }
            .textSelection(.enabled)
            .frame(maxWidth: 680, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background {
            if notebookBackground {
                NotebookDots()
            }
        }
        .accessibilityLabel("Reader text")
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
    var createAnotherSummary: ((MarkdownDocument) -> Void)?
    @State private var associatingSummary = false
    @State private var confirmingAnotherSummary = false
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
    /// Asks the Librarian where this item belongs; nil where no one can be asked.
    var suggestHome: HomeSuggester?
    /// Removes a home or makes one primary from its chip; nil keeps the chips read-only.
    var editHomes: FilingEditor?
    /// Re-runs a Writer document's request; offered only for composed documents.
    var refreshDocument: ((MarkdownDocument) -> Void)?
    var showsSummaryActions = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.addToChat) private var addToChat
    @Environment(\.isReaderMode) private var readerMode
    @Environment(\.enterReader) private var enterReader
    @Environment(\.libraryGraphContext) private var graphContext
    @Environment(\.linkedSourceContext) private var linkedSourceContext
    @Environment(\.noteWorkspace) private var noteWorkspace
    private var appearance = ReadingAppearance()

    private var readingKind: ReadingKind {
        model.showsCapturedSource ? .sources : ReadingKind(libraryKind: model.details.kind)
    }

    private var readingFont: ReadingFont {
        readerMode ? appearance[readingKind].readerModeFont : appearance[readingKind]
    }

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
            WorkingProgress("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = model.document {
            if readerMode {
                ReaderTextView(
                    title: document.name,
                    markdown: document.markdown,
                    readingFont: readingFont,
                    notice: model.warnings.isEmpty ? nil : model.warnings.joined(separator: " "),
                    notebookBackground: readingKind == .notes
                )
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let data = model.details.previewImage,
                               let image = NSImage(data: data)
                            {
                                hero(image)
                            }
                            header(document)
                            if model.citation != nil || sourceURL != nil || model.canGenerateSummary
                                || generatingSummary || addToChat != nil
                            {
                                ViewThatFits(in: .horizontal) {
                                    actionBar(document, compact: false)
                                    actionBar(document, compact: true)
                                }
                            }
                            infoCard(document)
                            Divider()
                            VStack(alignment: .leading, spacing: 12) {
                                if contentTitle != nil || (enterReader != nil && !readerMode) {
                                    HStack(alignment: .firstTextBaseline) {
                                        if let contentTitle {
                                            Text(contentTitle)
                                                .font(readingFont.scaledFont(
                                                    17.0 / 14,
                                                    weight: .semibold
                                                ))
                                                .accessibilityAddTraits(.isHeader)
                                        }
                                        Spacer()
                                        if model.showsCapturedSource,
                                           let citation = model.citation
                                        {
                                            ReaderModeButton(target: .source(citation.captureID))
                                        } else {
                                            ReaderModeButton(target: .note(document.id))
                                        }
                                    }
                                }
                                MarkdownPreview(
                                    markdown: model.displayedMarkdown ?? document.markdown,
                                    readingFont: readingFont
                                )
                                .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Document content")
                            if !model.showsCapturedSource, let noteWorkspace {
                                NoteWorkspaceSection(
                                    document: document,
                                    workspace: noteWorkspace,
                                    openNote: openDocument
                                )
                            }
                            if readingKind == .notes, let linkedSourceContext {
                                LinkedSourcesView(
                                    document: document, context: linkedSourceContext,
                                    openDocument: openDocument
                                ).id(document.id).padding(.top, 12)
                            }
                            if let graphContext, model.details.archived == nil {
                                NoteConnectionsView(
                                    noteID: document.id, store: graphContext.store,
                                    refreshToken: graphContext.refreshToken,
                                    explore: graphContext.explore, openNote: openDocument,
                                    openSource: openSource
                                ).padding(.top, 12)
                            }
                            if showsLibraryDetails,
                               graphContext == nil || model.details.archived != nil,
                               !model.links.isEmpty
                            {
                                itemList(
                                    "Linked",
                                    items: model.links.map { ($0.document, $0.rationale) }
                                )
                            }
                            if showsLibraryDetails, !model.related.isEmpty {
                                itemList(
                                    "Other notes from these sources",
                                    items: model.related.map { ($0, nil) }
                                )
                            }
                        }
                        // A vertical scroll view must not inherit the image or metadata's ideal
                        // width.
                        .frame(
                            width: min(readingMeasure, max(0, viewport.size.width - 64)),
                            alignment: .leading
                        )
                        .padding(.horizontal, 32).padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .tint(categoryInk)
                    .accessibilityLabel("Markdown preview")
                    // The fetched page replaces the bookmark's note in place; fade rather than
                    // jump.
                    .id(document.revision)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: document.revision)
                }
            }
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

    /// Roughly 65–75 characters a line at the reading size, so text never runs the width of a
    /// wide pane.
    private var readingMeasure: CGFloat {
        min(760, max(520, readingFont.size * 36))
    }

    private var contentTitle: String? {
        if model.showsCapturedSource {
            return "Full Text"
        }
        if model.generatedSummary {
            return "Summary"
        }
        return model.citation == nil ? nil : "Full Text"
    }

    // MARK: Header

    /// The page as it looked when captured. It repeats the title, so VoiceOver skips it.
    private func hero(_ image: NSImage) -> some View {
        GeometryReader { viewport in
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: viewport.size.width, height: 170, alignment: .top)
                .clipped()
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5)
        }
        .opacity(dark ? 0.9 : 1)
        .accessibilityHidden(true)
    }

    private func header(_ document: MarkdownDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                DocumentIdentityLabel(identity: model.identity).layoutPriority(1)
                if !sourceMetadata.isEmpty {
                    HStack(spacing: 8) {
                        sourceIcon
                        ForEach(Array(sourceMetadata.enumerated()), id: \.offset) { _, value in
                            Text(value).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                if editDocument != nil || fileDocument != nil || archiveDocument != nil
                    || model
                    .citation != nil || sourceURL != nil ||
                    (refreshDocument != nil && model.composed)
                {
                    moreMenu(document)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(model.showsCapturedSource ? model.retainedSource?.title ?? document.name : document
                .name)
                .font(readingFont.scaledFont(22.0 / 14, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if !model.sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.sources.count == 1 ? "Source" : "Sources")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.sources) { source in
                        Button { (linkedSourceContext?.viewSource ?? openDocument)(source.id)
                        } label: {
                            Label(source.name, systemImage: "doc.text")
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.link).font(.callout)
                        .accessibilityLabel("Source: \(source.name)")
                        .help("Open the saved source in Library")
                    }
                }
            }
        }
    }

    @ViewBuilder private var sourceIcon: some View {
        if let data = model.details.favicon, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
        }
    }

    private var sourceMetadata: [String] {
        let host = sourceURL?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let kind = model.identity.isSource ? model.coverage?.label : nil
        return [host, kind].compactMap(\.self)
    }

    // MARK: Actions

    private func actionBar(_ document: MarkdownDocument, compact: Bool) -> some View {
        HStack(spacing: 8) {
            if model.canViewCapturedSource || !model.summaries.isEmpty {
                SourceSummaryNavigation(
                    summaries: model.summaries, compact: compact,
                    showsSource: model.canViewCapturedSource, openSummary: openSummary,
                    viewSource: { model.showsCapturedSource = true }
                ).buttonStyle(.bordered)
            }
            if let url = model.citation?.url ?? sourceURL {
                Link(destination: url) {
                    actionLabel("Open Original", systemImage: "safari", compact: compact)
                }
                .buttonStyle(.bordered)
                .help("Open the original page in your browser")
            }
            AddToChatButton(target: .note(document.id), compact: compact)
            if generatingSummary {
                SummarizingButton(cancel: cancelSummary)
            } else if model.canGenerateSummary, model.summaries.isEmpty, showsSummaryActions {
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
        .sheet(isPresented: $associatingSummary) {
            if let store = model.store {
                SummaryAssociationView(store: store, sourceID: document.id) {
                    await linkedSourceContext?.changed()
                    await model.load(from: store)
                }
            }
        }
        .confirmationDialog("Create another summary?", isPresented: $confirmingAnotherSummary) {
            Button("Create Summary") { createAnotherSummary?(document) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This creates a new note from the retained source using the selected AI provider. Existing notes and source data stay unchanged."
            )
        }
    }

    private func openSummary(_ id: UUID) {
        model.showsCapturedSource = false
        openDocument(id)
    }

    private func moreMenu(_ document: MarkdownDocument) -> some View {
        Menu {
            if model.citation != nil {
                Button("Use as Summary for This Source…", systemImage: "note.text.badge.plus") {
                    associatingSummary = true
                }
                if createAnotherSummary != nil, !model.summaries.isEmpty || model.generatedSummary {
                    Button("Create Another Summary…", systemImage: "sparkles") {
                        confirmingAnotherSummary = true
                    }.disabled(!summaryEnabled || generatingSummary)
                }
                Divider()
            }
            if let editDocument, !model.showsCapturedSource {
                Button("Edit…", systemImage: "pencil") { editDocument(document) }
            }
            if let refreshDocument, model.composed {
                Button("Refresh Document", systemImage: "arrow.triangle.2.circlepath") {
                    refreshDocument(document)
                }
                .help("Gather again, re-read new or changed sources and review the changes")
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

    /// Filing leads, since it's the fact you act on; status that needs attention stays visible;
    /// who wrote it and when sit in a collapsed Details row.
    private func infoCard(_ document: MarkdownDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FilingRow(
                document: document, categories: model.categories,
                change: fileDocument.map { change in { change(document) } },
                suggester: suggestHome, editor: editHomes
            )
            .id(document.id)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filing")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                statusRows(document)
            }
            if hasDetails {
                RowDisclosure(title: detailsTitle) {
                    Grid(
                        alignment: .leadingFirstTextBaseline,
                        horizontalSpacing: 14, verticalSpacing: 8
                    ) {
                        detailRows
                    }
                    .padding(.top, 6)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func statusRows(_ document: MarkdownDocument) -> some View {
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
                // One line, so the row doesn't change height as each step reports in.
                // The same animated symbol as library rows and Captures: it sits on the
                // text's baseline, which a spinner doesn't.
                let step = bookmarkFetch
                    .isEmpty ? "Waiting to fetch the page" : bookmarkFetch
                Label {
                    Text(step)
                        .lineLimit(1).truncationMode(.tail)
                        .fadesOnChange(step)
                } icon: {
                    ChatWorkingIndicator(color: .secondary)
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
    }

    @ViewBuilder private var detailRows: some View {
        if model.generatedSummary, !model.showsCapturedSource,
           let provider = model.authorProvider
        {
            infoRow("Summary") {
                HStack(spacing: 4) {
                    Label(provider, systemImage: "sparkles")
                    Text("(check the source for details)")
                        .foregroundStyle(.secondary)
                }
            }
        } else if let provider = model.authorProvider, provider != "user",
                  !model.showsCapturedSource
        {
            infoRow("Written by") { Label(provider, systemImage: "sparkles") }
        } else if model.canGenerateSummary, model.summaries.isEmpty {
            infoRow("Summary") {
                HStack {
                    Text("No summary associated.").foregroundStyle(.secondary)
                    Button("Use Existing Note…") { associatingSummary = true }
                        .buttonStyle(.link)
                }
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
                    ForEach(
                        Array(model.warnings.enumerated()),
                        id: \.offset
                    ) { _, warning in
                        Text(warning).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var hasDetails: Bool {
        model.authorProvider != nil && !model.showsCapturedSource
            || model.canGenerateSummary && model.summaries.isEmpty
            || model.details.saved != nil || !model.warnings.isEmpty
    }

    /// The saved date, so the collapsed row still says when.
    private var detailsTitle: String {
        model.details.saved.map {
            "Saved \($0.formatted(date: .abbreviated, time: .omitted))"
        } ?? "Details"
    }

    private func infoRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Related

    /// Related items in a card; a link's reason shows in place of the item's kind.
    private func itemList(_ title: String, items: [(DocumentSummary, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
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
        let height = rows.map(rowHeight).reduce(0, +)
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
            let baseline = rowBaseline(row)
            for dimensions in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + baseline - dimensions[.firstTextBaseline]),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: dimensions.width, height: dimensions.height)
                )
                x += dimensions.width + spacing
                index += 1
            }
            y += rowHeight(row) + spacing
        }
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal _: ProposedViewSize,
        subviews: Subviews, cache _: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline else { return nil }
        return rows(width: bounds.width, subviews: subviews).first.map(rowBaseline)
    }

    private func rowBaseline(_ row: [ViewDimensions]) -> CGFloat {
        row.map { $0[.firstTextBaseline] }.max() ?? 0
    }

    private func rowHeight(_ row: [ViewDimensions]) -> CGFloat {
        rowBaseline(row) + (row.map { $0.height - $0[.firstTextBaseline] }.max() ?? 0)
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [[ViewDimensions]] {
        var rows: [[ViewDimensions]] = [[]]
        var used: CGFloat = 0
        for subview in subviews {
            let size = subview.dimensions(in: ProposedViewSize(width: width, height: nil))
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

/// A repeating tile keeps drawing cost independent of the note's length.
private struct NotebookDots: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private static let lightTile = makeTile(dark: false)
    private static let darkTile = makeTile(dark: true)

    private static func makeTile(dark: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            (dark ? NSColor.white : .black).setFill()
            NSBezierPath(ovalIn: NSRect(x: 9.4, y: 9.4, width: 1.2, height: 1.2)).fill()
            return true
        }
    }

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(nsImage: colorScheme == .dark ? Self.darkTile : Self
                    .lightTile)))
            .opacity(contrast == .increased ? 0 : colorScheme == .dark ? 0.10 : 0.08)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Render local Markdown as native, selectable text. No scripts or remote images are loaded.
struct MarkdownPreview: View {
    let markdown: String
    var font: Font = .body
    var readingFont: ReadingFont?
    /// Fades in the end of the last block while a reply streams.
    var trailingFade: TrailingFade?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tintedCategories) private var tintedCategories

    var body: some View {
        let blocks = Self.blocks(markdown)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let fade = index == blocks.count - 1 ? trailingFade : nil
                if let latex = MathMarkdown.displayFormula(block) {
                    MathBlock(latex: latex, size: nativeFont().pointSize)
                } else if block.hasPrefix("```") {
                    fading(Text(block.components(separatedBy: "\n").dropFirst().dropLast()
                            .joined(separator: "\n")), fade)
                        .font(readingFont
                            .map { .system(size: $0.size, design: .monospaced) } ?? .body
                            .monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color(nsColor: .controlBackgroundColor))
                } else if let rows = Self.tableRows(block) {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        inlineText(
                                            cell,
                                            nativeFont: nativeFont(weight: index == 0 ? .semibold :
                                                .regular)
                                        )
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
                    inlineText(
                        String(block.dropFirst(heading)).trimmingCharacters(in: .whitespaces),
                        nativeFont: nativeFont(
                            scale: readingFont == nil ? 1 : (heading == 1 ? 17.0 / 14 : 1),
                            style: heading == 1 ? .title2 : .headline, weight: .semibold
                        ),
                        fade: fade
                    )
                    .font(readingFont?.scaledFont(
                        heading == 1 ? 17.0 / 14 : 1,
                        weight: .semibold
                    )
                        ?? (heading == 1 ? .title2.weight(.semibold) : .headline))
                    .padding(.top, 8).accessibilityAddTraits(.isHeader)
                } else if block.hasPrefix("- ") || block.hasPrefix("* ") || block.hasPrefix("+ ") {
                    HStack(alignment: .top, spacing: 10) {
                        Text("•").foregroundStyle(.tint).accessibilityHidden(true)
                        inlineText(String(block.dropFirst(2)), lineSpacing: 3, fade: fade)
                            .lineSpacing(3)
                    }
                } else if block.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil,
                          let marker = block.firstIndex(of: ".")
                {
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(block[...marker])).foregroundStyle(.secondary)
                        inlineText(
                            String(block[block.index(after: marker)...])
                                .trimmingCharacters(in: .whitespaces),
                            fade: fade
                        )
                    }
                } else if let quote = Self.quoteText(block) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "quote.opening").font(.caption).accessibilityHidden(true)
                        inlineText(quote, lineSpacing: 4, color: .secondaryLabelColor, fade: fade)
                            .lineSpacing(4)
                    }.foregroundStyle(.secondary).padding(.leading, 12)
                } else {
                    inlineText(block, lineSpacing: 4, fade: fade).lineSpacing(4)
                }
            }
        }
        .font(readingFont?.font ?? font)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated static func blocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var lines: [String] = []
        var code = false
        var math = false
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = code || math ? rawLine : normalizedBlockLine(rawLine)
            if !code, displayMath(line, open: &math, lines: &lines, blocks: &blocks) {
                continue
            } else if line.hasPrefix("```") {
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

    /// A display formula is a block of its own, even inside a paragraph. Returns whether the
    /// line belonged to one.
    private nonisolated static func displayMath(
        _ line: String, open: inout Bool, lines: inout [String], blocks: inout [String]
    ) -> Bool {
        if open {
            lines.append(line)
            if MathMarkdown.closesDisplay(line) {
                flush(&lines, into: &blocks)
                open = false
            }
            return true
        }
        let whole = MathMarkdown.displayFormula(line) != nil
        guard whole || MathMarkdown.opensDisplay(line) else { return false }
        flush(&lines, into: &blocks)
        lines.append(line)
        open = !whole
        if whole {
            flush(&lines, into: &blocks)
        }
        return true
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

    @ViewBuilder private func inlineText(
        _ source: String, nativeFont: NSFont? = nil, lineSpacing: CGFloat = 0,
        color: NSColor = .labelColor, fade: TrailingFade? = nil
    ) -> some View {
        let (text, formulas) = tintedInline(source)
        let font = nativeFont ?? self.nativeFont()
        // Linked text is AppKit-drawn, so it streams in without the fade.
        if text.runs.contains(where: { $0.link != nil }) {
            MarkdownLinkText(
                text: text, font: font, color: color, lineSpacing: lineSpacing,
                formulas: formulas
            )
        } else {
            fading(MathMarkdown.text(
                text, formulas: formulas, size: font.pointSize,
                secondary: color == .secondaryLabelColor, dark: colorScheme == .dark
            ), fade)
        }
    }

    @ViewBuilder private func fading(_ text: Text, _ fade: TrailingFade?) -> some View {
        if let fade {
            text.textRenderer(fade)
        } else {
            text
        }
    }

    private func nativeFont(
        scale: Double = 1, style: NSFont.TextStyle? = nil, weight: NSFont.Weight = .regular
    ) -> NSFont {
        let base = readingFont?.nativeFont
            ?? NSFont.preferredFont(forTextStyle: style ?? (font == .callout ? .callout : .body))
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: base.pointSize * scale) ?? base
    }

    private func tintedInline(_ source: String) -> (AttributedString, [MathMarkdown.Formula]) {
        var (text, formulas) = Self.inline(source)
        if !tintedCategories.isEmpty {
            Self.tintCategories(
                in: &text, categories: tintedCategories, dark: colorScheme == .dark
            )
        }
        return (text, formulas)
    }

    /// Colors bold or code spans that name a category with that category's ink, as filing tags
    /// do, so a reply's mention of a home reads as the same thing.
    static func tintCategories(
        in text: inout AttributedString, categories: [DecimalCategory], dark: Bool
    ) {
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            guard intent.contains(.stronglyEmphasized) || intent.contains(.code),
                  run.link == nil else { continue }
            let span = String(text[run.range].characters)
                .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            guard let category = category(named: span, in: categories) else { continue }
            let ink = AtlasPalette.ink(AtlasHierarchy.hue(for: category.code), dark: dark)
            text[run.range].foregroundColor = ink
            text[run.range].appKit.foregroundColor = NSColor(ink)
            // A code span named a category, not code: drop the monospaced face.
            if intent.contains(.code) {
                text[run.range].inlinePresentationIntent = intent.subtracting(.code)
                    .union(.stronglyEmphasized)
            }
        }
    }

    nonisolated static func category(
        named span: String, in categories: [DecimalCategory]
    ) -> DecimalCategory? {
        guard !span.isEmpty else { return nil }
        return categories.first {
            span.caseInsensitiveCompare($0.label) == .orderedSame
                || span.caseInsensitiveCompare($0.name) == .orderedSame
                || span == $0.code
        }
    }

    private static func inline(_ source: String) -> (AttributedString, [MathMarkdown.Formula]) {
        let (text, formulas) = MathMarkdown.extractingInline(source)
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        return (parsed, formulas)
    }
}

extension EnvironmentValues {
    /// Categories whose names are tinted where Markdown bolds them; empty outside Chat.
    @Entry var tintedCategories: [DecimalCategory] = []
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
/// It keeps its words even where other actions are icons: a dot alone doesn't say what's
/// happening.
private struct SummarizingButton: View {
    /// Nil shows progress only, for a summary the page fetch is writing.
    let cancel: (() -> Void)?

    var body: some View {
        Button(action: cancel ?? {}) {
            HStack(spacing: 6) {
                ChatWorkingIndicator(color: .secondary)
                Text("Summarizing…")
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

/// Changes an item's homes from their chips; each returns the homes before, for Undo.
struct FilingEditor {
    let remove: (UUID, DecimalCategory) async throws -> [FilingMembership]
    let makePrimary: (UUID, DecimalCategory) async throws -> [FilingMembership]
    let restore: (UUID, [FilingMembership]) async throws -> Void
}

/// How an item's info card asks the Librarian for a home, files it there and undoes that.
struct HomeSuggester {
    let suggest: (UUID) async throws -> HomeSuggestion?
    /// Returns the applied changes, for Undo.
    let file: (UUID, HomeSuggestion) async throws -> [UUID]
    let undo: ([UUID]) async throws -> Void
    /// Adds a secondary home; false when it was already there.
    let addHome: (UUID, DecimalCategory) async throws -> Bool
    let removeHome: (UUID, DecimalCategory) async throws -> Void
}

/// The item's homes with Change… and Suggest. Suggest asks the Librarian and shows its answer
/// inline; nothing changes until File Here, and Undo puts the old filing back.
private struct FilingRow: View {
    enum Step {
        case idle, asking
        case suggested(HomeSuggestion)
        case filed(HomeSuggestion, [UUID])
        /// A home removed or made primary from its chip, with the homes before for Undo.
        case edited(String, [FilingMembership])
        case failed(String)
    }

    let document: MarkdownDocument
    let categories: [DecimalCategory]
    let change: (() -> Void)?
    let suggester: HomeSuggester?
    var editor: FilingEditor?
    @State private var step = Step.idle
    @State private var hovered: UUID?
    /// Secondary homes added from "Also fits", so each can be undone.
    @State private var added: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChipFlow(spacing: 8) {
                if categories.isEmpty {
                    Text("Unfiled").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, home in
                        chip(home, primary: index == 0)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let change {
                        Button(categories.isEmpty ? "File…" : "Change…", action: change)
                            .buttonStyle(.link)
                    }
                    if suggester != nil, case .idle = step {
                        Button { ask() } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Image(systemName: "sparkles").imageScale(.small)
                                    .accessibilityHidden(true)
                                Text("Suggest")
                            }
                        }
                        .buttonStyle(.link)
                        .help("Ask the Librarian for the best home")
                    }
                }.fixedSize(horizontal: true, vertical: false)
            }
            answer
        }
    }

    @ViewBuilder private var answer: some View {
        switch step {
        case .idle: EmptyView()
        case .asking:
            Label {
                Text("Asking the Librarian…")
            } icon: {
                ChatWorkingIndicator(color: .secondary)
            }
            .font(.callout).foregroundStyle(.secondary)
        case let .suggested(suggestion):
            suggestionCard(suggestion)
        case let .filed(suggestion, ids):
            HStack(spacing: 8) {
                Text("Filed in \(suggestion.category?.label ?? "the suggested home").")
                    .foregroundStyle(.secondary)
                Button("Undo") { undo(ids) }.buttonStyle(.link)
            }
            .font(.callout)
        case let .edited(message, before):
            HStack(spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button("Undo") { restore(before) }.buttonStyle(.link)
            }
            .font(.callout)
        case let .failed(message):
            HStack(spacing: 8) {
                Text(message).foregroundStyle(.secondary).fixedSize(
                    horizontal: false,
                    vertical: true
                )
                Button("Dismiss") { step = .idle }.buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private func suggestionCard(_ suggestion: HomeSuggestion) -> some View {
        let current = categories.first?.id == suggestion.category?.id && !suggestion.isNew
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
                if let home = suggestion.category {
                    CategoryChip(category: home)
                    if suggestion.isNew {
                        NewCategoryBadge()
                    }
                } else {
                    Text("No home fits yet").foregroundStyle(.secondary)
                }
            }
            if !suggestion.rationale.isEmpty {
                Text(suggestion.rationale).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !suggestion.alsoFits.isEmpty {
                alsoFits(suggestion.alsoFits)
            }
            HStack(spacing: 12) {
                if current {
                    Text("It's already filed here.").font(.callout).foregroundStyle(.secondary)
                } else if suggestion.category != nil {
                    Button(suggestion.isNew ? "Create and File Here" : "File Here") {
                        file(suggestion)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button("Dismiss") { step = .idle }.buttonStyle(.link).font(.callout)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested home")
    }

    /// A home's chip. With an editor, hovering shows a remove button and right-clicking offers
    /// Make Primary Home and Remove.
    @ViewBuilder private func chip(_ home: DecimalCategory, primary: Bool) -> some View {
        let base = CategoryChip(category: home, primary: primary)
        if editor != nil {
            base
                .overlay(alignment: .topTrailing) {
                    if hovered == home.id {
                        Button { edit(home, remove: true) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor), .secondary)
                        }
                        .buttonStyle(.plain).font(.callout)
                        .offset(x: 6, y: -6)
                        .help("Remove from \(home.label)")
                        .transition(.opacity)
                    }
                }
                .onHover { inside in
                    withAnimation(.easeOut(duration: 0.12)) {
                        if inside {
                            hovered = home.id
                        } else if hovered == home.id {
                            hovered = nil
                        }
                    }
                }
                .contextMenu {
                    if !primary {
                        Button("Make Primary Home") { edit(home, remove: false) }
                    }
                    Button("Remove from \(home.label)", role: .destructive) {
                        edit(home, remove: true)
                    }
                }
                .accessibilityAction(named: "Remove from \(home.label)") { edit(home, remove: true)
                }
        } else {
            base
        }
    }

    private func edit(_ home: DecimalCategory, remove: Bool) {
        guard let editor else { return }
        hovered = nil
        Task {
            do {
                if remove {
                    let before = try await editor.remove(document.id, home)
                    step = .edited("Removed from \(home.label).", before)
                } else {
                    let before = try await editor.makePrimary(document.id, home)
                    step = .edited("Made \(home.label) the primary home.", before)
                }
            } catch { step = .failed(error.localizedDescription) }
        }
    }

    private func restore(_ before: [FilingMembership]) {
        guard let editor else { return }
        Task {
            do {
                try await editor.restore(document.id, before)
                step = .idle
            } catch { step = .failed(error.localizedDescription) }
        }
    }

    /// Other homes it could live in too, each added as a secondary home on its own.
    private func alsoFits(_ homes: [DecimalCategory]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Also fits").font(.caption).foregroundStyle(.secondary)
            ForEach(homes) { home in
                HStack(spacing: 8) {
                    CategoryChip(category: home, primary: false)
                    if added.contains(home.id) {
                        Text("Added").font(.callout).foregroundStyle(.secondary)
                        Button("Undo") { setHome(home, on: false) }.buttonStyle(.link)
                    } else if categories.contains(where: { $0.id == home.id }) {
                        Text("Already here").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("Also File Here") { setHome(home, on: true) }
                            .buttonStyle(.link)
                            .help("Add as another home; the main home stays")
                    }
                }
            }
        }
    }

    private func setHome(_ home: DecimalCategory, on: Bool) {
        guard let suggester else { return }
        Task {
            do {
                if on {
                    if try await suggester.addHome(document.id, home) {
                        added.insert(home.id)
                    }
                } else {
                    try await suggester.removeHome(document.id, home)
                    added.remove(home.id)
                }
            } catch { step = .failed(error.localizedDescription) }
        }
    }

    private func ask() {
        guard let suggester else { return }
        step = .asking
        Task {
            do {
                step = try await suggester.suggest(document.id).map { .suggested($0) }
                    ?? .failed("Suggestions need Apple Intelligence or ChatGPT.")
            } catch { step = .failed(error.localizedDescription) }
        }
    }

    private func file(_ suggestion: HomeSuggestion) {
        guard let suggester else { return }
        Task {
            do { step = try await .filed(suggestion, suggester.file(document.id, suggestion)) }
            catch { step = .failed(error.localizedDescription) }
        }
    }

    private func undo(_ ids: [UUID]) {
        guard let suggester else { return }
        Task {
            do {
                try await suggester.undo(ids)
                step = .idle
            } catch { step = .failed(error.localizedDescription) }
        }
    }
}
