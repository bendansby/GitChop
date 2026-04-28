# GitChop — orientation

A Mac-native `git rebase -i` that doesn't drop you into a TODO file.

Pitch: *"I made `git rebase -i` not suck."* The killer differentiator vs.
Tower / Fork / GitHub Desktop is **split-commit-in-window** (the `edit`
verb done as a hunk-staging UI rather than a `--continue` dance). v0.1
ships the rest of the rebase verbs without split — split lands in v0.2.

Currently at **0.1.0 (preview)**. macOS 14+. Bundle ID
`com.bendansby.GitChop`. Not yet shipped publicly; no Sparkle feed yet.

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
that exercises every rebase verb in v0.1:

- **drop**     "WIP: starting TOML output (probably won't ship)"
- **fixup**    "Fix JSON output: don't double-escape" → into "Start JSON output support"
- **squash**   "Add CSV→JSON output test" → with "Start JSON output support"
- **reorder**  "Fix CI: install jq…" should land near the JSON feature commit, not 8 commits later

The init script ends by printing the graph and a guided practice list
so you can jump straight in. Re-running it deletes and regenerates the
sample, so it's safe to chop, mess up, and reset.

`Sample Project/repo/` is its own self-contained git repo (gitignored
by GitChop's outer repo). That's why opening it in GitChop shows the
sample's history rather than GitChop's own — `git rev-parse
--show-toplevel` stops at the nearest `.git` directory, which is the
sample's, not the outer one.

---

## Layout

```
GitChop/
  Package.swift                — SwiftPM, single executable target
  GitChop.entitlements         — empty; intentionally NOT sandboxed
                                 (sandbox blocks subprocess + arbitrary FS)
  Resources/
    Info.plist                 — bundle identity, version
  Sources/GitChop/
    GitChopApp.swift           — @main scene, Open-Repo command
    ContentView.swift          — split layout, toolbar, alert
    CommitListView.swift       — drag-reorder list, verb chips
    DiffPaneView.swift         — `git show` pane
    RebaseSession.swift        — top-level @ObservableObject
    RebaseEngine.swift         — load + apply (the rebase itself)
    GitRunner.swift            — Process wrapper around /usr/bin/git
    Models.swift               — Commit, Verb, PlanItem, RebaseOutcome
  Sample Project/
    init.sh                    — generates a fresh demo repo on demand
  scripts/
    build-app.sh               — local dev: build, ad-hoc sign, install
  release-notes/
    _layout.html               — Sparkle-WebView-friendly note layout
    0.1.0.html                 — preview release notes (body fragment)
  ORIENTATION.md               — this file
```

---

## How Apply actually works

The cute trick: `GIT_SEQUENCE_EDITOR` is invoked by git as
`<editor> <todo-file>`. We set it to `cp '/path/to/our/todo.txt'` so
that the invocation becomes `cp /our/todo.txt <git's-todo-file>`,
which overwrites git's TODO with ours. Result: a normal `git rebase -i`
runs to completion using our list, no editor pop-ups, no manual
`--continue`.

Sequence in `RebaseEngine.apply`:

1. Write a backup ref `refs/gitchop-backup/<timestamp>` pointing at
   current HEAD. This is the safety net.
2. Build a TODO file from the user's plan: `<verb> <full-sha> <subject>`,
   one per line. Order matches the user's reordered list.
3. `git rebase -i <base>` with `GIT_SEQUENCE_EDITOR=cp '<our-todo>'`
   and `GIT_EDITOR=:` (so squash's combined-message prompt accepts the
   default; v0.2 will plug a real editor for reword).
4. On non-zero exit: `git rebase --abort` then `git update-ref HEAD <backup>`
   plus `git reset --hard HEAD`. We never leave the user mid-rebase.

---

## Things you will not derive from the code

- **Not sandboxed.** Sandbox blocks subprocess execution; we have to
  shell out to `git`. `GitChop.entitlements` is empty on purpose.
- **Subjects in the TODO are display-only.** Git ignores anything
  past the SHA on a TODO line — so we put the subject there for
  human-readability when the user inspects the temp file, but
  rewriting the subject in the UI does NOT rename the commit. Reword
  is a separate `git commit --amend -m` path that comes in v0.2.
- **`drop` is a real rebase verb in modern git** (≥ 2.4). No need to
  filter the entry out of the TODO; git understands `drop <sha>` and
  skips it.
- **`squash` and `fixup` need a preceding `pick`.** If the user's
  plan starts with squash/fixup, git errors. We don't pre-validate;
  we let git's error message surface in the result alert and rely on
  the backup ref to recover. Pre-validation is on the v0.2 list.
- **Most-recent commit is bottom of the list, oldest is top.** Matches
  `git rebase -i`'s native TODO order (which surprises GUI users used
  to seeing newest-first). Worth keeping.
- **iCloud File Provider xattrs** are the same gotcha as the other
  apps in this workspace — we stage the .app to /tmp before signing.
- **`drop` rendering.** The row's subject gets a strikethrough and the
  whole row dims. No verb-chip color change beyond the chip's own red.

---

## Where this is going (v0.2 backlog)

- **Reword inline.** Click subject to edit; chips auto-promote to `reword`
  and we generate a per-commit message map that a small helper editor
  uses when git invokes GIT_EDITOR.
- **Split-commit in window** (the killer feature). Mark `edit` on a row;
  click a button to open a hunk view; partition hunks into N buckets
  with messages; the row expands into N rows in the plan.
- **Conflict pause.** Detect `.git/rebase-merge/` after a failed apply,
  surface "Resolve in mergetool / Skip / Abort" options instead of
  auto-rolling back.
- **Custom range.** Pick the base commit (HEAD~N picker, or click a
  commit to "base from here").
- **Pre-validate plan.** Refuse to Apply if `squash`/`fixup` precedes a
  `pick`, with a clear message instead of letting git complain.
