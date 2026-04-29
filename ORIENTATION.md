# GitChop — orientation

A Mac-native `git rebase -i` that doesn't drop you into a TODO file.

Pitch: *"I made `git rebase -i` not suck."* The killer differentiator vs.
Tower / Fork / GitHub Desktop is **split-commit-in-window** — the `edit`
verb done as a hunk-staging UI rather than a `--continue` dance. Magit
has had this on Emacs for 15 years; nothing else on macOS does.

Currently at **0.2 (preview)**. macOS 14+. Bundle ID
`com.bendansby.GitChop`. Not yet shipped publicly; no Sparkle feed yet.

If you want to know *why* a thing is the way it is, read `DECISIONS.md`.
If you want to know *what's next*, read `BACKLOG.md`.

---

## Try it in five minutes

```bash
# 1. Build and install GitChop locally
bash scripts/build-app.sh

# 2. Generate a self-contained sample repo at Sample Project/repo/
bash "Sample Project/init.sh"

# 3. In GitChop, hit "Open Repo…" and point it at:
#    Mac Apps/GitChop/Sample Project/repo
```

The sample is a small bash CLI project (`tabby` — CSV/Markdown/JSON
table converter) with 26 commits across three authors, two merged
feature/bugfix branches, and a deliberate 12-commit "local WIP" tail
that exercises every rebase verb:

- **drop**     "WIP: starting TOML output (probably won't ship)"
- **fixup**    "Fix JSON output: don't double-escape" → into "Start JSON output support"
- **squash**   "Add CSV→JSON output test" → with "Start JSON output support"
- **reorder**  "Fix CI: install jq…" should land near the JSON feature commit
- **edit**     pick any non-trivial commit and split it across two buckets

The init script ends by printing the graph and a guided practice list.
Re-running it deletes and regenerates the sample, so it's safe to chop,
mess up, and reset.

`Sample Project/repo/` is its own self-contained git repo (gitignored
by GitChop's outer repo). That's why opening it in GitChop shows the
sample's history rather than GitChop's own — `git rev-parse
--show-toplevel` stops at the nearest `.git`, which is the sample's,
not the outer one.

---

## Layout

```
GitChop/
  Package.swift                — SwiftPM, single executable target
  GitChop.entitlements         — empty; intentionally NOT sandboxed
                                 (sandbox blocks subprocess + arbitrary FS)
  Icon.png                     — generated from scripts/render-icon.py
  Resources/
    Info.plist                 — bundle identity, version
  Sources/GitChop/
    GitChopApp.swift           — @main scene, Open-Repo / Close-Tab commands
    Workspace.swift            — top-level state: N RebaseSessions + persistence
    RebaseSession.swift        — per-repo: plan, diff, status, isApplying
    RebaseEngine.swift         — load + apply + pause-loop + split execution
    GitRunner.swift            — Process wrapper around /usr/bin/git
                                 (run, runWithStdin)
    HunkParser.swift           — unified-diff → ParsedDiff (files + hunks),
                                 + reassemble back into a unified diff
    PlanInspector.swift        — squash/fixup attach-relationship math
    Models.swift               — Verb, Commit, PlanItem, EditPlan,
                                 RebaseOutcome
    ContentView.swift          — top-level layout, toolbar, sheet plumbing
    TabStripView.swift         — Finder-style tab strip (whole pill is hit area)
    CommitListView.swift       — drag-reorder, verb chips, attach indicators
    DiffPaneView.swift         — `git show` pane: word-wrap + line numbers,
                                 structural color
    RebaseConfirmSheet.swift   — pre-Apply confirmation, plan preview
    RebaseResultSheet.swift    — post-Apply result, copyable backup ref
    SplitCommitSheet.swift     — split-commit hunk-assignment UI
  Sample Project/
    init.sh                    — generates a fresh 26-commit demo repo
    repo/                      — generated, gitignored
  scripts/
    build-app.sh               — local dev: build, ad-hoc sign, install,
                                 lsregister, retry-launch until pgrep
    render-icon.py             — regenerates Icon.png (Pillow)
  release-notes/
    _layout.html               — Sparkle-WebView-friendly note layout
    0.1.0.html                 — preview release notes (body fragment)
  ORIENTATION.md               — this file
  DECISIONS.md                 — why-we-did-it-this-way log
  BACKLOG.md                   — v0.3 and beyond
```

---

## Apply pipeline (incl. split execution)

The cute trick: `GIT_SEQUENCE_EDITOR` is invoked by git as
`<editor> <todo-file>`. Setting it to `cp '/path/to/our/todo.txt'`
makes the invocation `cp /our/todo.txt <git's-todo-file>`, which
overwrites git's TODO with ours. Result: a normal `git rebase -i`
runs to completion using our list, no editor pop-ups, no manual
TODO editing.

Sequence in `RebaseEngine.apply`:

1. Write a backup ref `refs/gitchop-backup/<timestamp>` pointing at
   current HEAD. Safety net for everything that follows.
2. Build a TODO file from the user's plan: `<verb> <full-sha>
   <subject>`, one per line. Order matches the user's reordered list.
3. `git rebase -i <base>` with `GIT_SEQUENCE_EDITOR=cp '<our-todo>'`
   and `GIT_EDITOR=:` (so squash's combined-message prompt accepts
   the default; reword is v0.3).
4. **Pause loop.** git rebase exits with code 0 when it pauses on
   `edit` (or `break`), so exit code alone doesn't tell us if we're
   done. Poll `.git/rebase-merge/` and `.git/rebase-merge/stopped-sha`:
   while a rebase is in flight, look up the stopped commit in the
   plan; if it has an `EditPlan`, run `runSplit()`; either way
   `git rebase --continue` and re-check.
5. **Final check.** Success requires `.git/rebase-merge/` to be gone.
   If a continue failed (conflict, bad split apply), the caller in
   `RebaseSession.apply` runs `git rebase --abort` and `git update-ref
   HEAD <backup>` + `git reset --hard HEAD`. We never leave the user
   mid-rebase silently.

### Split execution (`runSplit`)

When git pauses on an edit row that has an `EditPlan`:

1. `git reset HEAD^` — uncommit but keep working-tree state
2. `git diff HEAD` — capture the original commit's full delta
3. `HunkParser.parse()` the diff
4. For each bucket, in order:
   - `HunkParser.reassemble()` only that bucket's hunk IDs
   - `git apply --cached --recount` (stdin = the reassembled patch)
   - `git commit -m "<bucket subject>"`
5. Belt-and-suspenders: any leftover staged/unstaged changes get
   `git add -A` + commit under `<original> (leftover)`. The sheet
   validates "all hunks assigned" before save, so this is for cases
   where the diff drifted between sheet-open and apply-time.
6. Returns to the pause loop, which then `git rebase --continue`s.

Hunk IDs are content-derived: `"<file>::<hunk-header>::<first-body-line>"`.
This is what lets the user's bucket assignments survive close-and-reopen
of the split sheet AND match between sheet-time parsing and apply-time
parsing (which happens against `git diff HEAD` after the reset).

---

## Things you will not derive from the code

- **Not sandboxed.** Sandbox blocks subprocess execution; we have to
  shell out to `git`. `GitChop.entitlements` is empty on purpose.
- **Subjects in the TODO are display-only.** Git ignores anything past
  the SHA on a TODO line — we put the subject there for human-readable
  diffs when inspecting the temp file. Rewriting the subject in the
  UI does NOT rename the commit (that's reword, v0.3).
- **`drop` is a real rebase verb in modern git** (≥ 2.4). No need to
  filter the entry out of the TODO; git understands `drop <sha>` and
  skips it.
- **`squash` and `fixup` need a preceding `pick` or `edit` or another
  squash/fixup.** If the user's plan starts with squash/fixup or has
  a chain that doesn't trace back to a pick/edit, git errors at apply
  time. We don't pre-validate; the result sheet surfaces git's error
  and the rebase rolls back.
- **Most-recent commit is at the BOTTOM of the list.** Matches
  `git rebase -i`'s native TODO order. Surprises GUI users used to
  reverse-chronological. Worth keeping — the user's mental model
  matches what git is about to do.
- **iCloud File Provider xattrs.** Same gotcha as the other apps in
  this workspace — we stage the .app to /tmp before signing.
- **Edit acts like pick for attach-relationship math.** A squash/fixup
  below an edit row chains into the result of the split (last bucket).
  An edit row absorbs squash/fixups below it — they fold into the
  last split commit at apply time.
- **Anything in ContentView that reads session state needs its own
  observer subview.** ContentView observes `Workspace`; Workspace
  doesn't republish when a session's @Published properties change.
  So `ApplyButton`, `ResetButton`, `StatusBar`, `SplitSheetHost`,
  `RewordSheetHost`, and `ConflictSheetHost` are all their own
  `@ObservedObject`-bound subviews / view modifiers. Anything new
  in ContentView that wants to read `session.something` will lag
  behind the user's edits unless it follows this pattern. Inner
  views like `CommitListView` are fine because they pick the
  session up via `@EnvironmentObject` (re-injected by `tabContent`).
- **Two sheets in sequence need a delay.** When the confirm sheet's
  Apply runs, we dismiss it, sleep 250 ms, then run the rebase and
  pop the result sheet. Without the sleep the dismiss/present
  animations race and the result sheet sometimes never appears.
- **Hunk IDs are content-derived, not UUIDs.** UUIDs would change
  on every parse; bucket assignments would lose their referent.
  Stable string IDs survive close-and-reopen of the split sheet
  AND survive the sheet-time → apply-time re-parse.
- **`Image.paste(layer, mask)` REPLACES alpha.** Caused the icon's
  colored dots to render as washed-out white rectangles. The fix is
  `Image.composite(layer, blank, mask)` to clip first, then
  `alpha_composite()` onto the destination.

---

## Tab strip + persistence

Multi-repo via tabs at the top of the window. `Workspace.swift`
holds `[RebaseSession]` + `activeSessionID`. Open paths persist as
absolute paths under UserDefaults key `GitChopOpenRepos.v1` and are
restored on launch (paths that no longer resolve to a directory get
silently dropped). Opening a repo that's already in some tab just
switches to that tab.

`TabStripView` renders Finder-style pills with the whole tab as the
hit target (an early version had only the inner Text as the click
target — clicks on padding fell through). Close X is overlaid on the
trailing edge with reserved width so tabs don't shift on hover.

---

## Auto-rebuild dev loop

`.claude/settings.local.json` at the workspace root has a `PostToolUse`
hook that fires on `Edit|Write|MultiEdit`. Hook body:
`.claude/hooks/gitchop-build.sh`. The hook:
- filters by file path containing `Mac Apps/GitChop/Sources/`
- guards with an mkdir-lock at `/tmp/gitchop-build.lock`
- runs `bash scripts/build-app.sh` from the GitChop directory
- logs to `/tmp/gitchop-build.log`

`build-app.sh` itself does `pkill -x GitChop`, ditto-installs to
`/Applications/GitChop.app`, calls `lsregister -f` to force LaunchServices
to re-index, then `open` + `pgrep` retry loop until the app is actually
running (LSOpenURLsWithCompletionHandler -600 is racy after a fresh
install; this gets around it).

**Watcher caveat:** Claude Code's settings watcher only watches
`.claude/` directories that existed at session start. If you create
`.claude/` mid-session, the hook is written but won't fire until you
open `/hooks` or restart. Once it does fire, every edit triggers a
rebuild within ~10 seconds.

---

## When you finish a task

1. Verify the build is clean:
   `bash scripts/build-app.sh 2>&1 | grep -E "error:|warning: |Build complete"`
2. For UI work: actually click through the change in the running app.
3. Commit only when asked. Message style: terse, imperative, body
   describes the *why*.
4. If a feature crosses multiple files, one squashed commit beats
   five micro-commits — easier to revert as a unit.

## When in doubt

- Read `DECISIONS.md` before second-guessing an established choice.
- Read `BACKLOG.md` before starting something new — it might be
  there with context already.
- The git history has good commit messages — `git log -p
  Sources/GitChop/<file>.swift` is faster than asking why a thing
  is the way it is.
- The sample repo at `Sample Project/repo/` is regeneratable from
  `init.sh`. Don't touch it manually; edit `init.sh` and re-run.
