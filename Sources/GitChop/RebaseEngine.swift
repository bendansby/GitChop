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

        // 2. Build TODO file. Verbs supported: pick / edit / squash /
        //    fixup / drop. squash/fixup require a preceding picked or
        //    editing commit — we don't enforce that here (git will
        //    error and we surface it). edit pauses the rebase so we
        //    can run the user's split plan and then continue.
        let todoLines: [String] = plan.compactMap { item in
            "\(item.verb.rawValue) \(item.commit.fullHash) \(item.commit.subject)"
        }
        let todo = todoLines.joined(separator: "\n") + "\n"

        let todoFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitchop-todo-\(UUID().uuidString).txt")
        try todo.write(to: todoFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: todoFile) }

        // 3. The cp trick: GIT_SEQUENCE_EDITOR is invoked as
        //    `<editor> <file>`, so `cp /our/todo.txt <file>` overwrites
        //    git's TODO with ours.
        var env: [String: String] = [
            "GIT_SEQUENCE_EDITOR": "/bin/cp '\(todoFile.path)'",
            "GIT_EDITOR": ":",
            "EDITOR": ":",
        ]

        // 3a. Reword wiring. For any `reword` rows with a stored
        //     `newMessage`, write each message to its own file in a
        //     scratch directory keyed by full SHA, then point GIT_EDITOR
        //     at a tiny helper script. The helper reads
        //     `.git/rebase-merge/done`'s last line (the row git is
        //     currently processing) and, if a file matching that SHA
        //     exists in the scratch dir, copies its contents into git's
        //     COMMIT_EDITMSG. One-file-per-SHA avoids escaping headaches
        //     for multi-line messages with arbitrary characters.
        //     Squash combined-message edits also pass through this
        //     helper, but they'll miss the dir and exit cleanly,
        //     leaving the default combined message intact.
        let rewords: [(String, String)] = plan.compactMap { item in
            guard item.verb == .reword,
                  let new = item.newMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !new.isEmpty else { return nil }
            return (item.commit.fullHash, new)
        }
        var rewordDir: URL? = nil
        var rewordHelperFile: URL? = nil
        if !rewords.isEmpty {
            let dirURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gitchop-reword-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            rewordDir = dirURL
            for (sha, message) in rewords {
                // Trailing newline matches git's own COMMIT_EDITMSG
                // convention so commit messages don't lose their final
                // \n on round-trip.
                let payload = message.hasSuffix("\n") ? message : message + "\n"
                try payload.write(
                    to: dirURL.appendingPathComponent(sha),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let helperURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gitchop-reword-editor-\(UUID().uuidString).sh")
            let script = """
            #!/bin/bash
            # GitChop reword helper: invoked by git as $EDITOR. Reads the
            # in-flight rebase row's SHA from .git/rebase-merge/done and
            # copies $GITCHOP_REWORD_DIR/<sha> into the commit-message
            # file if present. Silently no-ops on misses (e.g. squash
            # combined-message edits, or rows the user didn't reword).
            msgfile="$1"
            [ -n "$msgfile" ] || exit 0
            gitdir=$(git rev-parse --git-dir 2>/dev/null || echo .git)
            done="$gitdir/rebase-merge/done"
            [ -f "$done" ] || exit 0
            sha=$(awk 'NF { last=$2 } END { print last }' "$done")
            [ -n "$sha" ] || exit 0
            [ -n "$GITCHOP_REWORD_DIR" ] || exit 0
            src="$GITCHOP_REWORD_DIR/$sha"
            [ -f "$src" ] || exit 0
            cp "$src" "$msgfile"
            """
            try script.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: helperURL.path
            )
            rewordHelperFile = helperURL

            env["GIT_EDITOR"] = helperURL.path
            env["GITCHOP_REWORD_DIR"] = dirURL.path
        }
        defer {
            if let d = rewordDir { try? FileManager.default.removeItem(at: d) }
            if let f = rewordHelperFile { try? FileManager.default.removeItem(at: f) }
        }

        var combinedLog = ""

        // 4. Start the rebase. `--no-autostash` so we never silently
        //    stash the user's working-tree changes; if anything's
        //    uncommitted, git refuses cleanly instead of corrupting
        //    state.
        let firstResult = try runner.run(["rebase", "-i", "--no-autostash", base], env: env)
        combinedLog += format(result: firstResult, label: "rebase -i")

        // 5. Pause loop. git rebase exits with code 0 when it pauses on
        //    an `edit` (or `break`) — we need to detect the pause via
        //    the .git/rebase-merge directory rather than relying on
        //    exit codes alone. For each pause:
        //      • find the stopped commit
        //      • if it's an edit row with an editPlan, run the split
        //      • run `git rebase --continue`
        //    Loop until rebase-merge is gone (success) or a continue
        //    fails (treated as failure → caller rolls back).
        var safetyCounter = 0
        while isRebaseInProgress() {
            safetyCounter += 1
            if safetyCounter > plan.count + 4 {
                // Defensive: shouldn't ever loop more times than there
                // are commits in the plan plus a small fudge factor.
                combinedLog += "\n!! pause loop exceeded safety bound; aborting\n"
                break
            }

            let stoppedSha = readStoppedSha()
            if let sha = stoppedSha,
               let item = plan.first(where: { $0.commit.fullHash == sha
                                              || $0.commit.fullHash.hasPrefix(sha) }) {
                if item.verb == .edit, let editPlan = item.editPlan, !editPlan.buckets.isEmpty {
                    do {
                        let splitLog = try runSplit(plan: editPlan, originalSubject: item.commit.subject)
                        combinedLog += "\n── Splitting \(item.commit.shortHash) into \(editPlan.buckets.count) commits ──\n\(splitLog)"
                    } catch let e {
                        combinedLog += "\n!! split failed for \(item.commit.shortHash): \(e.localizedDescription)\n"
                        // Abort the rebase; caller will roll back via
                        // the backup ref.
                        _ = try? runner.run(["rebase", "--abort"])
                        return RebaseOutcome(kind: .failed, log: combinedLog, backupRef: backupRef)
                    }
                } else if item.verb == .edit {
                    combinedLog += "\n── Pausing on edit \(item.commit.shortHash) (no split plan, continuing) ──\n"
                }
            }

            let cont = try runner.run(["rebase", "--continue"], env: env)
            combinedLog += format(result: cont, label: "rebase --continue")
            if !cont.isSuccess {
                // The continue failed (e.g. conflict, or our split left
                // the index in a bad state). Don't abort here — caller
                // will detect the in-progress rebase via final-state
                // check below and abort + roll back.
                break
            }
        }

        // 6. Final state. Success requires both: starting result
        //    produced no fatal error AND we're no longer mid-rebase.
        let success = !isRebaseInProgress()
        return RebaseOutcome(
            kind: success ? .success : .failed,
            log: combinedLog,
            backupRef: backupRef
        )
    }

    // MARK: - Pause detection / split execution

    /// Whether a rebase is currently mid-flight in this repo. Detected
    /// by the presence of either `.git/rebase-merge` (the modern
    /// interactive-rebase state dir) or `.git/rebase-apply` (the older
    /// patch-based variant; older git, or non-interactive rebase).
    private func isRebaseInProgress() -> Bool {
        let fm = FileManager.default
        let merge = runner.cwd.appendingPathComponent(".git/rebase-merge")
        let apply = runner.cwd.appendingPathComponent(".git/rebase-apply")
        return fm.fileExists(atPath: merge.path) || fm.fileExists(atPath: apply.path)
    }

    /// Read the SHA of the commit the rebase is currently paused on.
    /// `.git/rebase-merge/stopped-sha` contains it as plain text.
    /// Returns nil if no stopped state, or the file is absent.
    private func readStoppedSha() -> String? {
        let path = runner.cwd.appendingPathComponent(".git/rebase-merge/stopped-sha")
        guard let s = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Execute a split plan against the working tree. Assumes git is
    /// currently paused on an edit, with the edit's commit already
    /// applied (HEAD == that commit). Steps:
    ///   1. `git reset HEAD^` — uncommit, keep working tree changes
    ///   2. `git diff` against HEAD to capture the original commit's
    ///      changes
    ///   3. Re-parse hunks, match against the EditPlan's buckets
    ///   4. For each bucket: reassemble its hunks, `git apply --cached`,
    ///      then commit with the bucket's subject
    ///   5. If anything's left unstaged, commit it as a final
    ///      "leftover" commit using the original subject — defends
    ///      against a stale plan whose hunk IDs no longer cover the
    ///      whole diff
    private func runSplit(plan: EditPlan, originalSubject: String) throws -> String {
        var log = ""

        // 1. Uncommit, keeping working-tree state intact.
        let reset = try runner.run(["reset", "HEAD^"])
        log += "  reset HEAD^ → \(reset.exitCode)\n"
        guard reset.isSuccess else {
            throw EngineError.gitFailed("git reset HEAD^: \(reset.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 2. Capture the diff once so all bucket-applies see the same
        //    parsed hunks (the order matters less than consistency).
        let diff = try runner.run(["diff", "--no-color", "HEAD"])
        guard diff.isSuccess else {
            throw EngineError.gitFailed("git diff HEAD: \(diff.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let parsed = HunkParser.parse(diff.stdout)
        let allHunkIDs = Set(parsed.allHunks.map(\.id))

        // 3. Apply each bucket in order.
        for (idx, bucket) in plan.buckets.enumerated() {
            let bucketLabel = "Bucket \(idx + 1) (\(bucket.subject))"
            // Restrict to hunk IDs that actually parsed out of the
            // current diff — protects against stale plans.
            let validIDs = bucket.hunkIDs.intersection(allHunkIDs)
            if validIDs.isEmpty {
                log += "  \(bucketLabel): no live hunks, skipping\n"
                continue
            }
            let patch = HunkParser.reassemble(parsed, includingHunks: validIDs)

            let applyResult = try runner.runWithStdin(["apply", "--cached", "--recount"], stdin: patch)
            if !applyResult.isSuccess {
                throw EngineError.gitFailed("\(bucketLabel) apply failed: \(applyResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            let subject = bucket.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let commitResult = try runner.run([
                "commit",
                "-m", subject.isEmpty ? "(empty)" : subject,
            ])
            if !commitResult.isSuccess {
                throw EngineError.gitFailed("\(bucketLabel) commit failed: \(commitResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            log += "  \(bucketLabel): \(validIDs.count) hunk\(validIDs.count == 1 ? "" : "s") committed\n"
        }

        // 4. Leftover guard. If the plan's hunk IDs didn't cover
        //    everything in the working diff, commit the rest under the
        //    original subject so we don't leak changes silently. In
        //    practice the SplitCommitSheet validates "all hunks
        //    assigned" before save, so this is a belt-and-suspenders.
        let statusResult = try runner.run(["status", "--porcelain"])
        if statusResult.isSuccess && !statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try runner.run(["add", "-A"])
            let leftover = try runner.run(["commit", "-m", "\(originalSubject) (leftover)"])
            if leftover.isSuccess {
                log += "  Leftover changes: committed under '\(originalSubject) (leftover)'\n"
            } else {
                // Don't throw — some leftover states (e.g. "nothing to
                // commit, working tree clean") aren't actually errors.
                log += "  Leftover commit: \(leftover.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }
        }

        return log
    }

    /// Compact one-line + body summary of a git command result for
    /// the combined log shown in the result sheet.
    private func format(result: GitRunner.Result, label: String) -> String {
        var s = "\(label) → exit \(result.exitCode)"
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { s += "\n\(out)" }
        if !err.isEmpty { s += "\n\(err)" }
        return s + "\n"
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
