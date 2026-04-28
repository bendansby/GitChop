import SwiftUI
import AppKit

/// Single source of truth for the open repo + plan + diff. Views observe.
@MainActor
final class RebaseSession: ObservableObject {
    @Published var repoURL: URL?
    @Published var branch: String = ""
    @Published var plan: [PlanItem] = []
    @Published var baseHash: String = ""
    @Published var selectedID: String?
    @Published var diffText: String = ""
    @Published var status: String = "Open a git repo to begin."
    @Published var isApplying = false
    @Published var lastOutcome: RebaseOutcome?

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

    // MARK: - Open

    func openPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Pick a git repository."
        if panel.runModal() == .OK, let url = panel.url {
            load(repo: url)
        }
    }

    func load(repo: URL) {
        repoURL = repo
        let engine = RebaseEngine(runner: GitRunner(cwd: repo))
        do {
            let result = try engine.loadPlan(depth: 12)
            plan = result.plan
            baseHash = result.base
            branch = result.branch.isEmpty ? "(detached)" : result.branch
            originalOrder = plan.map(\.id)
            selectedID = plan.last?.id    // most-recent commit selected by default
            status = "Loaded \(plan.count) commit\(plan.count == 1 ? "" : "s") on \(branch)."
            recomputeChangedFlag()
            loadDiffForSelection()
        } catch {
            status = error.localizedDescription
            plan = []
            baseHash = ""
            originalOrder = []
            selectedID = nil
            diffText = ""
            hasChanges = false
        }
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
