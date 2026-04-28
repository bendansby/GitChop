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
    /// and the total number of non-merge commits reachable from HEAD
    /// (used by the UI to decide whether to show "load more").
    func loadPlan(depth: Int = 12) throws -> (
        plan: [PlanItem], base: String, branch: String, totalNonMerge: Int
    ) {
        // Detect repo root so a path like `/repo/subdir` still works.
        let toplevel = try runner.run(["rev-parse", "--show-toplevel"])
        guard toplevel.isSuccess else {
            throw EngineError.notARepo(toplevel.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let branchResult = try runner.run(["symbolic-ref", "--short", "-q", "HEAD"])
        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cap depth at the actual reachable count so a tiny repo doesn't
        // blow up trying to resolve HEAD~depth. We use the non-merge
        // count for the cap because the loaded list and the "total"
        // shown to the user both use --no-merges; otherwise the cap
        // would let us request a depth we can never display.
        let totalResult = try runner.run(["rev-list", "--count", "HEAD"])
        let totalAll = Int(totalResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let totalNoMergeResult = try runner.run(["rev-list", "--count", "--no-merges", "HEAD"])
        let totalNoMerge = Int(totalNoMergeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let n = min(depth, max(0, totalAll - 1))   // need at least one ancestor as base
        guard n > 0 else {
            throw EngineError.tooFewCommits
        }

        // %x09 = TAB. We split on TAB to keep subjects with spaces intact.
        // Format: full-sha \t short-sha \t author \t date \t subject
        let format = "%H%x09%h%x09%an%x09%ad%x09%s"
        let logResult = try runner.run([
            "log", "-\(n)", "--no-merges",
            "--date=format:%b %-d, %Y",
            "--pretty=format:\(format)",
        ])
        guard logResult.isSuccess else {
            throw EngineError.gitFailed("git log: \(logResult.stderr)")
        }

        // git log emits newest-first; flip to oldest-first to match how
        // `git rebase -i` presents its TODO list.
        let commits: [Commit] = logResult.stdout
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

        guard let oldest = commits.first else {
            throw EngineError.tooFewCommits
        }
        let baseResult = try runner.run(["rev-parse", "\(oldest.fullHash)^"])
        guard baseResult.isSuccess else {
            throw EngineError.gitFailed("rev-parse base: \(baseResult.stderr)")
        }
        let base = baseResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            plan: commits.map { PlanItem(commit: $0, verb: .pick) },
            base: base,
            branch: branch,
            totalNonMerge: totalNoMerge
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
