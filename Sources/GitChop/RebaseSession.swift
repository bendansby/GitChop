import SwiftUI
import AppKit

/// Per-repo session state: plan, diff, status, in-flight Apply.
/// Owned by a `Workspace`, which holds N of these (one per open tab).
@MainActor
final class RebaseSession: ObservableObject, Identifiable {
    /// Stable identity for tab selection / SwiftUI ForEach tagging.
    /// Distinct from repoURL so we can track a session across reloads.
    let id = UUID()

    @Published var repoURL: URL?
    @Published var branch: String = ""
    @Published var plan: [PlanItem] = []
    @Published var baseHash: String = ""
    @Published var selectedID: String?
    @Published var diffText: String = ""
    @Published var isApplying = false

    /// One-off message override — set by actions that want to surface a
    /// transient notice ("Rebase applied", error text). Nil falls back
    /// to a live "Loaded N of M on branch" derived from current state,
    /// so the count never goes stale relative to plan/totalNonMergeCount.
    @Published var actionMessage: String? = nil

    /// Status-bar text. Computed so it always reflects current
    /// plan.count + totalNonMergeCount; previously a stored string
    /// that drifted when callers changed plan size without also
    /// re-setting status.
    var status: String {
        if let msg = actionMessage, !msg.isEmpty { return msg }
        if branch.isEmpty && plan.isEmpty { return "Open a git repo to begin." }
        if plan.isEmpty { return "No commits loaded on \(branch)." }
        let suffix = plan.count < totalNonMergeCount
            ? " of \(totalNonMergeCount) on \(branch)."
            : " (all) on \(branch)."
        return "Loaded \(plan.count) commit\(plan.count == 1 ? "" : "s")\(suffix)"
    }
    @Published var lastOutcome: RebaseOutcome?

    /// How many commits the user asked us to load. Distinct from
    /// `plan.count` because the engine caps the request at the actual
    /// reachable depth (e.g. asking for 50 in a 24-commit repo loads 24).
    @Published var requestedDepth: Int = 12

    /// When set, the plan is loaded from `<customBase>..HEAD` and the
    /// depth menu's count knobs don't apply. Set by "Use as base" on a
    /// commit row's context menu; cleared by the menu's "Switch to
    /// depth-based loading" option.
    @Published var customBase: String? = nil

    /// Total non-merge commits reachable from HEAD. Used to decide
    /// whether to show "load more" / "load all" affordances.
    @Published var totalNonMergeCount: Int = 0

    /// Default step size for the "Load N more" button.
    /// `nonisolated` so it can be used as a default-argument value in
    /// methods on this @MainActor class without Swift 6 complaining.
    nonisolated static let loadMoreIncrement = 12

    /// When set, a SplitCommitSheet is open for this PlanItem's id.
    /// Toggled by setVerb (when the user picks .edit) and by openSplitSheet
    /// (when they re-open it for an already-edit row); cleared when the
    /// sheet calls back with Save or Cancel.
    @Published var splitSheetCommitID: String?

    /// When set, a RewordSheet is open for this PlanItem's id. Toggled
    /// by `setVerb` (when the user picks .reword) and by `openRewordSheet`
    /// (when re-opening for an already-reworded row); cleared on
    /// Save/Cancel.
    @Published var rewordSheetCommitID: String?

    /// True when there's a plan loaded and at least one row has a non-pick
    /// verb or has been reordered. Drives the Apply button's enabled state
    /// — a no-op rebase is harmless but pointless.
    @Published var hasChanges = false

    /// Captured snapshot of the originally-loaded order, used to detect
    /// whether the user has actually edited the plan. Compared by
    /// commit ID + verb on every plan mutation.
    private var originalOrder: [String] = []

    /// Whether the user has changed the order of the plan rows since
    /// load. Read by the confirmation sheet to summarize the reorder.
    var isReordered: Bool {
        plan.map(\.id) != originalOrder
    }

    var repoName: String {
        repoURL?.lastPathComponent ?? "GitChop"
    }

    // MARK: - Init

    init() { }

    /// Create a session bound to a repo URL and trigger the initial load.
    /// Used when a tab is being opened or restored.
    convenience init(repoURL: URL) {
        self.init()
        load(repo: repoURL)
    }

    // MARK: - Load

    func load(repo: URL, depth: Int? = nil) {
        repoURL = repo
        let d = depth ?? requestedDepth
        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        do {
            let result = try engine.loadPlan(depth: d, customBase: customBase)
            plan = result.plan
            baseHash = result.base
            branch = result.branch.isEmpty ? "(detached)" : result.branch
            // chopableTotal is the most we can ever load (total non-merge
            // minus the root, which is always the base). Use it as the
            // total count the UI shows, so "X of N" is true.
            totalNonMergeCount = result.chopableTotal
            // Track what we actually loaded, not what we asked for —
            // the engine caps at chopableTotal, so a request for 100
            // in a 24-commit repo turns into a 23-commit load.
            requestedDepth = plan.count
            originalOrder = plan.map(\.id)
            selectedID = plan.last?.id    // most-recent commit selected by default
            // Clear any one-off override; computed `status` will derive
            // the live "Loaded N of M" text from the freshly-set state.
            actionMessage = nil
            recomputeChangedFlag()
            loadDiffForSelection()
            loadHunkCountsInBackground()
        } catch {
            actionMessage = error.localizedDescription
            plan = []
            baseHash = ""
            totalNonMergeCount = 0
            originalOrder = []
            selectedID = nil
            diffText = ""
            hasChanges = false
            hunkCounts = [:]
        }
    }

    /// Populate `hunkCounts` for every commit currently in the plan.
    /// Runs off the main actor so the UI stays responsive while the
    /// per-commit `git diff-tree` calls fan out, then hops back to
    /// publish the result.
    private func loadHunkCountsInBackground() {
        guard let repo = repoURL else { return }
        let shas = plan.map(\.commit.fullHash)
        // Snapshot of the plan's identity so a stale background run
        // doesn't overwrite a fresher load's counts.
        let planSnapshotID = shas
        Task.detached(priority: .utility) {
            let engine = RebaseEngine(runner: GitRunner(cwd: repo))
            var collected: [String: Int] = [:]
            for sha in shas {
                collected[sha] = engine.hunkCount(for: sha)
            }
            let finalCounts = collected
            await MainActor.run {
                // Drop the result if the plan changed under us during
                // the background run (reload, depth change, etc.).
                guard self.plan.map(\.commit.fullHash) == planSnapshotID else { return }
                self.hunkCounts = finalCounts
            }
        }
    }

    /// Cached hunk count for the commit, or nil if not yet loaded.
    /// Nil should be treated as "unknown — assume any verb is OK"
    /// so the chip menu doesn't disable rows during the brief load.
    func cachedHunkCount(for id: String) -> Int? {
        hunkCounts[id]
    }

    /// Reload the current repo at a new depth. Discards in-progress
    /// plan edits — the user is opting in by changing depth, and
    /// preserving partial edits across a different commit window
    /// surfaces a thicket of edge cases (commits that fall outside the
    /// new window, etc.) that aren't worth solving for v0.1.
    func reload(depth: Int) {
        guard let repo = repoURL else { return }
        load(repo: repo, depth: depth)
    }

    /// Discard all pending plan edits — verbs revert to .pick, the
    /// original order is restored, edit plans and reword messages are
    /// dropped. Implemented as a fresh `load` since load already
    /// rebuilds plan + originalOrder + change flag from scratch. No
    /// git side effects; the working tree and HEAD are untouched.
    func resetPlan() {
        guard let repo = repoURL else { return }
        // Close any open per-row sheets so they don't reference rows
        // whose state is about to change.
        splitSheetCommitID = nil
        rewordSheetCommitID = nil
        load(repo: repo)
    }

    /// Extend the loaded view by N commits (default `loadMoreIncrement`).
    /// Caps at `totalNonMergeCount` so we never request more than exists.
    func loadMore(by additional: Int = RebaseSession.loadMoreIncrement) {
        guard totalNonMergeCount > 0 else { return }
        let target = min(plan.count + additional, totalNonMergeCount)
        reload(depth: target)
    }

    /// Load every non-merge commit reachable from HEAD.
    func loadAll() {
        guard totalNonMergeCount > 0 else { return }
        reload(depth: totalNonMergeCount)
    }

    /// Pin the plan to start from this specific commit. Everything
    /// above the chosen commit (newer) becomes the plan; the commit
    /// itself becomes the rebase base. Equivalent to `git rebase -i
    /// <sha>` from the terminal.
    func setCustomBase(_ sha: String) {
        guard let repo = repoURL else { return }
        customBase = sha
        load(repo: repo)
    }

    /// Drop the custom base and revert to depth-based loading at the
    /// current `requestedDepth`.
    func clearCustomBase() {
        guard let repo = repoURL else { return }
        customBase = nil
        load(repo: repo)
    }

    // MARK: - Mutate plan

    func setVerb(of id: String, to verb: Verb) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        let previousVerb = plan[idx].verb
        plan[idx].verb = verb
        // Switching AWAY from edit clears any saved split — there's no
        // sensible interpretation of "split this commit, but it's a pick"
        if previousVerb == .edit && verb != .edit {
            plan[idx].editPlan = nil
        }
        // Same idea for reword: leaving the verb discards the pending
        // new message so the row reverts to displaying the original.
        if previousVerb == .reword && verb != .reword {
            plan[idx].newMessage = nil
            if rewordSheetCommitID == id { rewordSheetCommitID = nil }
        }
        recomputeChangedFlag()
        // Switching TO edit auto-opens the split sheet so the user
        // doesn't have to discover a separate action — the verb itself
        // implies "I want to break this apart."
        if verb == .edit && previousVerb != .edit {
            splitSheetCommitID = id
        }
        // Same idea for reword: open the reword sheet so the user can
        // type the new subject immediately.
        if verb == .reword && previousVerb != .reword {
            rewordSheetCommitID = id
        }
    }

    /// Re-open the reword sheet for an already-reworded row. Bound to
    /// the chip menu's "Edit message…" entry.
    func openRewordSheet(for id: String) {
        guard let item = plan.first(where: { $0.id == id }), item.verb == .reword else { return }
        rewordSheetCommitID = id
    }

    /// Commit the new full message from the sheet. Empty / unchanged
    /// from the passed-in original → revert reword state and drop verb
    /// back to .pick; otherwise promote verb to .reword and store the
    /// new message verbatim.
    func saveReword(_ id: String, newMessage: String, original: String) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        let trimmedNew = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNew.isEmpty || trimmedNew == trimmedOriginal {
            plan[idx].newMessage = nil
            if plan[idx].verb == .reword { plan[idx].verb = .pick }
        } else {
            plan[idx].newMessage = trimmedNew
            plan[idx].verb = .reword
        }
        rewordSheetCommitID = nil
        recomputeChangedFlag()
    }

    func cancelReword() {
        // If the user opened the sheet via "promote to reword" but
        // dismissed without saving any new message, the .reword verb
        // would leave the row marked but accomplish nothing at apply
        // time. Revert to .pick in that case so the row matches what
        // will actually happen.
        if let id = rewordSheetCommitID,
           let idx = plan.firstIndex(where: { $0.id == id }),
           plan[idx].verb == .reword,
           plan[idx].newMessage == nil {
            plan[idx].verb = .pick
            recomputeChangedFlag()
        }
        rewordSheetCommitID = nil
    }

    /// Re-open the split sheet for an already-edit row. Bound to a
    /// "Split…" affordance on edit-marked rows.
    func openSplitSheet(for id: String) {
        guard let item = plan.first(where: { $0.id == id }), item.verb == .edit else { return }
        splitSheetCommitID = id
    }

    func setEditPlan(of id: String, to plan: EditPlan?) {
        guard let idx = self.plan.firstIndex(where: { $0.id == id }) else { return }
        self.plan[idx].editPlan = plan
        recomputeChangedFlag()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        plan.move(fromOffsets: offsets, toOffset: destination)
        recomputeChangedFlag()
    }

    func selectCommit(_ id: String?) {
        selectedID = id
        loadDiffForSelection()
    }

    private func loadDiffForSelection() {
        guard let id = selectedID, let item = plan.first(where: { $0.id == id }),
              let repo = repoURL else {
            diffText = ""
            return
        }
        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        do {
            diffText = try engine.diff(for: item.commit.fullHash)
        } catch {
            diffText = "Could not load diff:\n\(error.localizedDescription)"
        }
    }

    private func recomputeChangedFlag() {
        let reordered = plan.map(\.id) != originalOrder
        let anyNonPick = plan.contains { $0.verb != .pick }
        hasChanges = reordered || anyNonPick
    }

    // MARK: - Apply

    /// In-flight rebase state when paused on a conflict. Carries the
    /// engine's ActiveRebase so continue/skip/abort can resume the loop
    /// without rebuilding env/temp files. Nil whenever no rebase is
    /// paused waiting for user resolution.
    @Published var activeRebase: RebaseEngine.ActiveRebase?

    /// Files git currently considers unmerged. Mirrors the conflict
    /// outcome's file list and is refreshed by the conflict sheet's
    /// Refresh button so the user's "did I resolve everything?" view is
    /// always live.
    @Published var conflictedFiles: [String] = []

    /// Editable view of the rebase TODO file's remaining commits while
    /// paused on a conflict. The conflict sheet renders these as a
    /// drag-reorderable list; on Continue we write them back to
    /// `.git/rebase-merge/git-rebase-todo` so git picks up the new
    /// ordering for the rest of the rebase.
    @Published var remainingTodo: [PlanItem] = []

    /// Cached hunk counts keyed by full SHA. Populated lazily after
    /// each plan load via a background task running one `git diff-tree`
    /// per commit. Used by the verb chip menu to disable the `edit`
    /// option on commits with fewer than 2 hunks (splitting can't
    /// produce more commits than there are hunks).
    @Published var hunkCounts: [String: Int] = [:]

    func apply() async {
        guard let repo = repoURL, !plan.isEmpty, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        do {
            let (outcome, active) = try engine.apply(plan: plan, base: baseHash)
            handleOutcome(outcome, active: active, repo: repo, engine: engine)
        } catch {
            actionMessage = "Apply failed: \(error.localizedDescription)"
            lastOutcome = RebaseOutcome(kind: .failed, log: error.localizedDescription, backupRef: "")
        }
    }

    /// Resume a conflicted rebase after the user resolved the files.
    /// Engine runs `git rebase --continue` then re-enters the pause
    /// loop. Resulting outcome may itself be conflicted (next commit
    /// also conflicts), success, or failed.
    func continueAfterConflict() async {
        guard let repo = repoURL, let active = activeRebase, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        do {
            // Flush any reorder the user made in the conflict sheet so
            // git uses the new ordering for the rest of the rebase.
            try engine.writeRemainingTodo(remainingTodo)
            let (outcome, next) = try engine.continueAfterConflict(plan: plan, active: active)
            handleOutcome(outcome, active: next, repo: repo, engine: engine)
        } catch {
            actionMessage = "Continue failed: \(error.localizedDescription)"
            lastOutcome = RebaseOutcome(kind: .failed, log: error.localizedDescription, backupRef: active.backupRef)
        }
    }

    /// `git rebase --skip`: drop the conflicting commit and continue
    /// with the rest of the plan. Same outcome shape as continue.
    func skipConflictedCommit() async {
        guard let repo = repoURL, let active = activeRebase, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        do {
            // Same flush as Continue: --skip drops the failing commit
            // but proceeds with whatever's in the todo file.
            try engine.writeRemainingTodo(remainingTodo)
            let (outcome, next) = try engine.skipConflict(plan: plan, active: active)
            handleOutcome(outcome, active: next, repo: repo, engine: engine)
        } catch {
            actionMessage = "Skip failed: \(error.localizedDescription)"
            lastOutcome = RebaseOutcome(kind: .failed, log: error.localizedDescription, backupRef: active.backupRef)
        }
    }

    /// User-driven `git rebase --abort` + restore from backup ref.
    /// Always terminal; clears active state and reloads.
    func abortConflictedRebase() async {
        guard let repo = repoURL, let active = activeRebase else { return }
        isApplying = true
        defer { isApplying = false }
        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        let outcome = engine.abortConflict(active: active)
        handleOutcome(outcome, active: nil, repo: repo, engine: engine)
    }

    /// Re-poll git for the current set of unmerged paths. Bound to the
    /// conflict sheet's Refresh button.
    func refreshConflictedFiles() {
        guard let repo = repoURL, activeRebase != nil else { return }
        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        conflictedFiles = engine.unmergedFiles()
    }

    private func handleOutcome(
        _ outcome: RebaseOutcome,
        active: RebaseEngine.ActiveRebase?,
        repo: URL,
        engine: RebaseEngine
    ) {
        lastOutcome = outcome
        switch outcome.kind {
        case .success:
            activeRebase = nil
            conflictedFiles = []
            // load() clears actionMessage so the live "Loaded N..." text
            // shows. The result sheet already surfaces success + backup
            // ref; pinning a transient status here would just go stale
            // on the next plan change.
            load(repo: repo)
        case .failed:
            activeRebase = nil
            conflictedFiles = []
            // Belt-and-suspenders: if the engine left a rebase in flight
            // on a non-conflict failure, abort + restore here.
            try? engine.abort()
            try? engine.restore(from: outcome.backupRef)
            actionMessage = "Rebase failed. Restored from backup."
            load(repo: repo)
        case .conflicted(let files):
            activeRebase = active
            conflictedFiles = files
            actionMessage = "Conflict in \(files.count) file\(files.count == 1 ? "" : "s") — resolve and continue."
            // Snapshot the remaining-todo so the sheet can offer
            // reorder. Reads from `.git/rebase-merge/git-rebase-todo`,
            // which contains the lines git hasn't processed yet.
            remainingTodo = engine.readRemainingTodo() ?? []
        }
    }

    /// Drag-reorder support for `remainingTodo`. The conflict sheet
    /// binds onMove to this; the change is in-memory until Continue
    /// flushes it to disk.
    func moveRemainingTodo(from offsets: IndexSet, to destination: Int) {
        remainingTodo.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Re-read the remaining-todo from disk. Useful if something else
    /// touched the file (unlikely outside test scenarios).
    func refreshRemainingTodo() {
        guard let repo = repoURL, activeRebase != nil else { return }
        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        remainingTodo = engine.readRemainingTodo() ?? []
    }
}
