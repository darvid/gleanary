import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class NoteWorkspaceModel {
    let store: DocumentStore
    private(set) var generation = 0
    private(set) var noteGeneration = 0
    private(set) var busy = false
    var error: String?
    private(set) var templates: [NoteTemplate] = []

    init(store: DocumentStore) {
        self.store = store
    }

    func loadTemplates() async {
        do { templates = try await store.noteTemplates() }
        catch { self.error = "Could not load templates. Try opening Templates again." }
    }

    @discardableResult
    func change(changesNote: Bool = false, _ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await operation()
            generation += 1
            if changesNote {
                noteGeneration += 1
            }
            return true
        } catch {
            self.error = Self.message(error)
            return false
        }
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? WorkspaceError {
            return error.localizedDescription
        }
        if let error = error as? GleanaryError {
            return error.localizedDescription
        }
        return "This change could not be saved. Reopen the item and try again."
    }
}

/// The entry row is transient UI state, not a task record until Return is pressed.
@MainActor @Observable final class WorkspaceTaskEntryModel {
    var title = ""
    private(set) var submitting = false

    func submit(
        to workspace: NoteWorkspaceModel,
        view: WorkspaceTaskView,
        today: WorkspaceDay = WorkspaceDay(date: .now)
    ) async -> WorkspaceTaskView? {
        let entered = title
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !submitting else { return nil }
        submitting = true
        defer { submitting = false }
        let task = WorkspaceTask(title: trimmed, planned: view == .today ? today : nil)
        guard await workspace.change({ _ = try await workspace.store.saveWorkspaceTask(task) })
        else { return nil }
        // Do not discard text entered while the local write was in flight.
        if title == entered {
            title = ""
        }
        switch view {
        case .upcoming, .completed: return .inbox
        default: return view
        }
    }
}

extension EnvironmentValues {
    @Entry var noteWorkspace: NoteWorkspaceModel?
}
