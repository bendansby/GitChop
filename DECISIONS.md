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

---

## Sparkle as a SwiftPM binary XCFramework, manually copied at build

**Choice:** Sparkle is added via SwiftPM (`.package(url: …Sparkle…)`)
as a binary XCFramework, but `scripts/build-app.sh` manually copies
`Sparkle.framework` from `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/`
into `Contents/Frameworks/`. `Package.swift` carries an `unsafeFlags`
linker setting that adds `@executable_path/../Frameworks` to the
binary's rpath so dyld finds it.

**Alternatives:**
- Build Sparkle from source (StyleBop's `build_sparkle.sh` does this
  to get an `arm64e` slice the StyleBop SDK target needs).
- Use Xcode "Embed & Sign" (only works in Xcode-project builds, not
  SwiftPM `swift build`).
- Don't use Sparkle, ship without auto-update.

**Why:** SwiftPM resolves and links the binary fine, but doesn't copy
the framework bundle into the .app the way Xcode does. Without our
manual copy, dyld would fail at launch with "Library not loaded:
@rpath/Sparkle.framework". The vendored copy + the explicit rpath
linker flag is the smallest delta from a stock SwiftPM build that
gets us a working framework load. Building Sparkle from source
(StyleBop's path) would also work but adds a multi-minute one-time
setup step and requires Xcode toolchain checkout — not worth it
when the official binary release covers our `arm64 + x86_64` target.

---

## `--options runtime` and `--timestamp` are gated on a real Developer ID

**Choice:** `build-app.sh` only adds hardened-runtime + secure-timestamp
codesign flags when `SIGN_IDENTITY != "-"`. Local-dev ad-hoc signing
gets `--force --sign -` and nothing else.

**Alternatives:** always pass `--options runtime --timestamp` regardless
of identity (matches the release-build path).

**Why:** macOS's library-validation rule under hardened runtime
rejects loading frameworks signed with a different team identifier
from the loading binary. With ad-hoc signing both are "team
identifier not set" — should match — but the loader applies stricter
rules anyway, and Sparkle.framework's nested helpers fail to load at
launch with "different Team IDs". Simplest fix: skip hardened runtime
in ad-hoc local-dev builds where notarization isn't a concern. The
release pipeline still gets the full hardened-runtime + timestamp
treatment because it always passes a real Developer ID.

---

## MainWindowAccessor singleton, not `NSApp.mainWindow`

**Choice:** `MainWindowAccessor` is a tiny `NSViewRepresentable` that
records the document NSWindow into `MainWindowReference.shared.window`
on first appear. The `Close Tab` ⌘W command compares
`NSApp.keyWindow !== MainWindowReference.shared.window` to decide
whether to route the keystroke to the focused secondary window
(Preferences, etc.) instead of closing a background tab.

**Alternatives:** compare `NSApp.keyWindow !== NSApp.mainWindow`.

**Why:** on macOS 14+ the Settings scene's window can claim main-
window status when it's focused — `NSApp.mainWindow` returns the
Preferences window, not the GitChop document window. The check
`keyWindow !== mainWindow` then evaluates false (both point at
Preferences), the routing fails, and ⌘W silently closes a tab
behind the Preferences window. Tagging our actual document window
when it appears, via the accessor, gives a stable reference that
isn't subject to whatever the system has decided is "main" right
now. This shows up in `ORIENTATION.md` as a generalized lesson:
anything in `ContentView`'s scope that needs to read session state
needs its own observer subview, and anything in the menu bar that
needs to know "is the main window key" needs this reference.

---

## Reword writes per-SHA scratch files, not a single map

**Choice:** at apply time the engine writes each reworded commit's
new full message to its own file at
`/tmp/gitchop-reword-<uuid>/<sha>`, then sets `$GIT_EDITOR` to a tiny
shell helper that `cat`s the matching file into git's `COMMIT_EDITMSG`.
The helper finds the in-flight SHA by reading
`.git/rebase-merge/done`'s last line.

**Alternatives:** a single TAB-separated map file
(`<sha>\t<subject>` per line) parsed by the helper at editor time.

**Why:** the original BACKLOG entry imagined a single map. That works
for subject-only edits, but full-message rework with arbitrary body
content (multiple lines, special chars, etc.) makes shell-quoting
the contents into the helper's awk lookup uncomfortable. One file
per SHA sidesteps escaping entirely — `cp $dir/$sha $msgfile` is
the whole transformation. Squash combined-message edits also pass
through this helper but miss the dir and exit cleanly, leaving
the default merged message intact.

---

## `runSplit` re-parses live diff before each bucket

**Choice:** at apply time, `runSplit` runs `git diff HEAD` and
re-parses hunks **before each bucket**, not once at the start. Each
bucket reassembles using *live* hunks (current line numbers) and
applies that.

Hunk IDs are content-stable: `"<file>::<+/- body lines>"` (no `@@`
header, no context). The same hunk re-parsed against a different
working-tree state still has the same ID as long as its actual
changes are the same.

**Alternatives:** parse once at the start of `runSplit` (the original
1-pass design); reassemble using the parse-time line numbers and
trust `git apply --recount` to correct shifts.

**Why:** a single up-front parse breaks once any upstream rebase
step has shifted the file's content before this commit gets reached.
`--recount` corrects line-number drift but not context-content drift,
so the bucket's stored hunk header pointed at lines that no longer
matched the file. Re-parsing per bucket means we always reassemble
against the working-tree state `git apply` will see. Plus, after
bucket 1 commits, bucket 2's parse sees the diff *minus* bucket 1's
hunks — which is exactly what should be applied next.

The remaining failure mode (an upstream step *changed* a context
line's content, not just shifted its position) is a true 3-way
merge problem and still rolls back. BACKLOG tracks it under
"Hardening".

---

## `status` is a computed property, not a stored String

**Choice:** `RebaseSession.status` is a computed property that derives
"Loaded N of M on branch" live from `plan.count` + `totalNonMergeCount`
+ `branch`. One-off action messages (load errors, conflict notices,
rebase-failed-and-restored) go through a separate `actionMessage:
String?` override that's cleared on the next successful `load()`.

**Alternatives:** a stored `@Published var status: String` that every
mutation site has to keep in sync.

**Why:** the stored-string version drifted whenever any caller changed
`plan.count` or `totalNonMergeCount` without also re-setting status —
the bottom-bar text would say "Loaded 12 of 14" while the header
already showed 14 of 14. A computed property reads live values on
every render, so it can't go stale. Action-message override gives
us a way to surface transient notices without giving up the live
default. Pairs with a `StatusBar` subview that `@ObservedObject`s
the session so changes to `plan` / `totalNonMergeCount` /
`actionMessage` actually trigger re-renders (a recurring pattern —
see the "ApplyButton needs its own observer" entry above for the
generalized lesson).

---

## Preferences singleton: @MainActor instance + nonisolated static for git path

**Choice:** `Preferences` is a `@MainActor`-isolated `ObservableObject`
singleton holding the `@Published` properties bound to PreferencesView.
But `Preferences.resolvedGitPath()` is a `nonisolated static func` that
reads from `UserDefaults.standard` directly (and `which git` if the
user hasn't set a custom path).

**Alternatives:** make the whole class nonisolated; or call
`MainActor.assumeIsolated { Preferences.shared.resolvedGitPath() }`
from background tasks.

**Why:** `GitRunner.run` is called from background tasks (e.g. the
hunk-count loader is `Task.detached`). It needs the git path on every
invocation. An instance method on a `@MainActor` singleton would
require crossing the actor boundary on every git call. A nonisolated
static reading directly from `UserDefaults` is thread-safe and
avoids the hop. The `@MainActor` instance still exists for the
`@Published` bindings the SwiftUI view needs.

The same split applies to nested-type access: keys are hoisted to
file-scope `fileprivate enum PreferencesKeys` (rather than nested
inside the class) so the nonisolated static can name them without
inheriting the class's actor isolation.

---

## Tab strip auto-hides when only one repo is open

**Choice:** `ContentView` only renders `TabStripView` when
`workspace.sessions.count > 1`. Single-tab users never see the bar.

**Alternatives:** always show the strip; never show it (rely on the
window menu).

**Why:** the strip is empty chrome 90% of the time for a
single-repo user — they open one repo, they work in it, they close
the app. Showing the strip adds visual noise and pushes the commit
list down. Hiding it preserves the "this is just my one rebase
window" feel until the user actually opens a second repo, at which
point the strip appears with both tabs. The transition is a single
SwiftUI conditional, no extra plumbing needed.

---

## Custom rebase base via right-click "Use as base", not a search sheet

**Choice:** right-click any commit in the list → *Use as base*. The
clicked commit becomes the rebase foundation (excluded from the
plan, matching `git rebase -i <sha>`'s semantics). The header pill
flips to "N commits from abc1234"; the depth menu collapses to a
single "Switch to depth-based loading" item until the user reverts.

**Alternatives:** a "Pick base…" search sheet with a commit-finder
UI (the original BACKLOG entry).

**Why:** right-click + load-all covers the realistic flow without
extra UI. Real-world cases are "I want to rebase from this commit I
can already see" — for which a context menu on the visible commit
is faster than a search modal. The search-sheet variant is still
filed (now under v1.1 candidates) but isn't a v1 ship-blocker.

---

## Tab-close confirmation goes through a single Workspace dialog

**Choice:** both the tab-strip's X button and the Close Tab ⌘W
command call `workspace.requestClose(_ id:)`, which checks
`session.hasChanges` and either closes immediately (no changes) or
sets `pendingClose = session` (changes pending). `ContentView`
surfaces a confirmationDialog bound to that field; Discard / Cancel
buttons resolve via `confirmPendingClose()` / `cancelPendingClose()`.

**Alternatives:** show the dialog inline at each call site; or
no confirmation at all.

**Why:** two close paths share one chokepoint, so the dialog text and
behavior never drift between them. If we ever add a third close
path (a window-close handler, an "Open Recent" replacement, etc.) it
just calls `requestClose(_:)` and gets the same protection for free.
