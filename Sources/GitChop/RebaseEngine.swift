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

    /// Load commits for the plan. Two modes:
    ///   • `customBase == nil` (default): load up to `depth` most recent
    ///     commits and use the (depth+1)th as the rebase base.
    ///   • `customBase != nil`: load every non-merge commit between that
    ///     SHA and HEAD; depth is ignored. This is the "Use as base"
    ///     flow — user explicitly picks where the rebase starts instead
    ///     of counting commits.
    ///
    /// Returns the commits oldest-first (matching `git rebase -i`'s
    /// TODO order), the base commit's SHA, the branch name, and
    /// `chopableTotal` — the upper bound on how many commits could
    /// load into the plan in depth-mode, or the actual plan size in
    /// custom-base mode.
    func loadPlan(depth: Int = 12, customBase: String? = nil) throws -> (
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
        // Format string is shared between depth-mode and custom-base
        // mode so parsing is uniform.
        // %x09 = TAB. Split on TAB so subjects with spaces stay intact.
        // Format: full-sha \t short-sha \t author \t date \t unix-ts \t subject
        let format = "%H%x09%h%x09%an%x09%ad%x09%ct%x09%s"

        // Custom-base mode: load every non-merge commit between
        // <customBase> and HEAD, no depth cap. The user explicitly
        // chose this base, so we don't second-guess by counting.
        if let customBase = customBase {
            let logResult = try runner.run([
                "log", "--no-merges",
                "--date=format:%b %-d, %Y",
                "--pretty=format:\(format)",
                "\(customBase)..HEAD",
            ])
            guard logResult.isSuccess else {
                throw EngineError.gitFailed("git log \(customBase)..HEAD: \(logResult.stderr)")
            }
            let planCommits: [Commit] = logResult.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .reversed()
                .compactMap(Self.parseCommitLine)
            guard !planCommits.isEmpty else {
                throw EngineError.tooFewCommits
            }
            return (
                plan: planCommits.map { PlanItem(commit: $0, verb: .pick) },
                base: customBase,
                branch: branch,
                // No "load more" affordance in custom-base mode — the
                // user fixed the start point, so this IS the total.
                chopableTotal: planCommits.count
            )
        }

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
            .compactMap(Self.parseCommitLine)

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

    /// Parse a single TAB-separated `git log --pretty=format` line into
    /// a Commit. Returns nil for malformed lines so the caller can
    /// `compactMap` over a streamed log.
    private static func parseCommitLine(_ line: any StringProtocol) -> Commit? {
        let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        return Commit(
            fullHash: String(parts[0]),
            shortHash: String(parts[1]),
            subject: String(parts[5]),
            author: String(parts[2]),
            date: String(parts[3]),
            timestamp: TimeInterval(String(parts[4])) ?? 0
        )
    }

    /// Patch + stat for a single commit, used by the diff pane.
    func diff(for hash: String) throws -> String {
        let result = try runner.run(["show", "--stat", "--patch", "--no-color", hash])
        return result.stdout
    }

    /// Hunk count for a single commit. Used to decide whether the
    /// `edit` verb is meaningful on a row (needs ≥ 2 hunks to actually
    /// split into multiple commits). `--root` makes this work for the
    /// initial commit too (diff against the empty tree).
    func hunkCount(for sha: String) -> Int {
        guard let result = try? runner.run([
            "diff-tree", "--no-commit-id", "-p", "--no-color", "--root", sha
        ]) else { return 0 }
        guard result.isSuccess else { return 0 }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("@@ ") }
            .count
    }

    // MARK: - Apply

    /// Mutable state for an in-flight rebase. Carries the env we built
    /// at start (so continues see the same GIT_EDITOR / reword wiring),
    /// the backup ref, the temp files we own, and the accumulated log.
    /// `cleanup()` is called by the engine on terminal outcomes
    /// (success / failed / aborted) — not on `.conflicted`, which keeps
    /// the rebase alive for user resolution.
    final class ActiveRebase {
        let env: [String: String]
        let backupRef: String
        let todoFile: URL
        let rewordDir: URL?
        let rewordHelper: URL?
        var log: String

        init(env: [String: String], backupRef: String, todoFile: URL, rewordDir: URL?, rewordHelper: URL?, log: String) {
            self.env = env
            self.backupRef = backupRef
            self.todoFile = todoFile
            self.rewordDir = rewordDir
            self.rewordHelper = rewordHelper
            self.log = log
        }

        func cleanup() {
            let fm = FileManager.default
            try? fm.removeItem(at: todoFile)
            if let d = rewordDir { try? fm.removeItem(at: d) }
            if let h = rewordHelper { try? fm.removeItem(at: h) }
        }
    }

    func apply(plan: [PlanItem], base: String) throws -> (RebaseOutcome, ActiveRebase?) {
        // 0. Stale-rebase guard. If `.git/rebase-merge` is already on
        //    disk (previous session crashed, force-quit, etc.), git
        //    will refuse to start a new rebase. Auto-abort the stale
        //    state — the user clicked Apply with intent to start fresh,
        //    and the in-flight rebase is no longer reachable from the
        //    UI (no ActiveRebase reference exists).
        if isRebaseInProgress() {
            _ = try? runner.run(["rebase", "--abort"])
        }

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
        // No defer-cleanup of todoFile here: the file lifetime is owned
        // by the returned ActiveRebase, which cleans up on terminal
        // outcomes (success / failed / aborted). A `.conflicted` outcome
        // keeps the rebase alive across user resolution and continues.

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
        // (No defer-cleanup; lifetime owned by the ActiveRebase below.)

        let active = ActiveRebase(
            env: env,
            backupRef: backupRef,
            todoFile: todoFile,
            rewordDir: rewordDir,
            rewordHelper: rewordHelperFile,
            log: ""
        )

        // 4. Start the rebase. `--no-autostash` so we never silently
        //    stash the user's working-tree changes; if anything's
        //    uncommitted, git refuses cleanly instead of corrupting
        //    state.
        let firstResult = try runner.run(["rebase", "-i", "--no-autostash", base], env: env)
        active.log += format(result: firstResult, label: "rebase -i")

        return try driveLoop(plan: plan, active: active)
    }

    /// Resume after the user resolved conflicts and asked GitChop to
    /// continue. Runs `git rebase --continue` and re-enters the pause
    /// loop. Returns the new outcome (success / failed / conflicted again).
    func continueAfterConflict(plan: [PlanItem], active: ActiveRebase) throws -> (RebaseOutcome, ActiveRebase?) {
        let cont = try runner.run(["rebase", "--continue"], env: active.env)
        active.log += format(result: cont, label: "rebase --continue")
        return try driveLoop(plan: plan, active: active)
    }

    /// `git rebase --skip` — drop the conflicted commit and continue
    /// with the rest of the plan.
    func skipConflict(plan: [PlanItem], active: ActiveRebase) throws -> (RebaseOutcome, ActiveRebase?) {
        let skip = try runner.run(["rebase", "--skip"], env: active.env)
        active.log += format(result: skip, label: "rebase --skip")
        return try driveLoop(plan: plan, active: active)
    }

    /// `git rebase --abort` + restore from backup. Always terminal —
    /// cleans up temp files and returns a failed outcome.
    func abortConflict(active: ActiveRebase) -> RebaseOutcome {
        _ = try? runner.run(["rebase", "--abort"])
        try? restore(from: active.backupRef)
        active.log += "\nAborted by user.\n"
        let log = active.log
        let backup = active.backupRef
        active.cleanup()
        return RebaseOutcome(kind: .failed, log: log, backupRef: backup)
    }

    // MARK: - Driver

    /// The pause loop. Called fresh from `apply` and re-entered from
    /// continue/skip after the user resolves a conflict. Returns either
    /// a terminal outcome (cleanup performed, second tuple element nil)
    /// or `.conflicted(files)` (rebase still in flight, ActiveRebase
    /// returned for the caller to drive).
    private func driveLoop(plan: [PlanItem], active: ActiveRebase) throws -> (RebaseOutcome, ActiveRebase?) {
        var safetyCounter = 0
        while isRebaseInProgress() {
            safetyCounter += 1
            if safetyCounter > plan.count + 4 {
                // Defensive: shouldn't ever loop more times than there
                // are commits in the plan plus a small fudge factor.
                active.log += "\n!! pause loop exceeded safety bound; aborting\n"
                _ = try? runner.run(["rebase", "--abort"])
                let log = active.log
                let backup = active.backupRef
                active.cleanup()
                return (RebaseOutcome(kind: .failed, log: log, backupRef: backup), nil)
            }

            // Conflict gate: if there are unmerged paths, hand control
            // back to the user before attempting any continue. The
            // rebase stays in-flight; the ActiveRebase carries the
            // state needed to resume.
            let conflicts = unmergedFiles()
            if !conflicts.isEmpty {
                return (RebaseOutcome(kind: .conflicted(files: conflicts), log: active.log, backupRef: active.backupRef), active)
            }

            let stoppedSha = readStoppedSha()
            if let sha = stoppedSha,
               let item = plan.first(where: { $0.commit.fullHash == sha
                                              || $0.commit.fullHash.hasPrefix(sha) }) {
                if item.verb == .edit, let editPlan = item.editPlan, !editPlan.buckets.isEmpty {
                    do {
                        let splitLog = try runSplit(plan: editPlan, originalSubject: item.commit.subject)
                        active.log += "\n── Splitting \(item.commit.shortHash) into \(editPlan.buckets.count) commits ──\n\(splitLog)"
                    } catch let e {
                        active.log += "\n!! split failed for \(item.commit.shortHash): \(e.localizedDescription)\n"
                        _ = try? runner.run(["rebase", "--abort"])
                        let log = active.log
                        let backup = active.backupRef
                        active.cleanup()
                        return (RebaseOutcome(kind: .failed, log: log, backupRef: backup), nil)
                    }
                } else if item.verb == .edit {
                    active.log += "\n── Pausing on edit \(item.commit.shortHash) (no split plan, continuing) ──\n"
                }
            }

            let cont = try runner.run(["rebase", "--continue"], env: active.env)
            active.log += format(result: cont, label: "rebase --continue")
            if !cont.isSuccess {
                // Continue failed. If unmerged files appeared, surface
                // as conflict.
                let conflictsAfter = unmergedFiles()
                if !conflictsAfter.isEmpty {
                    return (RebaseOutcome(kind: .conflicted(files: conflictsAfter), log: active.log, backupRef: active.backupRef), active)
                }
                // Empty-cherry-pick recovery. After a successful merge
                // (no remaining unmerged paths), --continue can still
                // exit non-zero if the resolved tree introduces no
                // changes — git refuses empty commits and asks for
                // --skip or --allow-empty. Auto-skip: the conflicting
                // commit's content is already present in HEAD from an
                // earlier rebase step, so dropping it is the right
                // outcome ~99% of the time. Detected via stderr text
                // because there's no exit code that distinguishes this
                // from other failure modes.
                let stderr = cont.stderr.lowercased()
                let stdout = cont.stdout.lowercased()
                let isEmpty = (stderr.contains("now empty")
                               || stdout.contains("now empty")
                               || stderr.contains("nothing to commit")
                               || stdout.contains("nothing to commit"))
                if isEmpty && isRebaseInProgress() {
                    active.log += "\n  Empty cherry-pick — auto-skipping.\n"
                    let skip = try runner.run(["rebase", "--skip"], env: active.env)
                    active.log += format(result: skip, label: "rebase --skip (auto, empty)")
                    if !skip.isSuccess {
                        // --skip itself failed — bail out as terminal.
                        break
                    }
                    // Loop back; next iteration's gate decides what's
                    // next (success / pause / new conflict).
                    continue
                }
                break
            }
        }

        // Terminal: rebase-merge is gone (success) or break-out from a
        // failed continue with no conflict (treated as failure).
        let success = !isRebaseInProgress()
        let log = active.log
        let backup = active.backupRef
        active.cleanup()
        return (
            RebaseOutcome(kind: success ? .success : .failed, log: log, backupRef: backup),
            nil
        )
    }

    // MARK: - Remaining-todo I/O (mid-rebase reorder)

    /// Read `.git/rebase-merge/git-rebase-todo` — the list of commits
    /// git hasn't processed yet — into editable PlanItems. Comments
    /// and blank lines are skipped. Returns nil if there's no rebase
    /// in flight or the file is missing.
    ///
    /// Subjects come straight from the TODO line (which we wrote when
    /// starting the rebase). Author/date aren't in the TODO so we leave
    /// them blank — the conflict sheet's reorder list doesn't need them.
    func readRemainingTodo() -> [PlanItem]? {
        let path = runner.cwd.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        var items: [PlanItem] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Format: "<verb> <full-sha> <subject…>"
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, let verb = Verb(rawValue: parts[0]) else { continue }
            let sha = parts[1]
            let subject = parts.count > 2 ? parts[2] : ""
            let commit = Commit(
                fullHash: sha,
                shortHash: String(sha.prefix(7)),
                subject: subject,
                author: "",
                date: "",
                timestamp: 0
            )
            items.append(PlanItem(commit: commit, verb: verb))
        }
        return items
    }

    /// Overwrite `.git/rebase-merge/git-rebase-todo` with the user's
    /// reordered list. Called just before `git rebase --continue` so
    /// git picks up the new ordering for the remaining work.
    func writeRemainingTodo(_ items: [PlanItem]) throws {
        let path = runner.cwd.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
        let lines = items.map { item in
            "\(item.verb.rawValue) \(item.commit.fullHash) \(item.commit.subject)"
        }
        let payload = lines.joined(separator: "\n") + "\n"
        try payload.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Files git considers unmerged in the working tree right now.
    /// Empty when there are no conflicts. Exposed `internal` so the
    /// conflict sheet can refresh state without re-entering the loop.
    func unmergedFiles() -> [String] {
        guard let result = try? runner.run(["diff", "--name-only", "--diff-filter=U"]),
              result.isSuccess else { return [] }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
    ///   2. For each bucket, in order:
    ///        • re-`git diff HEAD` and re-parse — context lines may
    ///          have shifted relative to sheet-time (upstream rebase
    ///          steps modified the same file) and earlier buckets in
    ///          this loop have already moved hunks into commits, so
    ///          the live diff is what `git apply` will be matching
    ///          against
    ///        • match the bucket's saved hunkIDs against the live parse
    ///        • reassemble using LIVE hunks (current line numbers)
    ///        • `git apply --cached --recount`, then commit
    ///   3. If anything's left unstaged after all buckets, commit as a
    ///      "leftover" guard against a stale plan whose hunk IDs no
    ///      longer cover the whole diff.
    ///
    /// Hunk IDs are content-stable (file + the +/- body lines, no line
    /// numbers and no context), so they survive the upstream-context
    /// drift that broke the previous "parse once" approach.
    private func runSplit(plan: EditPlan, originalSubject: String) throws -> String {
        var log = ""

        // 1. Uncommit, keeping working-tree state intact.
        let reset = try runner.run(["reset", "HEAD^"])
        log += "  reset HEAD^ → \(reset.exitCode)\n"
        guard reset.isSuccess else {
            throw EngineError.gitFailed("git reset HEAD^: \(reset.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 2. Apply each bucket in order, re-parsing the live diff
        //    before each one so we always reassemble against the
        //    current state of the working tree.
        for (idx, bucket) in plan.buckets.enumerated() {
            let bucketLabel = "Bucket \(idx + 1) (\(bucket.subject))"

            let diff = try runner.run(["diff", "--no-color", "HEAD"])
            guard diff.isSuccess else {
                throw EngineError.gitFailed("git diff HEAD: \(diff.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let parsed = HunkParser.parse(diff.stdout)
            let liveHunkIDs = Set(parsed.allHunks.map(\.id))
            let validIDs = bucket.hunkIDs.intersection(liveHunkIDs)
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
