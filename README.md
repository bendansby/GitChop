# GitChop

A Mac-native `git rebase -i` that doesn't drop you into a terminal.

Drag-reorder commits. Split one commit's hunks into multiple commits without
the `edit → --continue` dance. Reword in place. Resolve conflicts in a sheet
that doesn't bounce you back to the shell. Pure SwiftUI, no servers, no
account, no telemetry.

**Site & download:** [bendansby.com/apps/gitchop](https://bendansby.com/apps/gitchop)
&nbsp;·&nbsp; **Docs:** [bendansby.com/apps/gitchop/docs](https://bendansby.com/apps/gitchop/docs.html)

---

## What it does

- **Drag-reorder** commits with a verb chip (`pick` · `reword` · `edit` ·
  `squash` · `fixup` · `drop`) on every row. Squash & fixup show absorb
  badges so chains are visible without remembering them.
- **Split a commit** by marking it `edit`. The split sheet lists every hunk
  in the commit; assign each to a named bucket; each bucket becomes its own
  commit at apply time. The terminal-only `edit → --continue` dance, done as
  a UI.
- **Reword in place** via a focused modal pre-loaded with the commit's full
  message (subject + body). Applied during the rebase via a tiny
  `$GIT_EDITOR` helper — no editor pop-ups during apply.
- **Conflict pause sheet.** When git stops on conflicts, GitChop stays open
  with a list of unmerged files. Open each in your editor, click Continue.
  Or Skip the commit. Or Abort the whole rebase. Mid-rebase reorder of the
  remaining commits is supported from the same sheet.
- **Backup ref every Apply.** Before any history rewrite, GitChop writes
  `refs/gitchop-backup/<timestamp>` pointing at pre-rebase HEAD. Failed
  rebases roll back automatically; manual recovery is one
  `git update-ref` away.
- **Custom rebase base.** Right-click any commit → *Use as base*. Equivalent
  to `git rebase -i <sha>` from the terminal.
- **Multi-repo tabs**, persistent across launches. Auto-update via Sparkle.
  Native macOS, Apple Silicon, no Rosetta required.

---

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon (M-series)
- `git` on `$PATH` — typically already there from Xcode command-line tools or
  Homebrew. A custom git path is configurable in Preferences.

GitChop shells out to your installed `git` for full upstream-fidelity behavior
(see [DECISIONS.md](DECISIONS.md) for why), so any version-specific behavior
your shell `git` has applies here too.

---

## Install

**Recommended:** download the notarized DMG from
[bendansby.com/apps/gitchop](https://bendansby.com/apps/gitchop) and drag
`GitChop.app` into `/Applications`. Auto-updates via Sparkle.

**Build from source:**

```bash
git clone https://github.com/<your-fork>/GitChop.git
cd GitChop
bash scripts/build-app.sh        # build, ad-hoc sign, install to /Applications, launch
```

The build is universal (arm64 + x86_64) and takes ~30 seconds on a clean
checkout. SwiftPM handles the Sparkle binary XCFramework automatically;
the build script copies it into `Contents/Frameworks/`.

`INSTALL=0 bash scripts/build-app.sh` builds to `build/GitChop.app` without
installing.

---

## Try it in five minutes

A self-contained sample repo lives at `Sample Project/` with a generator:

```bash
bash "Sample Project/init.sh"
```

That produces a fresh 26-commit demo repo at `Sample Project/repo/` with
deliberate candidates for every rebase verb. Open that folder in GitChop
and try the practice list the script prints. Re-run the script any time
to reset.

---

## Repo layout

```
GitChop/
  Package.swift          — SwiftPM, single executable target + Sparkle dep
  Sources/GitChop/       — all Swift sources
  Resources/Info.plist   — bundle identity, Sparkle keys
  scripts/
    build-app.sh         — local dev: build, sign, install, launch
    release.sh           — full ship: notarize → DMG → appcast → upload
  release-notes/         — per-version HTML fragments + Sparkle layout
  Sample Project/init.sh — generates the sample repo on demand
  ORIENTATION.md         — architectural orientation for contributors
  DECISIONS.md           — why-we-did-it-this-way log
  BACKLOG.md             — what's next
```

If you're contributing or hacking on it, **start with
[ORIENTATION.md](ORIENTATION.md)** — it's the single most useful page.
[DECISIONS.md](DECISIONS.md) covers the trade-offs already locked in
("we tried X, chose Y, here's why"). [BACKLOG.md](BACKLOG.md) is what's
queued up.

---

## Contributing

Issues and pull requests welcome. A few preferences:

- **Read ORIENTATION.md first.** A few SwiftUI gotchas in this app
  (Workspace doesn't republish on session changes, Settings windows can
  claim main-window status on macOS 14+, etc.) have well-trodden patterns
  that the orientation doc spells out. Nice to start there before
  reinventing them.
- **Single-purpose commits with terse imperative subjects.** The existing
  log is the style guide (`git log --oneline`).
- **Run the sample repo through any change that touches the engine.** It
  exercises every verb plus a deliberate split candidate; if a rebase
  flow breaks, the sample is where it'll show up first.

---

## Acknowledgements

GitChop bundles **[Sparkle](https://sparkle-project.org)** for in-app
auto-update. Sparkle is © Andy Matuschak, Kornel Lesiński, and others, used
under the MIT license. Full license text:
[github.com/sparkle-project/Sparkle/blob/master/LICENSE](https://github.com/sparkle-project/Sparkle/blob/master/LICENSE).

The app icon and visual design are original to this project. Verb chip
colors, `EditPlan.bucketColor` palette, and the violet/indigo brand are MIT
along with the rest of the source.

No analytics, no tracking, no account, no servers. Sparkle's update check
hits one URL (`bendansby.com/apps/gitchop/appcast.xml`) once a day; that's
the only network activity the app does.

---

## License

[MIT](LICENSE) © 2026 Ben Dansby
