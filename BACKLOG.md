# GitChop — backlog

Tracked items for v0.3 and beyond. Roughly priority-ordered within
each section. "Cost" is rough person-hours; "value" is gut-feel
ranking against the existing feature set.

---

## v0.3 — to ship

These are the missing pieces that block a real launch / Show HN.
Most are visible to users on day one; that's what raises the bar.

### Reword inline   ·   value: high   ·   cost: 4–6h

Click a commit's subject in the list to edit it inline. The chip
auto-promotes to `reword`. At apply time, the engine generates a
per-commit message map keyed by full SHA; `GIT_EDITOR` points at a
small helper script that reads its arg (the commit-message file git
provides) and replaces the contents with the user's new subject for
that SHA. Helper looks like:

```bash
#!/bin/bash
# args: $1 = path to git's COMMIT_EDITMSG-style file
# env GITCHOP_REWORD_MAP_FILE = path to our SHA→subject map
# env GIT_REBASE_TODO_LINE_INDEX or similar to tell us which commit
sha=$(awk '{print $2}' "$GIT_REBASE_TODO" | sed -n "${POS}p")
new=$(jq -r ".\"$sha\"" "$GITCHOP_REWORD_MAP_FILE")
echo "$new" > "$1"
```

The trick is identifying which reword we're doing. Options:
- Track via `git status` / `.git/rebase-merge/stopped-sha` pre-edit
- Use a stateful counter file that the helper increments

This is simpler than it sounds; ~half a day of work.

### Conflict pause UI   ·   value: high   ·   cost: 1–2 days

Currently if `git rebase --continue` fails (likely a conflict),
we abort and roll back. That's safe but means real-world rebases
where conflicts happen — > 50 % on nontrivial chops — bounce off
the tool. Need:

1. Detect conflict state: `.git/rebase-merge/` exists AND
   `git diff --name-only --diff-filter=U` returns paths
2. Surface a sheet listing conflicted files with three actions:
   - "Open in mergetool" → spawn `git mergetool`
   - "Skip this commit" → `git rebase --skip`
   - "Abort the whole rebase" → `git rebase --abort` + restore
3. After the user resolves, GitChop polls for a clean working tree
   and offers "Continue" → `git rebase --continue`
4. Loop back into the existing pause loop in `RebaseEngine.apply`

The hard part is the polling story — we don't want to busy-loop.
A `DispatchSourceFileSystemObject` watching `.git/rebase-merge/`
would let us react to git state changes without timers.

### Edge cases in hunk overlap   ·   value: medium   ·   cost: 1 day

When two buckets contain hunks that touch the same lines (e.g.
bucket 1 modifies lines 10–15, bucket 2 modifies lines 13–20),
applying bucket 1 changes the line numbers; bucket 2's stored
hunk header (`@@ -13,8 +20,15 @@`) no longer matches. `--recount`
mitigates this for most cases but not all.

Fix: at apply time, after each bucket's commit, re-`git diff HEAD`
and re-parse hunks for the next bucket against the NEW state.
Match by content, not by stored line numbers — find each remaining
hunk's added/removed lines in the live diff and apply that.

This is "split-commit but actually robust." Ship-blocker only if
it's hit often in practice; ship as fast-follow otherwise.

### Plan pre-validation   ·   value: medium   ·   cost: 2h

Refuse to Apply if:
- A `squash` or `fixup` chain doesn't trace back to a `pick` or
  `edit` (currently we let git error and surface in the result sheet)
- An `edit` row has no `EditPlan` AND has squash/fixup chained below
  it (the chained verbs would attach to whatever the edit produces,
  which without a plan is just the original commit — semantically
  fine, but the user probably forgot to configure)
- Empty plan (every row drop): warn that it's destructive

The warnings can be inline in the confirm sheet, with a "Apply
anyway" button for the rare cases where the user knows better.

### Custom range picker   ·   value: low–medium   ·   cost: 4h

Today the only knobs are 12 / 25 / 50 / 100 / All in the depth menu.
Add: click any commit in the list and pick "Base from here" — the
plan reloads with that commit as the base. Also a "Pick base…" item
in the depth menu that opens a small commit-search UI.

Real-world rebases often start with "I want to rebase from <some
shared parent commit>", not "the last N." Today the user has to
mentally count.

---

## v0.4 — polish + breadth

Once v0.3 is out and stable.

### Multi-bucket drag/drop

The split sheet's hunk-to-bucket assignment is a Menu picker today.
Drag-and-drop hunks onto bucket cards would be more discoverable
and faster for big splits. SwiftUI's `Draggable`/`DropDestination`
since macOS 14 makes this less painful than it used to be.

### Bucket reorder

The buckets list in the split sheet is display-order = apply-order.
Right now there's no way to reorder buckets after assignment. Add
drag-reorder (or up/down buttons).

### Hunk preview

In the split sheet, each hunk row is just the file + header + line
counts. No way to actually see the hunk content from the sheet. A
disclosure-arrow per row that expands to show the diff (with the
same structural color the diff pane uses) would let users make
informed bucket assignments without flipping back to the main
diff pane.

### Cross-vendor PR viewer

Long-shot: pull PR review surface (comments, status checks, requested
reviewers) into a sidebar of the diff pane. Works for GitHub +
GitLab + Gitea via their respective APIs, gated by configured PATs.
Massively expands the tool's value but also moves us toward "yet
another git client" rather than "the rebase one." Probably v1 or
later.

---

## v0.5 — distribution

### Sparkle feed

Once we ship publicly, set up the appcast at
`bendansby.com/apps/gitchop/appcast.xml` (mirroring the other apps
in this workspace) and wire up `scripts/release.sh` modeled on the
unified ship pipeline doc at `Mac Apps/RELEASE.md`.

### Showcase site page

Add `gitchop.html` + assets to `Showcase/` and link it from
`Showcase/index.html`. Marketing copy + screenshot grid + download
button. Match the visual style of the other apps' showcase pages.

### Open source the repo

The pitch is much stronger as "solo dev shipped a polished native
git tool — code's here." Closed source caps the HN ceiling. Decide
license before launch (likely MIT or Apache 2.0).

---

## Won't fix / out of scope

Things that have come up and been deliberately rejected:

- **Rebase --root support.** `git rebase --root -i` lets you rebase
  including the initial commit. Adds engine complexity (no "base"
  to pivot on, different TODO format) for an extremely rare use
  case. Not worth the code path.
- **Non-Mac platform.** Ship on Mac first; cross-platform is a
  3-month detour for a fraction of the user base.
- **Replace the diff pane with a full editor.** Tempting, but every
  step toward "code editor" is a step away from "rebase tool." Keep
  the diff pane read-only; let the user edit code in their actual
  editor.
- **Live commit-graph visualization.** Beautiful but not what users
  reach for during a rebase. Would compete for window space with
  the rebase plan, which IS the focus.

---

## Ideas to maybe pull in

Things worth thinking about but not committed:

- **Autosquash recognition.** When the user has commits with
  `fixup!` or `squash!` prefixes (matching another commit's subject),
  pre-mark them with the right verb. `git rebase --autosquash`
  already does this, but doing it client-side lets users see the
  re-arrangement before applying.
- **Shortcut keys for verb assignment.** `1`–`5` to set the
  selected row's verb to pick / edit / squash / fixup / drop. Magit
  has this; it's a power-user accelerator that keyboard-driven
  users would find immediately.
- **Plan templates.** Common rebase shapes: "fold all WIP commits
  into the previous one" (every fixup-flagged commit → fixup), "pull
  one commit out and pause for split" (mark `edit` on the selected
  row). Could be a "Suggest…" menu.
- **Diff coloring intensity toggle.** Some users find the green/red
  fill on +/- lines too saturated. Could expose a "structural color
  on/off" or "intensity" knob in the diff pane header alongside
  word-wrap and line numbers.
