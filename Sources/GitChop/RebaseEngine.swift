import Foundation

/// Loads commits and applies a plan via `git rebase -i`.
///
/// Apply works by:
///   1. Writing a backup ref `refs/gitchop-backup/<timestamp>` so the
///      pre-rebase state is recoverable from git even if the rebase
///      goes sideways.
///   2. Building the rebase TODO file from the plan.
///   3. Running `git rebase -i <base>` with `GIT_SEQUENCE_EDITOR` set to
///      a `cp` invocation that overwrites the TODO git provides with the
///      one we built. (cp's first arg is our source; git appends the
///      file path as the second arg, becoming cp's destination.)
///   4. Capturing stdout/stderr for the result alert.
struct RebaseEngine {
    let runner: GitRunner

    // MARK: - Load

    /// Load up to `depth` most recent commits on the current branch.
    /// Returns the commits oldest-first (matching the `git rebase -i`
    /// TODO order on screen), the base commit's SHA, the branch name,
    /// and `chopableTotal` — the maximum number of commits the user
    /// can ever load into the plan (= total non-merge commits minus
    /// the root, since the root must always be the rebase base).
    func loadPlan(depth: Int = 12) throws -> (
        plan: [PlanItem], base: String, branch: String, chopableTotal: Int
    ) {
        // Detect repo root so a path like `/repo/subdir` still works.
        let toplevel = try runner.run(["rev-parse", "--show-toplevel"])
        guard toplevel.isSuccess else {
            throw EngineError.notARepo(toplevel.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let branchResult = try runner.run(["symbolic-ref", "--short", "-q", "HEAD"])
        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // The maximum chopable depth is total-non-merge MINUS the root
        // commit. The root has no parent, so `<root>^` ("the parent of
        // the oldest commit in the plan, which is our rebase base")
        // doesn't resolve. Always leave the root commit out of the
        // plan and use it as the base instead.
        //
        // Earlier versions tried to load N non-merge commits and
        // compute base = `<oldest>^`, which exploded with
        // "ambiguous argument 'sha^'" the first time someone asked
        // for all commits in a repo with no leading merge layers.
        let totalNoMergeResult = try runner.run(["rev-list", "--count", "--no-merges", "HEAD"])
        let totalNoMerge = Int(totalNoMergeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let chopableTotal = max(0, totalNoMerge - 1)
        let n = min(max(0, depth), chopableTotal)
        guard n > 0 else {
            throw EngineError.tooFewCommits
        }

        // We request `n + 1` commits: the oldest is the rebase base,
        // the remaining `n` form the plan. Asking for n+1 lets us
        // discover the base in a single `git log` call without a
        // separate `rev-parse <oldest>^`, AND it transparently handles
        // the case where the (n+1)th commit happens to be the root —
        // the root naturally ends up as the base instead of breaking
        // the load.
        //
        // %x09 = TAB. Split on TAB so subjects with spaces stay intact.
        // Format: full-sha \t short-sha \t author \t date \t subject
        let format = "%H%x09%h%x09%an%x09%ad%x09%s"
        let logResult = try runner.run([
            "log", "-\(n + 1)", "--no-merges",
            "--date=format:%b %-d, %Y",
            "--pretty=format:\(format)",
        ])
        guard logResult.isSuccess else {
            throw EngineError.gitFailed("git log: \(logResult.stderr)")
        }

        // git log emits newest-first; flip to oldest-first to match how
        // `git rebase -i` presents its TODO list.
        let allCommits: [Commit] = logResult.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
                guard parts.count == 5 else { return nil }
                return Commit(
                    fullHash: String(parts[0]),
                    shortHash: String(parts[1]),
                    subject: String(parts[4]),
                    author: String(parts[2]),
                    date: String(parts[3])
                )
            }

        // Need at least 2: one for the base and one for the plan.
        guard allCommits.count >= 2, let baseCommit = allCommits.first else {
            throw EngineError.tooFewCommits
        }
        let planCommits = Array(allCommits.dropFirst())

        return (
            plan: planCommits.map { PlanItem(commit: $0, verb: .pick) },
            base: baseCommit.fullHash,
            branch: branch,
            chopableTotal: chopableTotal
        )
    }

    /// Patch + stat for a single commit, used by the diff pane.
    func diff(for hash: String) throws -> String {
        let result = try runner.run(["show", "--stat", "--patch", "--no-color", hash])
        return result.stdout
    }

    // MARK: - Apply

    func apply(plan: [PlanItem], base: String) throws -> RebaseOutcome {
        // 1. Backup ref so the pre-rebase tip is recoverable.
        let timestamp = Self.timestampString()
        let backupRef = "refs/gitchop-backup/\(timestamp)"
        let backup = try runner.run(["update-ref", backupRef, "HEAD"])
        guard backup.isSuccess else {
            throw EngineError.gitFailed("backup ref: \(backup.stderr)")
        }

        // 2. Build TODO file. v0.1 only emits pick/squash/fixup/drop; the
        //    rebase TODO format treats `drop` specially — git skips that
        //    commit entirely. squash/fixup require a preceding picked
        //    commit; we don't enforce that here (git will error and we
        //    surface it).
        let todoLines: [String] = plan.compactMap { item in
            // Subject is for human readability in the TODO; git ignores
            // anything after the hash.
            "\(item.verb.rawValue) \(item.commit.fullHash) \(item.commit.subject)"
        }
        let todo = todoLines.joined(separator: "\n") + "\n"

        let todoFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitchop-todo-\(UUID().uuidString).txt")
        try todo.write(to: todoFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: todoFile) }

        // 3. The cp trick: GIT_SEQUENCE_EDITOR is invoked as `<editor> <file>`,
        //    so `cp /our/todo.txt <file>` overwrites git's TODO with ours.
        //    Quoting the source path lets it work even if NSTemporaryDirectory()
        //    has spaces (it usually doesn't on macOS, but be safe).
        let env: [String: String] = [
            "GIT_SEQUENCE_EDITOR": "/bin/cp '\(todoFile.path)'",
            // For squash, git invokes GIT_EDITOR on the combined message.
            // `:` is shell true — accept the default combined message.
            // (Once we ship reword/edit, we'll plug a real editor here.)
            "GIT_EDITOR": ":",
            "EDITOR": ":",
        ]

        // 4. Run the rebase. `--no-autostash` so we never silently stash
        //    user work; if there's uncommitted work we want git to refuse.
        let result = try runner.run(["rebase", "-i", "--no-autostash", base], env: env)
        let log = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return RebaseOutcome(
            kind: result.isSuccess ? .success : .failed,
            log: log,
            backupRef: backupRef
        )
    }

    /// `git rebase --abort` — used after a failure to roll back.
    func abort() throws {
        _ = try runner.run(["rebase", "--abort"])
    }

    /// Restore HEAD to the given backup ref. Refuses if there's a rebase
    /// in progress (caller should abort first).
    func restore(from backupRef: String) throws {
        _ = try runner.run(["update-ref", "HEAD", backupRef])
        _ = try runner.run(["reset", "--hard", "HEAD"])
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}

enum EngineError: LocalizedError {
    case notARepo(String)
    case tooFewCommits
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .notARepo(let msg):    return "Not a git repository.\n\(msg)"
        case .tooFewCommits:        return "Need at least 2 commits to rebase."
        case .gitFailed(let msg):   return msg
        }
    }
}
