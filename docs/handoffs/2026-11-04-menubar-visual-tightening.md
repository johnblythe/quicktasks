# Handoff: menubar peek-panel visual tightening (+ bundled fixes)

**Date:** 2026-11-04
**Repo:** /Users/johnblythe/code/quicktasks (work on a branch, open a PR)
**Companion repo (read-only unless a task says otherwise):** /Users/johnblythe/code/hub

## The task in one paragraph

The Quicktask menubar app grew a "peek" feature (expand a row to read the
task's result inline, with Open result / Copy / Resume links). It works, but
it looks broken: the action links paint *over* the result text, the text
reads at near-title weight, and the panel has no visual container. Tighten
the peek panel's visuals so it looks deliberate, fix the overlap for good,
and bundle three small non-visual fixes listed at the bottom.

## Repo orientation (read these first)

- `menubar/Sources/MenuView.swift` — the dropdown's view. `TaskRow` (~line
  1371) is the row; `peekPanel` (search for `private var peekPanel`) is the
  expansion this task is about; `RowButton` (~1675) is the icon-button
  convention; `SectionHeader` (~1318) is a good reference for the file's
  hover patterns.
- `menubar/Sources/Model.swift` — `TaskRecord`, `MenuModel`, `Section`,
  `ClearedRows`. Note: `TaskRecord.error` holds the *result body* for qt
  ledger rows (naming accident, documented in MenuView's peekPanel comment).
- `menubar/Sources/App.swift` — `StatusController` (polling, reveal/deep-link
  state, clearing). Note the init-order rule: closures capturing `self` go
  last in `init`.
- `menubar/build.sh` — `./build.sh --no-install` compiles with swiftc (no
  Xcode project). `./build.sh --run` installs to /Applications and restarts
  via the login agent — do NOT use `--run` while iterating; the user is
  running the app.
- `menubar/Sources/Snapshot.swift` — `QuicktaskStatus --snapshot out.png`
  renders the real dropdown to a PNG headlessly. **This is your visual
  verification loop.** Built binary: `menubar/build/Quicktask.app/Contents/
  MacOS/QuicktaskStatus` after `./build.sh --no-install`.

## Reference images (in this directory)

- `peek-overlap-current.png` — the bug as the user screenshotted it: action
  links overlapping wrapped peek text, oversized-feeling text, no container.
- `menubar-baseline.png` — the dropdown as of today (collapsed rows).

## Diagnosed issues

### 1. OVERLAP BUG (the critical one)

`peekPanel`'s `Text(peekText).lineLimit(8).truncationMode(.tail)
.textSelection(.enabled).frame(maxWidth: .infinity)` sits in a
`VStack(spacing: 6)` inside the row's outer `VStack(spacing: 0)`. In the
screenshot the text renders ~9 lines but the VStack placed the button row
as if it were ~5 — the text overflowed its reported frame. Suspects:
`textSelection(.enabled)` + `lineLimit` mis-sizing on macOS, or the
frame/lineLimit combination. **Do not patch around it with spacing hacks** —
restructure so overlap is impossible. Acceptable directions (pick one, say
why in the PR):

  a. Put the peek text in its own fixed-max-height `ScrollView` (clipped
     frame, content scrolls if long).
  b. Drop `textSelection(.enabled)` (the Copy button already exists) and use
     a plain Text with a hard line cap.
  c. Use a read-only `TextEditor` (scrollable, selectable, sized).

Also strip markdown backticks from the peek text for display (result bodies
are markdown; the peek is prose).

### 2. Typography / hierarchy

The peek text currently reads at almost the same visual weight as the row
title. Direction: the row is the summary, the peek is quiet detail.
11pt or 10pt, `.tertiary` (or `.secondary` at most), tighter line spacing,
cap at ~5 lines with a trailing "…" and the "Open result" affordance for
the rest. Fallback line (no result text) stays italic tertiary.

### 3. Missing container

Give the peek panel a visual boundary: e.g. a rounded-rect fill
(`Color.primary.opacity(0.04)`-ish) with 8pt corner radius, or a hairline
divider above + inset background. Align the text's left edge with the row
*title's* left edge (currently pads to 27pt — verify against the title's
actual x position after the dot + source glyph columns). 6-8pt internal
padding, 6-8pt vertical breathing room below before the next row.

### 4. Row icon clutter

An expanded row currently shows eye→chevron.up swap plus resume and link
icons on the right. Use one rotating chevron (`chevron.right` →
`chevron.down`, 9-10pt, matching SectionHeader's convention) instead of the
eye/swap. Keep the resume/link RowButtons as-is otherwise.

## Verification requirements (all required, no exceptions)

1. **Add a snapshot seam for the expanded state** so the overlap can never
   regress invisibly: e.g. `QuicktaskStatus --snapshot out.png
   --expand <task-id-substring>` (or an env var) that opens the peek panel
   for the matching row before rendering. There is a `defaultVisibleIDs`
   precedent in DumpModel.swift for deterministic-seam thinking; keep the
   seam deterministic (no network, no real notification center). Seed a
   fixture task with a LONG multi-paragraph result so wrapping is exercised
   (QT_DATA points at a fixture dir; follow how tests/test_menubar_model.py
   builds fixtures).
2. **Before/after PNGs** committed to the PR description (not the repo):
   the expanded row with a long result, and the collapsed list.
3. **Tests**: add a `test_menubar_model.py` case driving the new snapshot
   seam (exit code + non-trivial PNG size is fine; the point is the seam
   runs in CI-like conditions). Run `python3 -m unittest discover -s tests`
   — all must pass EXCEPT the two known pre-existing flakes
   (`TestNotificationAuthorization`, `TestNotificationGating` — verified
   flaky on the pre-change tree; if you touch them, see bundled item A).
4. Never call `UNUserNotificationCenter` from a seam/test path
   (Notifier.swift's header comment explains why).

## Bundled non-visual fixes (small, same PR or a second one — your call)

A. **Flaky notification tests** — `TestNotificationAuthorization` and
   `TestNotificationGating` in tests/test_menubar_model.py fail
   order-dependently in full-suite runs but pass in isolation (verified on
   the pre-change tree too, so pre-existing). Diagnose the shared state
   (suspect: UserDefaults or process-level state leaking between seam
   invocations) and fix properly. If the fix is more than ~50 lines, split
   it into its own PR.
B. **Label spot-check** — one recent row ("michael and i are talking a…")
   shows what looks like the heuristic (prompt-prefix) label rather than a
   Haiku-refined one. Check whether `_refine_label` ran
   (`label_refined` in the task JSON) and whether its output is actually
   being preferred on the Pass feed path (PassStatus.swift title mapping).
   Fix only if it's a real bug; if it's just an old task, note it in the
   PR and move on.
C. If you touch the overlap area anyway: the peek fallback line for
   failed/timeout rows should say the text is an *error*, not a "result"
   (mirrors the copyResult toast wording fix already in MenuView).

## Conventions that matter here

- **Comments**: this repo explains *why* in long header comments and dated
  inline notes (see any modified file for the register). Match it. A fix
  without the reasoning comment is a red flag in review.
- **Tests** are Python driving the compiled binary's `--dump-*` seams
  (subprocess + fixtures), unittest style. No Swift test target.
- **No new dependencies.** SwiftUI + AppKit only.
- `qt` is a single Python file with no extension; load it in tests via
  SourceFileLoader (see tests/test_labels.py).
- Data dir is `$QT_DATA` (default `~/.quicktasks`); never touch the real one
  from a test — every suite sets `QT_DATA` to a tmp dir and several pin
  `QT_NOTIFY_INBOX=0` / `QT_LABEL_REFINE=0` for isolation.
- The app running at /Applications is the user's live widget. Do not
  `build.sh --run` or `killall` it; verify via `--no-install` builds and
  snapshots only. Final install happens after the PR merges.
- Git: branch off `main`, one or two clean commits, message style
  `menubar: <imperative>` (see `git log --oneline`). Open the PR with
  `gh pr create` and include the before/after PNGs in the body.

## Acceptance criteria

1. Expanded peek panel: no overlap under any text length (fixture-test the
   multi-paragraph case), quiet typography, visible container boundary,
   rotating-chevron affordance, markdown backticks stripped in display.
2. Snapshot seam renders the expanded state; before/after PNGs in the PR.
3. Full test suite green (modulo the two named flakes — or they are fixed).
4. `qt` and `qt-guard.py` untouched unless bundled item B requires it.
