# GitChop — backlog

What's queued up for v1.x and beyond. Roughly priority-ordered within
each section. "Cost" is rough person-hours; "value" is gut-feel
ranking against the existing feature set.

---

## Shipped in 1.0

Most of the original v0.3 / v0.5 backlog is in the released app:

- **Reword inline** — modal sheet preloaded with the commit's full
  message; engine writes per-SHA scratch files and points
  `$GIT_EDITOR` at a tiny helper.
- **Conflict pause UI** — sheet listing unmerged files with Open /
  Reveal, plus Continue / Skip / Abort actions. Mid-rebase reorder of
  the still-pending commits is supported from the same sheet.
- **Split-bucket re-parse** — runSplit re-parses the live diff before
  each bucket and reassembles using current hunks. Hunk IDs are
  content-stable (file + +/- body lines) so they survive upstream
  line-number drift.
- **Custom range picker** — right-click any commit → *Use as base*.
- **Sparkle feed** — `bendansby.com/apps/gitchop/appcast.xml`, signed
  with the workspace EdDSA key. Auto-update via `Check for Updates…`.
- **Showcase site page + docs** at `bendansby.com/apps/gitchop`.
- **Open-source release** — MIT, source at the repo root.
- **Reset toolbar button**, **chronology column**, **Preferences
  window** (default depth / git path / editor mode), **stale-rebase
  recovery**, **empty-cherry-pick auto-skip**, **tab-close
  confirmation** — all 1.0.

---

## Next up — v1.1 candidates

### Plan pre-validation   ·   value: medium   ·   cost: 2–3h

Refuse to Apply (or warn inline in the confirm sheet) when:
- A `squash` / `fixup` chain doesn't trace back to a `pick` / `edit`
  / `reword` (currently we let git error and surface in the result
  sheet).
- An `edit` row has no `EditPlan` AND has squash/fixup chained below
  it — the chained verbs would attach to whatever the edit produces,
  which without a plan is just the original commit (semantically
  fine, but probably forgot to configure).
- Every-row-drop: warn that it's destructive.

The 1-hunk-edit case is already handled (chip menu disables the entry
with "Not available — commit has only 1 hunk"); this generalizes the
pattern.

### Multi-bucket drag/drop in the split sheet   ·   value: medium   ·   cost: 4–6h

Hunk-to-bucket assignment is a chevron menu today. Drag-and-drop
onto bucket cards is more discoverable for big splits. SwiftUI's
`Draggable` / `DropDestination` since macOS 14 makes this less
painful than it used to be.

### Hunk preview in the split sheet   ·   value: medium   ·   cost: 1d

Each hunk row is just the file + header + line counts. A
disclosure-arrow per row that expands the diff body (same structural
color the diff pane uses) would let users make informed bucket
assignments without flipping back to the main diff pane.

### Bucket reorder   ·   value: low   ·   cost: 2h

The buckets list in the split sheet is display-order = apply-order.
Drag-reorder (or up/down buttons) so users can sequence the resulting
commits. Most splits don't care, but the affordance is missing.

### Native window tabs   ·   value: medium   ·   cost: 1d

Replace the custom tab strip with macOS's native window-tab
mechanism. Means restructuring from `WindowGroup → Workspace → N
sessions` to `WindowGroup → one session per window`, with system
tabbing merging windows automatically. Wins: drag tabs out into
windows, system ⌘⇧] / ⌘⇧[ navigation, less custom code. Cost: real
refactor of state ownership + persistence, not just a styling swap.

### Mergetool integration in the conflict sheet   ·   value: low–medium   ·   cost: 4–6h

Today's "Open" launches the configured editor; the user resolves and
clicks Refresh / Continue. Adding a "Merge with mergetool…" action
that spawns `git mergetool` and refreshes when it returns would save
a step for users who already use Kaleidoscope, Beyond Compare, etc.

### File-system watcher during conflict resolution   ·   value: low   ·   cost: 2h

`DispatchSourceFileSystemObject` on `.git/rebase-merge/` and the
unmerged paths. Removes the manual Refresh tap — the conflict sheet
auto-updates as the user saves resolutions.

---

## Ideas — uncommitted

Things worth thinking about but not on a roadmap:

- **Autosquash recognition.** When commits have `fixup!` / `squash!`
  prefixes matching another commit's subject, pre-mark them with the
  right verb on load. `git rebase --autosquash` does this client-side
  already; doing it in the UI lets users see the rearrangement before
  applying.
- **Verb keyboard shortcuts.** `1`–`6` to set the selected row's
  verb. Magit-style accelerator for keyboard-driven users.
- **Plan templates.** "Fold all WIP commits into the previous one,"
  "Pull one commit out and pause for split," etc. Could be a
  *Suggest…* menu.
- **Diff-color intensity toggle.** Some users find the green/red
  fill on +/- lines too saturated. Could expose a "structural color
  on/off" or "intensity" knob in the diff pane header.
- **Cross-vendor PR viewer.** Pull PR review surface (comments,
  status checks, requested reviewers) into a diff-pane sidebar. Works
  for GitHub / GitLab / Gitea via APIs, gated by configured PATs.
  Massively expands the tool's value but also moves toward "yet
  another git client" rather than "the rebase one." Long-shot for
  v1.x.

---

## Won't fix / out of scope

Things that have come up and been deliberately rejected:

- **Rebase --root support.** `git rebase --root -i` lets you rebase
  including the initial commit. Adds engine complexity (no "base" to
  pivot on, different TODO format) for an extremely rare use case.
  Not worth the code path.
- **Non-Mac platform.** Ship on Mac first; cross-platform is a
  3-month detour for a fraction of the user base.
- **Replace the diff pane with a full editor.** Tempting, but every
  step toward "code editor" is a step away from "rebase tool." Keep
  the diff pane read-only; let the user edit code in their actual
  editor (which Preferences now lets them launch from the conflict
  sheet).
- **Live commit-graph visualization.** Beautiful but not what users
  reach for during a rebase. Would compete for window space with
  the rebase plan, which IS the focus.
- **In-app branch switcher.** GitChop reads whichever branch is
  currently checked out — that's enough. Branch management is well
  served by other Mac git tools (Tower, Fork, Xcode, the terminal),
  and adding it here would import a thicket of dirty-tree / detached-
  HEAD / no-upstream edge cases that don't pay back in the
  rebase-only lane.

---

## Hardening / known limitations

- **Split during rebase, true context drift.** When an upstream
  rebase step actually changes a context line's *content* (not just
  shifts its position), the bucket's hunk has stale removal lines and
  `git apply` rejects it. Today the engine rolls back. The proper
  fix is 3-way merging the bucket's intent against the live tree —
  significantly more work than the line-number-drift fix that 1.0
  shipped. Surface as a conflict so the user can resolve, rather
  than dropping the whole split.
- **Backup-ref retention.** `refs/gitchop-backup/<timestamp>` accumulates
  forever today. A "Delete backups older than N days" knob in
  Preferences (auto-runnable on launch) is a small addition; just
  hasn't been built.
