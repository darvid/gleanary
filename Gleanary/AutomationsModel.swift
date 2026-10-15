import Foundation
import Observation

/// The app's automations: their settings, the schedule that runs them, their run history and
/// what they've proposed. Runs happen one at a time while the app is open.
@MainActor @Observable final class AutomationsModel {
    private(set) var configs: [AutomationConfig] = []
    private(set) var runs: [AutomationKind: [AutomationRun]] = [:]
    /// Proposals waiting for review, per automation.
    private(set) var pending: [AutomationKind: [AgentChange]] = [:]
    /// Item titles for showing proposals.
    private(set) var titles: [UUID: String] = [:]
    private(set) var running: AutomationKind?
    /// What the running automation is doing now, when it says.
    private(set) var progress: String?
    /// Items due now per automation, beyond what one run takes.
    private(set) var backlog: [AutomationKind: Int] = [:]
    /// Runs whose changes are still applied, so Undo can put them back.
    private(set) var undoableRuns: Set<UUID> = []
    /// Runs whose changes were all undone.
    private(set) var undoneRuns: Set<UUID> = []
    /// Items history mentions that are gone, so they show without a link.
    private(set) var goneItems: Set<UUID> = []
    var error: String?

    @ObservationIgnored private let store: DocumentStore
    @ObservationIgnored private let engine: AutomationEngine
    @ObservationIgnored private let schedules: Bool
    /// The run in progress, however it started (Run Now, the schedule or new items), so
    /// Stop can always reach it.
    @ObservationIgnored private var currentRun: Task<AutomationRun, Never>?
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var newItemsTask: Task<Void, Never>?
    /// Refreshes the library after a run changed it.
    @ObservationIgnored var libraryChanged: () async -> Void = {}

    var pendingCount: Int {
        pending.values.reduce(0) { $0 + $1.count }
    }

    /// Automations whose latest run failed, until a later one succeeds.
    var failed: [AutomationKind] {
        AutomationKind.allCases.filter { runs[$0]?.first?.status == .failed }
    }

    /// `schedules` false keeps tests and previews from running anything on their own.
    init(store: DocumentStore, engine: AutomationEngine, schedules: Bool) {
        self.store = store
        self.engine = engine
        self.schedules = schedules
    }

    func config(_ kind: AutomationKind) -> AutomationConfig {
        configs.first { $0.kind == kind } ?? AutomationConfig(kind: kind)
    }

    func load() async {
        do {
            configs = try await store.automationConfigs()
            var updatedRuns: [AutomationKind: [AutomationRun]] = [:]
            var updatedPending: [AutomationKind: [AgentChange]] = [:]
            var updatedBacklog: [AutomationKind: Int] = [:]
            for kind in AutomationKind.allCases {
                // A run in progress shows as Running… above the history, not as an empty row.
                updatedRuns[kind] = try await store.automationRuns(kind)
                    .filter { $0.status != .running }
                updatedPending[kind] = try await store.pendingAutomationChanges(kind)
                updatedBacklog[kind] = try await engine.backlog(config(kind))
            }
            backlog = updatedBacklog
            var updatedTitles = titles
            let missing = Set(updatedPending.values.joined().flatMap { [$0.noteID, $0.targetID] }
                .compactMap(\.self)).filter { updatedTitles[$0] == nil }
            let found = try await store.noteTitles(Array(missing))
            for id in missing {
                updatedTitles[id] = found[id] ?? "Deleted item"
            }
            let undo = try await store.runUndoState(updatedRuns.values.joined().map(\.id))
            let gone = try await store.missingNotes(Array(Set(
                updatedRuns.values.joined().flatMap(\.entries).compactMap(\.itemID)
            )))
            runs = updatedRuns
            undoableRuns = undo.applied
            undoneRuns = undo.undone
            goneItems = gone
            pending = updatedPending
            titles = updatedTitles
        } catch { self.error = error.localizedDescription }
    }

    /// Starts the schedule, first catching up on anything missed while the app was closed.
    /// The system decides exactly when within each window, deferring under load or on battery.
    func start() {
        guard schedules, scheduler == nil else { return }
        let activity = NSBackgroundActivityScheduler(identifier: "app.gleanary.automations")
        activity.repeats = true
        activity.interval = 5 * 60
        activity.tolerance = 2 * 60
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.tick()
                completion(.finished)
            }
        }
        scheduler = activity
        Task {
            try? await store.closeInterruptedAutomationRuns()
            await load()
            await tick()
        }
    }

    /// Runs every enabled automation that's due, one after another.
    func tick(now: Date = Date()) async {
        guard running == nil else { return }
        if configs.isEmpty {
            await load()
        }
        for config in configs where config.isDue(at: now) {
            await perform(config)
        }
    }

    /// How long after the last save a run starts, so a burst of saves is one run.
    static let newItemsDelay: Duration = .seconds(90)

    /// Something new was saved. Automations that work on new items run shortly after, rather
    /// than waiting for their schedule; new items come first in every run, so they're covered.
    func itemsSaved() {
        guard schedules else { return }
        newItemsTask?.cancel()
        newItemsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.newItemsDelay)
            guard !Task.isCancelled else { return }
            await self?.runForNewItems()
        }
    }

    func runForNewItems() async {
        guard running == nil else { return }
        if configs.isEmpty {
            await load()
        }
        for config in configs where config.enabled && config.kind.followsNewItems {
            await perform(config)
        }
    }

    /// How many items this automation's next run takes, given what's due.
    func plannedBatch(_ kind: AutomationKind) -> Int {
        AutomationEngine.plannedBatch(config(kind), backlog: backlog[kind] ?? 0)
    }

    func runNow(_ kind: AutomationKind) {
        guard running == nil else { return }
        Task { await perform(config(kind)) }
    }

    private func show(_ step: String) {
        guard running != nil else { return }
        progress = step
    }

    func stop() {
        currentRun?.cancel()
    }

    func update(_ config: AutomationConfig) {
        guard let index = configs.firstIndex(where: { $0.kind == config.kind }) else { return }
        let recheckChanged = configs[index].recheck != config.recheck
        configs[index] = config
        Task {
            do {
                try await store.saveAutomation(config)
                // A different interval changes what's due.
                if recheckChanged {
                    backlog[config.kind] = try await engine.backlog(config)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Applies the chosen proposals and turns down the rest of this automation's.
    func apply(_ ids: Set<UUID>, of kind: AutomationKind) async {
        let all = pending[kind] ?? []
        do {
            let report = try await store.applyAgentChanges(Array(ids))
            try await store.rejectAgentChanges(all.map(\.id).filter { !ids.contains($0) })
            if report.stale > 0 {
                error = "\(report.stale) change\(report.stale == 1 ? "" : "s") skipped: the item changed since it was proposed."
            }
        } catch { self.error = error.localizedDescription }
        await load()
        await libraryChanged()
    }

    func reject(_ kind: AutomationKind) async {
        do { try await store.rejectAgentChanges((pending[kind] ?? []).map(\.id)) }
        catch { self.error = error.localizedDescription }
        await load()
    }

    /// Puts back what one run applied, where the item hasn't changed since.
    func undo(_ run: AutomationRun) async {
        do {
            let ids = try await store.appliedRunChanges(run.id)
            let undone = try await store.undoAgentChanges(ids)
            if undone < ids.count {
                error = "\(ids.count - undone) change\(ids.count - undone == 1 ? " was" : "s were") edited since and kept."
            }
        } catch { self.error = error.localizedDescription }
        await load()
        await libraryChanged()
    }

    func canUndo(_ run: AutomationRun) -> Bool {
        run.kind.undoable && run.changed > 0 && undoableRuns.contains(run.id)
    }

    private func perform(_ config: AutomationConfig) async {
        // Two quick Run Now clicks, or a click as the schedule fires, start one run.
        guard running == nil else { return }
        running = config.kind
        let engine = engine
        let task = Task {
            await engine.run(config) { [weak self] step in await self?.show(step) }
        }
        currentRun = task
        defer {
            running = nil
            progress = nil
            currentRun = nil
        }
        let run = await task.value
        await load()
        if run.changed > 0 || run.proposed > 0 {
            await libraryChanged()
        }
    }
}

/// What automations need from the library while they run, read on the main actor.
@MainActor final class AutomationHooks {
    weak var library: LibraryModel?
    var judge: (any LinkJudging)?
    var filer: (any ConversationInferring)?
    /// Looks up the Writer's model when a digest runs, so it follows the AI provider then
    /// rather than whatever was set when the window opened.
    var writer: (@MainActor () async throws -> (any ConversationInferring)?)?

    func currentWriter() async throws -> (any ConversationInferring)? {
        try await writer?()
    }

    /// Imports, deletions and a summary someone asked for come first.
    var shouldYield: Bool {
        guard let library else { return true }
        return library.busy || library.generatingSummaryID != nil
    }
}
