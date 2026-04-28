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
    @Published var status: String = "Open a git repo to begin."
    @Published var isApplying = false
    @Published var lastOutcome: RebaseOutcome?

    /// How many commits the user asked us to load. Distinct from
    /// `plan.count` because the engine caps the request at the actual
    /// reachable depth (e.g. asking for 50 in a 24-commit repo loads 24).
    @Published var requestedDepth: Int = 12

    /// Total non-merge commits reachable from HEAD. Used to decide
    /// whether to show "load more" / "load all" affordances.
    @Published var totalNonMergeCount: Int = 0

    /// Default step size for the "Load N more" button.
    /// `nonisolated` so it can be used as a default-argument value in
    /// methods on this @MainActor class without Swift 6 complaining.
    nonisolated static let loadMoreIncrement = 12

    /// True when there's a plan loaded and at least one row has a non-pick
    /// verb or has been reordered. Drives the Apply button's enabled state
    /// — a no-op rebase is harmless but pointless.
    @Published var hasChanges = false

    /// Captured snapshot of the originally-loaded order, used to detect
    /// whether the user has actually edited the plan. Compared by
    /// commit ID + verb on every plan mutation.
    private var originalOrder: [String] = []

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
            let result = try engine.loadPlan(depth: d)
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
            let suffix = plan.count < totalNonMergeCount
                ? " of \(totalNonMergeCount) on \(branch)."
                : " (all) on \(branch)."
            status = "Loaded \(plan.count) commit\(plan.count == 1 ? "" : "s")\(suffix)"
            recomputeChangedFlag()
            loadDiffForSelection()
        } catch {
            status = error.localizedDescription
            plan = []
            baseHash = ""
            totalNonMergeCount = 0
            originalOrder = []
            selectedID = nil
            diffText = ""
            hasChanges = false
        }
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

    // MARK: - Mutate plan

    func setVerb(of id: String, to verb: Verb) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[idx].verb = verb
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

    func apply() async {
        guard let repo = repoURL, !plan.isEmpty, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        do {
            let outcome = try engine.apply(plan: plan, base: baseHash)
            lastOutcome = outcome
            switch outcome.kind {
            case .success:
                status = "Rebase applied. Backup: \(outcome.backupRef)"
                // Reload from the new HEAD so the list reflects the new history.
                load(repo: repo)
            case .failed:
                status = "Rebase failed. Aborting and restoring from backup."
                try? engine.abort()
                try? engine.restore(from: outcome.backupRef)
                load(repo: repo)
            }
        } catch {
            status = "Apply failed: \(error.localizedDescription)"
            lastOutcome = RebaseOutcome(kind: .failed, log: error.localizedDescription, backupRef: "")
        }
    }
}
