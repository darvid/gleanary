import AppKit

@MainActor enum DeleteNoteConfirmation {
    static func present(
        _ document: MarkdownDocument,
        library: LibraryModel,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard library.canDeleteNotes,
              let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permanently delete “\(document.name)”?"
        alert.informativeText = "This permanently removes the document, revision history, captures, favicon, search data, and graph and mind-map data. Tracked tasks remain in Tasks, without this note as their origin. Original files and vectors shared with other documents are kept. This cannot be undone."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let delete = alert.addButton(withTitle: "Delete permanently")
        delete.keyEquivalent = ""
        // Native neutral buttons preserve label contrast; the warning names the irreversible
        // action.
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            Task { @MainActor in
                await completion(library.remove(document.id))
            }
        }
    }
}
