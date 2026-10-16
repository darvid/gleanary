import Foundation
import GRDB
import Observation

@MainActor @Observable
final class ActivityModel {
    var query = ActivityQuery()
    private(set) var days: [ActivityDay] = []
    private(set) var hasMore = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var trackingSince: Date?
    private(set) var generation = 0
    private(set) var inspection: ActivityInspection?
    private(set) var inspecting = false
    private(set) var inspectionError: String?
    var selection: Int64?
    @ObservationIgnored private let store: DocumentStore
    private var token = UUID()
    private var inspectionToken = UUID()

    init(store: DocumentStore) {
        self.store = store
    }

    func reload() async {
        token = UUID()
        let expected = token
        loading = true
        error = nil
        do {
            let page = try await store.activityPage(query: query)
            guard expected == token, !Task.isCancelled else { return }
            days = page.days
            hasMore = page.hasMore
            trackingSince = page.trackingSince
            generation += 1
        } catch {
            guard expected == token, !Task.isCancelled else { return }
            self.error = "Could not load activity. Try again."
            // Stale rows might contain the title of a now-purged note.
            days = []
        }
        if expected == token {
            loading = false
        }
    }

    func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        let expected = token
        let offset = days.reduce(0) { $0 + $1.groups.count }
        do {
            let page = try await store.activityPage(query: query, offset: offset)
            guard expected == token, !Task.isCancelled else { return }
            for day in page.days {
                if days.last?.id == day.id {
                    days[days.count - 1].groups += day.groups
                } else {
                    days.append(day)
                }
            }
            hasMore = page.hasMore
            error = nil
        } catch {
            guard expected == token, !Task.isCancelled else { return }
            self.error = "Could not load older activity. Try again."
        }
        if expected == token {
            loading = false
        }
    }

    func inspectSelection() async {
        inspectionToken = UUID()
        let expected = inspectionToken
        inspection = nil
        inspectionError = nil
        guard let selection else { inspecting = false; return }
        inspecting = true
        do {
            let result = try await store.inspectActivity(selection)
            guard expected == inspectionToken, !Task.isCancelled else { return }
            inspection = result
        } catch {
            guard expected == inspectionToken, !Task.isCancelled else { return }
            inspectionError = "Could not load this change. Try again."
        }
        if expected == inspectionToken {
            inspecting = false
        }
    }

    /// SQLite observation includes writes from other windows and background workers.
    func observe() async {
        do {
            let pool = try await store.readyDatabase()
            let observation = ValueObservation.tracking { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT version FROM activity_context WHERE id = 1"
                ) ?? 0
            }
            for try await _ in observation.values(in: pool) {
                guard !Task.isCancelled else { return }
                // Clear before awaiting so permanent deletion cannot leave an old preview visible.
                inspectionToken = UUID()
                inspection = nil
                await reload()
                await inspectSelection()
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Activity updates stopped. Reopen Activity to reconnect."
        }
    }
}
