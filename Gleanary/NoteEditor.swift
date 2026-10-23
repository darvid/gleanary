import MarkdownEngine
import SwiftUI
import UniformTypeIdentifiers

/// Edits a note in place of its reading view, so the library stays beside it.
struct NoteEditor: View {
    let document: MarkdownDocument
    @Bindable var library: LibraryModel
    /// Leaves the editor; saving, discarding and deleting all end here.
    let close: () -> Void
    @State private var name: String
    @State private var markdown: String
    @State private var history: [NoteRevision] = []
    @State private var message: String?
    @State private var exporting = false
    @State private var exportText = ""
    @State private var profile: NoteProfile
    @State private var originalProfile: NoteProfile
    @State private var profileReady: Bool
    @State private var propertiesExpanded = false
    @State private var templateDraft: NoteTemplate?
    var didSave: (UUID) -> Void
    @State private var confirmingDiscard = false
    @State private var readingKind = ReadingKind.notes
    private var appearance = ReadingAppearance()

    init(
        document: MarkdownDocument,
        library: LibraryModel,
        profile: NoteProfile? = nil,
        didSave: @escaping (UUID) -> Void = { _ in },
        close: @escaping () -> Void
    ) {
        self.document = document
        self.library = library
        self.close = close
        self.didSave = didSave
        _profile = State(initialValue: profile ?? NoteProfile())
        _originalProfile = State(initialValue: profile ?? NoteProfile())
        _profileReady = State(initialValue: profile != nil || document.revision == nil)
        _propertiesExpanded = State(initialValue: profile?.type != nil && profile?.type != .note)
        _name = State(initialValue: document.name)
        _markdown = State(initialValue: document.markdown)
    }

    private var changed: Bool {
        name != document.name || markdown != document.markdown || profile != originalProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(
                    document.revision == nil ? "New Note" : "Editing Markdown",
                    systemImage: "square.and.pencil"
                )
                .font(.headline)
                Spacer()
                Button("Cancel") {
                    if changed {
                        confirmingDiscard = true
                    } else {
                        close()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(library.busy)
                Button("Save") {
                    Task {
                        var draft = document
                        draft.name = name
                        draft.markdown = markdown
                        if await library.save(draft, profile: profile) {
                            close()
                            didSave(draft.id)
                        } else {
                            message = library.error
                        }
                    }
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(library.busy || !profileReady || name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            Divider()
            // The title as the reading view shows it, so editing doesn't change the page's shape.
            TextField("Title", text: $name)
                .textFieldStyle(.plain)
                .font(appearance[readingKind].scaledFont(22.0 / 14, weight: .bold))
                .accessibilityLabel("Note name")
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 8)
            DisclosureGroup("Note properties", isExpanded: $propertiesExpanded) {
                ScrollView {
                    NotePropertiesEditor(profile: $profile, store: library.store).padding(.top, 8)
                }.frame(maxHeight: 210)
            }
            .disabled(!profileReady)
            .padding(.horizontal, 28).padding(.bottom, 10)
            MarkdownSourceEditor(text: $markdown, documentID: document.id, readingKind: readingKind)
                .accessibilityLabel("Markdown content")
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).textSelection(.enabled)
                    .padding(.horizontal, 28).padding(.vertical, 8)
            }
            Divider()
            HStack {
                if document.revision != nil {
                    Button("Delete note", systemImage: "trash", role: .destructive) {
                        DeleteNoteConfirmation.present(document, library: library) { deleted in
                            if deleted {
                                close()
                            } else {
                                message = library
                                    .error ??
                                    "The note could not be deleted. Close the editor and try again."
                            }
                        }
                    }
                    .disabled(!library.canDeleteNotes)
                    .help(library
                        .captureTask == nil ? "Permanently delete this note" :
                        "Wait for captures to finish before deleting")
                }
                Button("Export Markdown", systemImage: "square.and.arrow.up") {
                    Task {
                        do {
                            exportText = try await library.store.workspaceExport(
                                markdown,
                                noteID: document.id,
                                profile: profile
                            )
                            exporting = true
                        } catch { message = "Could not prepare the Markdown export. Try again." }
                    }
                }.disabled(!profileReady)
                Button("Save as template…") {
                    templateDraft = NoteTemplate(
                        name: name + " template",
                        body: NoteTemplate.starterBody(from: markdown),
                        defaults: NoteProfile(type: profile.type)
                    )
                }.disabled(!profileReady)
                if !history.isEmpty {
                    Menu("Revision history") {
                        ForEach(history) { revision in
                            Button(
                                "\(revision.name) · \(revision.createdAt.formatted(date: .abbreviated, time: .standard))"
                            ) {
                                Task {
                                    do {
                                        let saved = try await library.store
                                            .noteProfileRevision(revision.id)
                                        name = revision.name
                                        markdown = revision.markdown
                                        if let saved {
                                            profile = saved
                                        }
                                        message = "Loaded a previous revision. Save to create a new revision. Task records are not rolled back."
                                    } catch {
                                        message =
                                            "Could not load this revision. Try another revision."
                                    }
                                }
                            }
                        }
                    }
                }
                Spacer()
                Text("Saved locally. Search indexing runs in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(.horizontal, 28).padding(.vertical, 10)
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .disabled(library.busy)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard) {
            Button("Discard changes", role: .destructive) { close() }
        }
        .fileExporter(
            isPresented: $exporting,
            document: MarkdownExport(text: exportText),
            contentType: UTType(filenameExtension: "md") ?? .plainText,
            defaultFilename: name
        ) { result in
            if case let .failure(error) = result {
                message = error.localizedDescription
            }
        }
        .sheet(item: $templateDraft) {
            NoteTemplateEditor(workspace: library.workspace, template: $0)
        }
        .task {
            guard document.revision != nil else { return }
            do {
                if !profileReady {
                    profile = try await library.store.noteProfile(document.id)
                    originalProfile = profile
                    profileReady = true
                }
                let details = try await library.store.libraryItemDetails(for: document.id)
                readingKind = ReadingKind(libraryKind: details.kind)
                history = try await library.history(for: document.id)
            } catch { message = "Could not load revision history: \(error.localizedDescription)" }
        }
    }
}

/// Styles Markdown as it's typed but keeps every character, so the saved note is exactly the
/// text written.
struct MarkdownSourceEditor: View {
    @Binding var text: String
    /// Scopes the editor's undo history to one note.
    let documentID: UUID
    var readingKind = ReadingKind.notes
    private var appearance = ReadingAppearance()

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: MarkdownEditorConfiguration(textInsets: TextInsets(horizontal: 28)),
            fontName: appearance[readingKind].nativeFont.fontName,
            fontSize: appearance[readingKind].size,
            documentId: documentID.uuidString
        )
        .background(FirstRenderRedraw())
    }
}

/// MarkdownEngine 0.14.0 styles a note just after laying it out unstyled, and doesn't redraw the
/// visible text for the taller result, so the first render stops partway down until a click.
/// Redraws once the editor is on screen, as a click does.
private struct FirstRenderRedraw: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        Probe()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After SwiftUI's current update, which is when the engine styles the note.
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.editorTextView() else { return }
                textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
                textView.setSelectedRange(textView.selectedRange())
                textView.needsDisplay = true
            }
        }

        /// The editor is this view's sibling, so search up from the nearest shared ancestor.
        private func editorTextView() -> NSTextView? {
            var ancestor = superview
            while let view = ancestor {
                if let textView = Self.textView(in: view) {
                    return textView
                }
                ancestor = view.superview
            }
            return nil
        }

        private static func textView(in view: NSView) -> NSTextView? {
            // Skips the title field's editor, which is also a text view while it has focus.
            if let textView = view as? NSTextView, !textView.isFieldEditor {
                return textView
            }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
    }
}

struct MarkdownExport: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText]
    }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(
            data: data,
            encoding: .utf8
        ) else {
            throw GleanaryError.invalidFile("Markdown")
        }
        self.text = text
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
