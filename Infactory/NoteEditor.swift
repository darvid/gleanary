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
    @State private var confirmingDiscard = false

    init(document: MarkdownDocument, library: LibraryModel, close: @escaping () -> Void) {
        self.document = document
        self.library = library
        self.close = close
        _name = State(initialValue: document.name)
        _markdown = State(initialValue: document.markdown)
    }

    private var changed: Bool {
        name != document.name || markdown != document.markdown
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
                        if await library.save(draft) {
                            close()
                        } else {
                            message = library.error
                        }
                    }
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(library.busy || name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            Divider()
            // The title as the reading view shows it, so editing doesn't change the page's shape.
            TextField("Title", text: $name)
                .textFieldStyle(.plain)
                .font(.title.weight(.bold))
                .accessibilityLabel("Note name")
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 8)
            MarkdownSourceEditor(text: $markdown, documentID: document.id)
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
                Button("Export Markdown", systemImage: "square.and.arrow.up") { exporting = true }
                if !history.isEmpty {
                    Menu("Revision history") {
                        ForEach(history) { revision in
                            Button(
                                "\(revision.name) · \(revision.createdAt.formatted(date: .abbreviated, time: .standard))"
                            ) {
                                name = revision.name
                                markdown = revision.markdown
                                message = "Loaded a previous revision into the editor. Save to create a new revision."
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
            document: MarkdownExport(text: markdown),
            contentType: UTType(filenameExtension: "md") ?? .plainText,
            defaultFilename: name
        ) { result in
            if case let .failure(error) = result {
                message = error.localizedDescription
            }
        }
        .task {
            do { history = try await library.history(for: document.id) }
            catch { message = "Could not load revision history: \(error.localizedDescription)" }
        }
    }
}

/// Styles Markdown as it's typed but keeps every character, so the saved note is exactly the
/// text written.
struct MarkdownSourceEditor: View {
    @Binding var text: String
    /// Scopes the editor's undo history to one note.
    let documentID: UUID

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: MarkdownEditorConfiguration(textInsets: TextInsets(horizontal: 28)),
            fontSize: NSFont.systemFontSize,
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
            throw InfactoryError.invalidFile("Markdown")
        }
        self.text = text
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
