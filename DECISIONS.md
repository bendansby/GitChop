# GitChop — design decisions

A log of "we tried X, chose Y, here's why" calls. Read this before
second-guessing an established pattern. Entries are roughly chronological,
not by importance. Each entry: a header, the choice, the considered
alternatives, and the reason.

---

## Shell out to `/usr/bin/git`, not libgit2

**Choice:** every git operation goes through `GitRunner`, which spawns
`git` as a subprocess.

**Alternatives considered:** libgit2 via Swift bindings (e.g. SwiftGit2).

**Why:** rebase semantics are subtle and shift between git versions.
libgit2's `git_rebase_*` family lags upstream git on edge cases (rebase
merges, autosquash semantics, the various `--keep-empty` interactions).
Shelling out gets us upstream git's exact behavior for free, including
whatever the user's installed version does. It also keeps the
`runWithStdin` story simple (pipe a patch into `git apply --cached`)
which is core to split-commit. Performance hit is irrelevant — rebase
is human-paced.

---

## Not sandboxed; hardened runtime only

**Choice:** `GitChop.entitlements` is an empty plist. App is
notarization-ready (hardened runtime via `--options runtime`) but not
sandboxed.

**Alternatives:** sandbox + security-scoped bookmarks for repo paths.

**Why:** sandbox blocks subprocess execution. We can't shell out to
`git` from a sandboxed app. Distribution path is direct download from
bendansby.com, not the App Store, so sandbox isn't a hard requirement.
The hardened runtime + Developer ID is what notarization needs; sandbox
is orthogonal.

---

## Tabs (one window) for multi-repo, not multiple windows

**Choice:** `Workspace` owns N `RebaseSession`s; `TabStripView` shows
them at the top of one window. ⌘O appends a tab; ⌘W closes the active.

**Alternatives:** SwiftUI `Window`-per-repo (Mac-native, but with state
restoration challenges); a sidebar like Mail; a `WindowGroup` with a
single document type.

**Why:** rebase is a focused activity — you don't need to see two repos
side-by-side. Tabs match the "I have a few repos in flight" mental
model and make persistence trivial (just a `[String]` of paths).
Multi-window adds window-state restoration and a per-window menu bar
that don't pay for themselves.

---

## Persist open repos as plain absolute paths, not bookmarks

**Choice:** `UserDefaults.set([String], forKey: "GitChopOpenRepos.v1")`.
On restore, drop any path that no longer resolves to a directory.

**Alternatives:** security-scoped bookmarks (NSURL bookmarkData).

**Why:** we're not sandboxed, so we don't need security-scoped resolve.
Bookmarks would handle moved repos; in practice users rarely move
repos and the failure mode (missing → silently dropped) is fine.
Plain paths are also debuggable from `defaults read`.

---

## Default depth = 12; cap is `total non-merge commits − 1`

**Choice:** the depth menu offers 12 / 25 / 50 / 100 / All. "All" is
defined as "every non-merge commit *except* the root."

**Alternatives:** show the entire history including the root (would
need `git rebase --root` support); arbitrary numeric input.

**Why:**
- 12 matches the size of a typical pre-push tail of work, which is
  the most common rebase target. Loading 100+ commits in a typical
  repo just adds scroll.
- `--root` rebases are vanishingly rare in interactive use and would
  require special-casing the engine to handle "no base commit." Not
  worth the code path for v0.2.
- The root commit *has* to be the rebase base (its parent doesn't
  exist), so "All N" really means "N − 1 chopable commits." The UI
  truthfully reports `chopableTotal = totalNonMerge − 1` so the
  count headers match what's loadable.

The earlier version capped at `totalAll − 1` (with merges), which
caused `git rev-parse <root>^` to fail on Load all. The fix was
asking for N+1 commits and using the oldest as the base directly,
no `<sha>^` hop.

---

## Depth menu lives ON the count text, not in the toolbar

**Choice:** the "X of Y commits" text in the list header IS the menu
trigger, with a small chevron pill background.

**Alternatives:** a separate toolbar button with a `list.number` icon.

**Why:** the count is information AND the action — clicking the thing
that shows you "how many" to change "how many" is the most discoverable
collapse. Two-place rendering (toolbar button + header label) was
redundant.

---

## Hunk IDs are content-derived, not UUIDs

**Choice:** `Hunk.id = "<file>::<header>::<first-body-line>"`.

**Alternatives:** `let id = UUID()` per parse.

**Why:** UUIDs would change on every parse, including the one we do
at apply-time after `git reset HEAD^` + `git diff HEAD`. The user's
bucket assignments (stored as `Set<String>` of hunk IDs) would lose
their referents and every split would dump every hunk into the
"leftover" commit. Content-derived IDs are stable across:
- close-and-reopen of the split sheet
- sheet-time-parse vs. apply-time-parse (same file content yields
  the same IDs)
- minor edits to the plan that don't actually re-stage anything

The chosen key is unique enough in practice (a file rarely has two
hunks with identical headers AND identical first body lines) and
much simpler than computing a real content hash.

---

## Picking `edit` from the verb chip auto-opens the split sheet

**Choice:** `RebaseSession.setVerb(of: id, to: .edit)` sets
`splitSheetCommitID` if the previous verb wasn't already `.edit`.

**Alternatives:** require an explicit "Split…" button to open the
sheet after marking edit.

**Why:** "edit" without a saved split plan is a no-op pause-and-
continue at apply time. Users shouldn't be able to mark edit with
no plan and then be confused that nothing happened. Auto-opening
the sheet means the verb itself becomes "I want to break this
apart" rather than a useless intermediate state. The chip menu
still has a "Configure split…" / "Edit split…" item to re-open
without toggling away and back.

If the user cancels the sheet (no plan saved), the verb stays
`.edit` and apply will pause-and-continue at that commit. That's
a reasonable fallback: the user got an interactive pause point
without a configured split, and can drop into a terminal if they
want.

---

## A separate `ApplyButton` subview observes the session directly

**Choice:** `ApplyButton: View { @ObservedObject var session }`.
ContentView passes `workspace.activeSession` in.

**Alternatives:** read `workspace.activeSession?.hasChanges` inline
inside ContentView.

**Why:** ContentView's `@EnvironmentObject` is `Workspace`, which
publishes only on its own changes (sessions array, activeSessionID).
It does NOT republish when an inner session's `@Published` properties
change. So referencing `workspace.activeSession?.hasChanges` inline
gave a value that never updated as the user edited the plan — the
toolbar button stayed stuck in disabled state. Moving the read into
a subview that takes the session as `@ObservedObject` re-subscribes
SwiftUI to that session's publishes.

This pattern repeats anywhere we need to observe both the workspace
AND the active session. Most inner views (`CommitListView`,
`DiffPaneView`, etc.) get the session via
`.environmentObject(session)` re-injection from `ContentView`.

---

## Confirm sheet → 250 ms sleep → run rebase → result sheet

**Choice:** `RebaseConfirmSheet`'s onApply dismisses the confirm
sheet, then `Task { try? await Task.sleep(nanoseconds: 250_000_000); …
await session.apply(); showOutcome = true }`.

**Alternatives:** swap sheets directly, or use a single sheet that
multiplexes between confirm and result states.

**Why:** SwiftUI's sheet dismiss/present animations race when chained
back-to-back. Without the sleep the result sheet often doesn't appear
— the parent's `.sheet(isPresented:)` binding flips before the dismiss
animation completes, and SwiftUI silently drops the new presentation.
250 ms is long enough to let the dismiss settle and short enough that
the user doesn't perceive a gap before the rebase kicks off.

The single-sheet alternative (multiplex via an enum state) was
rejected because the two sheets have very different sizes and
content — keeping them as distinct types is clearer.

---

## Image.composite + alpha_composite for icon highlights

**Choice:** when adding the per-dot specular highlight in
`render-icon.py`, clip the highlight layer with `Image.composite`
first, then `alpha_composite` it onto the dot.

**Alternatives:** `img.paste(highlight, (0,0), interior_mask)`.

**Why:** Pillow's `Image.paste(im, position, mask)` REPLACES the
destination's alpha channel where the mask is non-zero, rather than
alpha-blending the source over the destination. The result was that
every colored dot got rendered as a washed-out white blob — the
highlight's semi-transparent white pixels overwrote the colored
fill below. `Image.composite()` produces a clipped layer (transparent
outside the mask), and `alpha_composite()` then blends it correctly
onto the destination. Same effect as a Photoshop "clipping mask + 
normal blend mode."

---

## Diff pane: line numbers are per-row, not per-display-line

**Choice:** each logical line in the diff is its own
`HStack(alignment: .top)` with the gutter number on the left and
the line text on the right. When word-wrap is on, the text wraps;
the gutter number stays at the top of the wrapped block.

**Alternatives:** a single `Text` with the line numbers prepended;
a side-by-side `Text` ("1\n2\n3..." next to "line1\nline2\nline3...").

**Why:** the prepended-number approach made selection (textSelection)
include the line numbers, which is annoying for copy-paste. The
side-by-side approach got out of sync as soon as wrap was enabled —
gutter numbers at fixed line height didn't match the wrapped text's
actual rendered height. Per-row HStacks let SwiftUI's natural
top-alignment do the work.

---

## Verb chip: bucket count `(N)` shows only when `editPlan` is set

**Choice:** the chip on an edit row reads `✂ edit` until a plan is
saved, then reads `✂ edit (N)` where N is the bucket count.

**Alternatives:** always show "(0)" or never show the count.

**Why:** the count is a positive signal — "your split is configured."
Showing "(0)" before configuration adds visual noise that doesn't
help the user; absence-of-count means "not yet configured" and
matches the "Configure split…" wording in the chip menu (vs. "Edit
split…" once a plan exists).

---

## Sample repo: 26 commits with deliberate rebase candidates, in
its own gitignored subfolder

**Choice:** `Sample Project/init.sh` generates a multi-author
project at `Sample Project/repo/` (gitignored from GitChop's outer
repo). 26 commits including 2 merge commits; the most recent 12
non-merge commits are the "local WIP tail" GitChop loads by default.

**Alternatives:** ship a static sample as files in the repo; generate
to `~/Desktop/GitChop Sample`.

**Why:**
- Static files committed under GitChop's repo would either be a
  submodule (overkill) or pollute GitChop's `.git` (confusing —
  picking the folder in GitChop walked up to GitChop's `.git` and
  showed GitChop's history instead of the sample's).
- Generating to `~/Desktop` worked but required the user to
  remember a separate path. Generating in-tree at `Sample Project/repo/`
  with a clear `.gitignore` rule means the repo is right where the
  user expects it.
- 26 commits, 3 authors, 2 merged feature/bugfix branches, deliberate
  drop / fixup / squash / reorder candidates — enough to demonstrate
  every feature without being so big it's slow.

The init script is destructive-by-design (`rm -rf` the destination
first) so the user can chop, mess up, and reset by re-running.

---

## Tab strip: whole pill is the activate target; close X is overlaid

**Choice:** the entire `Button { workspace.setActive(...) } label:
{ ... }` is the click area. The close X sits in an `.overlay()`
with reserved width inside the label so layout doesn't shift.

**Alternatives:** an HStack of two buttons (label + close); only
the inner Text as the activate target.

**Why:** an early version had only the inner Text as the click
target — clicks on the padding around it fell through, and the user
reported "tabs don't always activate." The fix is making the whole
pill (including padding) one Button, with the close X as an overlay
that absorbs its own clicks. Reserved width inside the label means
the X showing/hiding on hover doesn't reflow the tab.

---

## Build script retries `open` until the app is actually running

**Choice:** after `ditto`-installing to /Applications, `build-app.sh`
calls `lsregister -f` to force LaunchServices to re-index, then runs
`open` up to 6 times with a 0.4 s pause between attempts, verifying
liveness via `pgrep -x GitChop`.

**Alternatives:** call `open` once and trust it; sleep a fixed
amount and trust it.

**Why:** after a `ditto`-replace, LaunchServices sometimes still has
the old bundle's inode cached and `open` returns
`_LSOpenURLsWithCompletionHandler() failed with error -600`
(silently). The user is left with no running app. `lsregister -f`
forces an immediate re-index; the retry loop catches transient cases.
The pgrep check makes the script truthful — it prints "Launched" or
a fallback hint, not a misleading "Done" when the app didn't actually
come up.

---

## `--no-autostash` on `git rebase -i`

**Choice:** we always pass `--no-autostash`.

**Alternatives:** allow autostash; require a clean working tree.

**Why:** autostash silently saves uncommitted changes to a stash
before rebasing and pops them after. That's *almost* always what the
user wants — except when their uncommitted state is a half-written
hunk they don't want disturbed. With autostash, GitChop would silently
move the user's working changes around in a stash; the user might
not notice until something failed to pop. `--no-autostash` makes git
fail fast with a clear message ("cannot rebase: you have unstaged
changes"), which the result sheet surfaces. The user can stash or
commit themselves and retry.

---

## Hook lock at /tmp/gitchop-build.lock instead of file-locking

**Choice:** the auto-build PostToolUse hook uses `mkdir
/tmp/gitchop-build.lock` as an atomic single-builder lock. Held
during the build, removed when it finishes.

**Alternatives:** `flock`, a sentinel pid file, no lock at all.

**Why:** `mkdir` is atomic on every Unix filesystem we care about.
`flock` would work but adds a dependency on the lock fd staying open
for the lifetime of the build. A pid file race is more code than
mkdir for the same protection. No lock means rapid edits stack up
parallel builds racing to install to /Applications and kill each
other's processes — bad. mkdir is one syscall, can't fail spuriously,
and if the process crashes mid-build the stale lock is recoverable
by `rm -rf /tmp/gitchop-build.lock`.

---

## Unified relationship-indicator column (↑ / +N)

**Choice:** squash/fixup attach indicators (↑) and pick/edit absorb
counts (+N) share the same 22pt column between the drag handle and
the verb chip. Mutually exclusive — a row is either an absorber or
an absorbee, never both.

**Alternatives:** put the +N badge after the subject (the original
implementation); render no relationship indicator at all.

**Why:** putting +N after the subject made it visually disconnected
from the rest of the row's metadata, and it shifted every time the
subject got a different length. Sharing the column keeps the rest
of the row vertically aligned regardless of which (if any) cue
applies, and reads as "this is the row's relationship to its
neighbors" — one concept, one place.

The "no indicator at all" option felt like a loss because squash
and fixup are *relational* verbs — without the visual cue, users
have to remember which row they were attaching to from memory.
