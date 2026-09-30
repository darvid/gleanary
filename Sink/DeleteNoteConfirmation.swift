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
        alert.informativeText = "This removes the note, its revision history, captures, and original files that no other capture uses. Unused vectors and unsaved edits are removed too. This cannot be undone."
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
