import SwiftUI
import UniformTypeIdentifiers

/// File › Import Bookmarks: choose an export, decide where its folders go, then import.
struct BookmarkImportView: View {
    let library: LibraryModel
    var onImported: () async -> Void = {}
    /// Opens auto-categorization for what the import left unfiled.
    var categorize: (() -> Void)?
    @State private var choosingFile: Bool
    @State private var preparing = false
    @State private var draft: BookmarkImportDraft?
    @State private var plan: BookmarkFolderPlan?
    @State private var imported: Int?
    @State private var report: BookmarkImportReport?
    @State private var error: String?
    @State private var askTask: Task<Void, Never>?
    /// Identifies the current Librarian run, so late streamed updates from a stopped or undone
    /// run are ignored.
    @State private var librarianRun: UUID?
    @State private var librarianAnswered = 0
    @State private var librarianTotal = 0
    @State private var reasons: [String: String] = [:]
    /// The plan before the Librarian's last suggestion, for undo.
    @State private var beforeLibrarian: BookmarkFolderPlan?
    @State private var librarianNote: String?
    /// Resolved when asked, so it follows the current ChatGPT setting.
    private let inference: (() -> any ConversationInferring)?
    @Environment(\.dismiss) private var dismiss

    /// With a prepared draft, the sheet opens on review instead of the file chooser.
    init(
        library: LibraryModel,
        draft: BookmarkImportDraft? = nil,
        onImported: @escaping () async -> Void = {},
        categorize: (() -> Void)? = nil,
        inference: (() -> any ConversationInferring)? = nil
    ) {
        self.library = library
        self.onImported = onImported
        self.categorize = categorize
        self.inference = inference
        _choosingFile = State(initialValue: draft == nil)
        _draft = State(initialValue: draft)
        _plan = State(initialValue: draft?.plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Bookmarks").font(.title2.weight(.semibold))
            if let report {
                summary(report)
            } else if let imported, let draft {
                ProgressView(
                    value: Double(imported),
                    total: Double(max(1, draft.file.bookmarks.count))
                ) {
                    Text("Importing \(draft.file.bookmarks.count.formatted()) bookmarks…")
                } currentValueLabel: {
                    Text("\(imported.formatted()) checked").monospacedDigit()
                        .countsOnChange(imported)
                }
                Spacer()
            } else if let draft, plan != nil {
                review(draft)
            } else if preparing {
                WorkingProgress("Reading export…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                introduction
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            footer
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 620)
        .fileImporter(
            isPresented: $choosingFile,
            allowedContentTypes: [.commaSeparatedText, .html]
        ) { result in
            switch result {
            case let .success(url): Task { await prepare(url) }
            case let .failure(failure): error = failure.localizedDescription
            }
        }
        .interactiveDismissDisabled(imported != nil && report == nil)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Choose a bookmark export: an HTML file from Safari, Chrome, Firefox or Raindrop, or a Raindrop CSV."
            )
            Text(
                "Bookmarks are saved from the export alone—nothing is downloaded. A page is fetched when you open it."
            )
            .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if report == nil, imported == nil {
                Button("Choose File…") { choosingFile = true }.disabled(preparing)
            }
            Spacer()
            if let report {
                if let categorize, !report.unfiledIDs.isEmpty {
                    Button("Suggest Homes for \(report.unfiledIDs.count.formatted()) Unfiled…") {
                        categorize()
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(imported != nil)
                if let draft, let plan {
                    Button("Import \(draft.file.bookmarks.count.formatted())") {
                        Task { await run(draft, plan: plan) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(imported != nil || askTask != nil || !library.ready || library.busy)
                }
            }
        }
    }

    private func review(_ draft: BookmarkImportDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(overview(draft)).font(.callout).foregroundStyle(.secondary)
            if let plan, !plan.folders.isEmpty {
                librarianBar
                List {
                    ForEach(plan.folders) { folder in
                        folderRow(folder, options: options(draft))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08))
                )
                Text(
                    "Unfiled bookmarks wait in the library for auto-categorization. New categories are created only when you import."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
            }
        }
    }

    private var librarianBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Folders").font(.headline)
                if let librarianNote, askTask == nil {
                    Text(librarianNote).font(.caption).foregroundStyle(.secondary)
                    if beforeLibrarian != nil {
                        Button("Undo") { undoLibrarian() }.buttonStyle(.link).font(.caption)
                    }
                }
                Spacer()
                if let inference {
                    if askTask != nil {
                        Button("Stop") { askTask?.cancel() }
                    } else {
                        let local = inference().capabilities.local
                        Button("Ask Librarian", systemImage: "sparkles") {
                            startLibrarian(inference())
                        }
                        .disabled(imported != nil)
                        .help(local
                            ? "Suggest a home for every folder using Apple Intelligence on this Mac."
                            :
                            "Suggest a home for every folder using ChatGPT. Folder names, counts and a few titles are sent to OpenAI.")
                    }
                }
            }
            if askTask != nil {
                if librarianAnswered == 0 {
                    // Nothing measurable until the first folder is answered.
                    ProgressView {
                        Text("The Librarian is reading \(librarianTotal) folders…").font(.callout)
                    }
                    .progressViewStyle(.linear)
                } else {
                    ProgressView(
                        value: Double(librarianAnswered),
                        total: Double(max(1, librarianTotal))
                    ) {
                        Text("The Librarian is placing folders…").font(.callout)
                    } currentValueLabel: {
                        Text("\(librarianAnswered) of \(librarianTotal) folders").monospacedDigit()
                            .countsOnChange(librarianAnswered)
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: BookmarkFolderPlan.Folder, options: [Option]) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(folder.path.last ?? "", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                if let reason = reasons[folder.id] {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(reason)
                }
            }
            .padding(.leading, CGFloat(folder.depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A fixed, right-aligned column so counts line up at every depth.
            Text(folder.count.formatted()).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .accessibilityLabel("\(folder.count) bookmarks")
            if case .new = folder.destination {
                NewCategoryBadge()
            }
            Picker("Destination for \(folder.id)", selection: destination(folder)) {
                ForEach(options) { option in
                    Text(option.label).tag(option.destination)
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }

    private func summary(_ report: BookmarkImportReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "\(report.imported.formatted()) bookmarks imported",
                systemImage: "checkmark.circle"
            )
            .font(.headline)
            Group {
                Text(
                    "\(report.filed.formatted()) filed from folders, \(report.unfiledIDs.count.formatted()) unfiled"
                )
                if report.categoriesCreated > 0 {
                    Text("\(report.categoriesCreated) new categories")
                }
                if report.duplicates > 0 {
                    Text("\(report.duplicates.formatted()) already in your library or repeated")
                }
                if report.rejected > 0 {
                    Text("\(report.rejected.formatted()) skipped as unsafe addresses")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func overview(_ draft: BookmarkImportDraft) -> String {
        var parts = [
            "\(draft.file.bookmarks.count.formatted()) bookmarks in \(draft.fileName)",
        ]
        if let plan, plan.unsorted > 0 {
            parts.append("\(plan.unsorted.formatted()) not in a folder")
        }
        if draft.file.skipped > 0 {
            parts.append("\(draft.file.skipped.formatted()) skipped (not web pages)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Destinations

    private struct Option: Identifiable {
        let destination: BookmarkFolderPlan.Destination
        let label: String
        var id: BookmarkFolderPlan.Destination {
            destination
        }
    }

    /// Unfiled, every existing category, and every category the original plan proposed.
    /// Unfiled, existing categories, and new categories: the current plan's names first, then
    /// any the original plan proposed under codes still free. Every destination in use is
    /// listed, so no picker shows a value it has no option for.
    private func options(_ draft: BookmarkImportDraft) -> [Option] {
        var proposed: [String: String] = [:]
        for category in (plan?.newCategories ?? []) + draft.plan.newCategories {
            proposed[category.code] = proposed[category.code] ?? category.name
        }
        return [Option(destination: .unfiled, label: "Leave unfiled")]
            + draft.categories.map { Option(destination: .existing($0.id), label: $0.label) }
            + proposed.sorted { $0.key < $1.key }.map { (code: $0.key, name: $0.value) }.map {
                Option(
                    destination: .new(code: $0.code, name: $0.name),
                    label: "\($0.code) \($0.name)"
                )
            }
    }

    /// Changing a folder moves the subfolders that were following it.
    private func destination(_ folder: BookmarkFolderPlan
        .Folder) -> Binding<BookmarkFolderPlan.Destination>
    {
        Binding {
            plan?.destination(for: folder.path) ?? .unfiled
        } set: { value in
            guard var updated = plan else { return }
            for index in updated.folders.indices {
                let candidate = updated.folders[index]
                let descendant = candidate.path.starts(with: folder.path)
                    && candidate.path.count > folder.path.count
                if candidate.path == folder.path
                    || descendant && candidate.destination == folder.destination
                {
                    updated.folders[index].destination = value
                }
            }
            plan = updated
        }
    }

    // MARK: Actions

    /// Streams the Librarian's answers into the plan as they arrive. Stopping keeps the folders
    /// answered so far; Undo returns to the plan from before the run.
    private func startLibrarian(_ engine: any ConversationInferring) {
        guard let draft, let base = plan, askTask == nil else { return }
        let folders = FolderMapping.folders(plan: base, bookmarks: draft.file.bookmarks)
        let run = UUID()
        librarianRun = run
        beforeLibrarian = base
        reasons = [:]
        librarianNote = nil
        error = nil
        librarianAnswered = 0
        librarianTotal = folders.count
        askTask = Task {
            do {
                let answers = try await engine.librarianFolderPlan(
                    folders,
                    categories: draft.categories
                ) { partial in
                    Task { @MainActor in
                        applyLibrarian(partial, base: base, folders: folders, run: run)
                    }
                }
                applyLibrarian(answers, base: base, folders: folders, run: run, final: true)
            } catch is CancellationError {
                librarianNote = "Stopped after \(librarianAnswered) of \(librarianTotal) folders."
            } catch {
                self.error = error.localizedDescription
                if librarianAnswered > 0 {
                    librarianNote = "Kept \(librarianAnswered) of \(librarianTotal) folders."
                }
            }
            if librarianRun == run {
                askTask = nil
            }
        }
    }

    private func applyLibrarian(
        _ answers: [FolderMapping.Answer],
        base: BookmarkFolderPlan,
        folders: [FolderMapping.Folder],
        run: UUID,
        final: Bool = false
    ) {
        // Streamed snapshots can arrive out of order; never go backwards.
        guard librarianRun == run, final || answers.count > librarianAnswered,
              let draft else { return }
        let result = FolderMapping.apply(
            answers, to: base, folders: folders, categories: draft.categories
        )
        plan = result.plan
        reasons = result.reasons
        librarianAnswered = answers.count
        guard final else { return }
        let created = result.plan.newCategories.count
        librarianNote = (result
            .changed == 1 ? "Changed 1 folder" : "Changed \(result.changed) folders")
            + (created == 0 ? "." : created == 1 ? ", 1 new category."
                : ", \(created) new categories.")
    }

    private func undoLibrarian() {
        askTask?.cancel()
        askTask = nil
        librarianRun = nil
        if let beforeLibrarian {
            plan = beforeLibrarian
        }
        beforeLibrarian = nil
        reasons = [:]
        librarianNote = nil
    }

    private func prepare(_ url: URL) async {
        preparing = true
        error = nil
        defer { preparing = false }
        do {
            let prepared = try await library.prepareBookmarkImport(url)
            draft = prepared
            plan = prepared.plan
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ draft: BookmarkImportDraft, plan: BookmarkFolderPlan) async {
        imported = 0
        error = nil
        do {
            report = try await library.importBookmarks(draft, plan: plan) { imported = $0 }
            await onImported()
        } catch {
            imported = nil
            self.error = error.localizedDescription
        }
    }
}
