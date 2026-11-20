---
title: "feat: Decide in place from the Quicktask menu bar"
type: feat
status: active
date: 2026-11-14
---

> Superseded by ~/code/hub/docs/plans/2026-11-17-001-feat-asks-daily-driver-plan.md (2026-11-17). Kept for its verified code facts only.

# feat: Decide in place from the Quicktask menu bar

Deep plan, ten units in two phases. Phase 0 repairs what looks or counts wrong. Phase 1 lets the operator read a
result, decide, and be told, without leaving the menu bar. Companion to the hub plan
(`docs/plans/2026-11-14-001-feat-trust-and-loop-closure-plan.md` in the hub repo): U5 here reads `result_text`
from hub U9, U8 reads the notice kinds from hub U4, and U9 reads the `health` block from hub U2. Each of those
units degrades cleanly when the hub field is absent, so this plan can run before the hub ships.

## Summary

The dropdown shows what needs the operator but makes acting on it expensive: the peek panel paints links over its
text and is empty for Pass rows, verdicts need the mouse and cannot be undone, the badge hides the needs-you count
whenever a job is running, five icons per row truncate titles to about 25 characters, and nothing notifies when a
job enters verify. This plan fixes the peek, makes the count trustworthy, adds keyboard verdicts with undo,
declutters rows and aligns vocabulary with The Pass, adds actionable tiered notifications, and shows hub health.

## Requirements

- R1. The peek panel never overlaps its own controls, reads as quiet detail, and has a snapshot seam for the expanded state (origin: `docs/handoffs/2026-11-04-menubar-visual-tightening.md`).
- R2. The full test suite passes in one run, including the two notification test classes that fail order-dependently today.
- R3. The status item count always reflects what needs the operator; running jobs never hide it and Clear never removes a pending decision from it.
- R4. The peek panel shows result text for Pass-originated rows.
- R5. Rows give the title the width, show one worded status, and use the same words and color meanings as The Pass.
- R6. Every row verdict is available from the keyboard, with undo.
- R7. Notifications fire for verify, gate, and health events, carry actions including a typed redo note, and use an interruption level that matches urgency.
- R8. The footer shows hub health when the hub reports it.
- R9. One `make` entry point builds the app without installing it and runs the tests.
- R10. README and CHANGELOG describe what the app does today.

## Scope Boundaries

- No time features: no due dates, reminders, calendar, or snooze picker. That is the next phase and needs a design pick.
- No roster of agents outside the hub (Claude sessions, Caddy). That is a later phase.
- No change to `qt` or `qt-guard.py`.
- No new dependencies. SwiftUI and AppKit only.
- Never install over or restart the operator's running app: build with `--no-install`, verify with snapshots and the dump seams.

### Deferred to Follow-Up Work

- Split `menubar/Sources/MenuView.swift` (1,867 lines) and `tests/test_menubar_model.py` (3,874 lines) so units can run in parallel.
- Rename `TaskRecord.error` once nothing reads it as result text.
- The unexplained heap step noted in CHANGELOG on 2026-09-29.
- Per-task model picker (issue #9).

## Context

- `menubar/build.sh --no-install` compiles with `swiftc`; there is no Xcode project and no Swift test target.
- Tests are Python (`tests/test_menubar_model.py`, 317 tests) that build the binary once and drive `--dump-*`,
  `--post-*`, and `--snapshot` seams as subprocesses against fixtures and a loopback fixture Pass. Every suite sets
  `QT_DATA` to a temp directory. Never call `UNUserNotificationCenter` from a seam or test path (see the header
  comment in `menubar/Sources/Notifier.swift`).
- `menubar/Sources/Model.swift` holds `TaskRecord`, `MenuModel`, `ClearedRows`, and the `badge` string (near line 506).
- `menubar/Sources/App.swift` holds `StatusController`: polling, reveal, `clearSection` (near line 342), and the
  poll-detected notification calls. Init-order rule: closures that capture `self` go last in `init`.
- `menubar/Sources/MenuView.swift`: `TaskRow`, `peekPanel` (near line 1562), `RowButton`, `SectionHeader`.
- `menubar/Sources/Notifier.swift` registers three categories (blocked, blocked without allow, outcome).
- `menubar/Sources/PassClient.swift` has `status`, `capture`, `run`, `revive`, `decide`, `restart`; it does not
  fetch `/job/<id>` today.
- Conventions: long "why" header comments and dated inline notes; commit style `menubar: <imperative>`.

## Key Technical Decisions

- **Peek uses a clipped, fixed-max-height scroll view** for result text, with a plain non-selectable text and the
  existing Copy button, so overlap is structurally impossible (direction "a" in the handoff).
- **The count is the needs-you count, always.** Running is shown by icon state, not by replacing the number.
- **One commit model with the page:** a verdict takes effect at once and offers undo. When the hub returns an undo
  token (hub U6) the app uses it; otherwise the app holds the POST for the undo window and sends it when the window
  closes or the panel hides.
- **Vocabulary and color follow The Pass:** "Your go", "Approve?", "Blocked", "Running"; amber means a decision is
  yours, teal means an agent is involved, red means blocked or failed. No purple.
- **Unknown notice kinds fall back** to the existing outcome category, and absent hub fields hide their UI, so the
  app works against an older hub.
- **Interruption level by tier:** blocked on something just fired is time sensitive; verify and gate are active;
  done is passive.

## Open Questions

### Deferred to Implementation

- Whether a time-sensitive interruption level is honored for an ad-hoc signed build. If not, use active with a
  sound for the blocked tier and note it in the unit's comment.
- Root cause of the order-dependent notification tests (suspect: process-level or defaults state leaking between
  seam invocations).
- Exact undo window; match the hub's.

## Implementation Units

### Phase 0: repair

### U1. Makefile build and test entry points

**Goal:** One command builds without installing and one runs the tests.
**Requirements:** R9
**Dependencies:** none
**Files:** `Makefile` (new)
**Approach:** Targets: `build` (runs `menubar/build.sh --no-install`), `test` (unittest discovery over `tests/`),
and a pattern target `test-%` that runs `tests/test_%.py` through discovery with a filename pattern. No target
installs, runs, or restarts the app.
**Acceptance checks:**
- `test -f Makefile`
- `grep -q "no-install" Makefile`
- `make test-labels`
**Assignment hint:** Mechanical; lowest tier that writes files.

### U2. Peek panel rebuild and expanded snapshot seam

**Goal:** The peek panel cannot overlap, reads as quiet detail, and can be snapshotted expanded.
**Requirements:** R1
**Dependencies:** U1
**Files:** `menubar/Sources/MenuView.swift`, `menubar/Sources/Snapshot.swift`, `menubar/Sources/DumpModel.swift`, `tests/test_menubar_model.py`
**Approach:** Follow the handoff document listed in R1 in full: scroll-view container with a fixed maximum height,
10 to 11 pt tertiary text capped near five lines, a rounded quiet container aligned to the title's left edge, one
rotating chevron in place of the eye and chevron swap, markdown backticks stripped for display, and the fallback
line saying "error" for failed and timed-out rows. Add `--expand <id-substring>` to the snapshot seam, kept
deterministic. Add test class `TestPeekExpandedSnapshot` that seeds a fixture task with a long multi-paragraph
result and asserts the seam exits 0 and writes a non-trivial PNG.
**Acceptance checks:**
- `grep -q "class TestPeekExpandedSnapshot" tests/test_menubar_model.py`
- `grep -q "expand" menubar/Sources/Snapshot.swift`
- `make test-menubar_model`
**Assignment hint:** SwiftUI layout work verified by looking at snapshots; strongest executor, visual review.

### U3. Notification tests pass in a full run

**Goal:** The suite is green in one run, so every later check can trust it.
**Requirements:** R2
**Dependencies:** U2
**Files:** `tests/test_menubar_model.py`, `menubar/Sources/Notifier.swift`, `menubar/Sources/DumpModel.swift`
**Approach:** Diagnose the shared state that makes `TestNotificationAuthorization` and `TestNotificationGating`
fail order-dependently and remove it at the source (isolate defaults or process state per seam invocation). Do not
skip, reorder, or retry the tests. Record the cause in a dated comment.
**Acceptance checks:**
- `make test-menubar_model`
- `make test`
**Assignment hint:** Debugging with an unknown root cause; claude:sonnet or stronger, no time pressure.

### U4. A count the operator can trust

**Goal:** The status item number always means "this many things need you".
**Requirements:** R3
**Dependencies:** U3
**Files:** `menubar/Sources/Model.swift`, `menubar/Sources/MenuBarIcon.swift`, `menubar/Sources/App.swift`, `tests/test_menubar_model.py`
**Approach:** The badge shows the needs-you count whenever it is above zero, with running indicated by the icon's
state. Suggestions count toward it. Clear applies to finished rows only: rows awaiting a verdict, a go, or blocked
cannot be cleared and never leave the count through Clear. Add test class `TestBadgeSemantics`: running plus
pending shows the pending count, suggestions are counted, clearing a section leaves needs-you rows and the count
intact, a previously cleared needs-you row reappears after upgrade.
**Acceptance checks:**
- `grep -q "class TestBadgeSemantics" tests/test_menubar_model.py`
- `make test-menubar_model`
**Assignment hint:** Model logic with clear cases; claude:sonnet.

### Phase 1: decide in place

### U5. Pass results in the peek panel

**Goal:** Reading a Pass job's result does not require the browser.
**Requirements:** R4
**Dependencies:** U4
**Files:** `menubar/Sources/PassClient.swift`, `menubar/Sources/PassStatus.swift`, `menubar/Sources/Model.swift`, `menubar/Sources/MenuView.swift`, `tests/test_menubar_model.py`
**Approach:** Decode the optional `result_excerpt` from status jobs and show it at once in the peek. On expand,
fetch `/job/<id>` off the main thread, read the optional `result_text`, cache it per job id and finish time, and
replace the excerpt. When neither field exists (older hub) keep today's fallback line. Introduce a result-text
property on the record so new code stops reading the misnamed error field. Extend the fixture Pass to serve both
fields. Add test class `TestPassResultPeek`: excerpt shown, full text fetched once and cached, absent fields fall
back, a failed fetch shows the excerpt and no error banner.
**Acceptance checks:**
- `grep -q "result_text" menubar/Sources/PassClient.swift`
- `grep -q "class TestPassResultPeek" tests/test_menubar_model.py`
- `make test-menubar_model`
**Assignment hint:** Networking plus model plus a small view change; claude:sonnet.

### U6. Quiet rows and one vocabulary with The Pass

**Goal:** Titles are readable and both surfaces say the same thing the same way.
**Requirements:** R5
**Dependencies:** U5
**Files:** `menubar/Sources/MenuView.swift`, `menubar/Sources/Layout.swift`, `menubar/Sources/SettingsView.swift`, `tests/test_menubar_model.py`
**Approach:** A row at rest shows the dot, the title, and one worded status with age ("Approve? 5d", "Your go
16d", "Blocked 5d", "Running 4m"). Action buttons appear only on the hovered or highlighted row, primary verb
first. The headline reads "N need you" with the oldest age and no duplicate title preview. Words and dot colors
follow the Key Technical Decisions. Ages over seven days render in the warning color. Move the Start at login
switch from the footer into Settings. Every icon-only button gets an accessibility label. Add test class
`TestRowVocabulary` on the dump seam: status words per state, no purple, headline text, age escalation.
**Acceptance checks:**
- `grep -q "class TestRowVocabulary" tests/test_menubar_model.py`
- `grep -q "accessibilityLabel" menubar/Sources/MenuView.swift`
- `make test-menubar_model`
**Assignment hint:** Visual judgment against a written vocabulary; strongest executor, visual review with snapshots.

### U7. Keyboard verdicts with undo

**Goal:** Any row decision is one key, and reversible.
**Requirements:** R6
**Dependencies:** U6
**Files:** `menubar/Sources/MenuView.swift`, `menubar/Sources/Actions.swift`, `menubar/Sources/PassClient.swift`, `menubar/Sources/Outcome.swift`, `tests/test_menubar_model.py`
**Approach:** On the highlighted row: `a` approve, `e` redo with an inline note field, `x` reject (press twice
within two seconds), `r` run (press twice), Return opens the peek. Keys are ignored while a text field has focus.
After a verdict an undo banner shows for the undo window; `u` or a click reverses it using the hub's undo token
when present, otherwise by cancelling the held POST. A one-line key hint sits under the highlighted row. Mouse
verdicts get the same undo. Add test class `TestKeyboardVerdicts` on the post seams: each key maps to its
decision, two-beat keys need both presses, undo with a token posts to the hub's undo route, undo without a token
sends nothing, keys are inert during text entry.
**Acceptance checks:**
- `grep -q "class TestKeyboardVerdicts" tests/test_menubar_model.py`
- `make test-menubar_model`
**Assignment hint:** Focus and key handling in SwiftUI, historically where this app's bugs live; strongest executor.

### U8. Actionable, tiered notifications

**Goal:** The operator is told when something needs a decision and can decide from the notification.
**Requirements:** R7
**Dependencies:** U7
**Files:** `menubar/Sources/Notifier.swift`, `menubar/Sources/NotifyInbox.swift`, `menubar/Sources/App.swift`, `menubar/Sources/Transitions.swift`, `menubar/Sources/Actions.swift`, `tests/test_menubar_model.py`
**Approach:** New categories: verify (Approve, Redo with a typed note, Open), gate (Run it, Later, Open), health
(Open Sources). Inbox kinds `verify`, `gate`, `health`, and `health-ok` map to them; unknown kinds use the
existing outcome category. When the inbox carries no such notice (older hub), the poll path raises a verify notice
on the transition into awaiting-verdict, with the existing suppression so a job is never announced twice.
Interruption levels follow the Key Technical Decisions. Notification actions go through the same decision path as
U7, including undo. Seams and tests never touch the real notification center. Add test class
`TestNoticeCategories`: kind to category mapping, fallback, text-input redo carries the note, no duplicate between
inbox and poll, level per tier.
**Acceptance checks:**
- `grep -q "class TestNoticeCategories" tests/test_menubar_model.py`
- `grep -q "UNTextInputNotificationAction" menubar/Sources/Notifier.swift`
- `make test-menubar_model`
**Assignment hint:** Platform API with test-isolation constraints; claude:sonnet with a careful reviewer.

### U9. Hub health in the footer

**Goal:** A broken intake is visible at a glance.
**Requirements:** R8
**Dependencies:** U8
**Files:** `menubar/Sources/PassStatus.swift`, `menubar/Sources/MenuView.swift`, `tests/test_menubar_model.py`
**Approach:** Decode the optional `health` block from status. The footer's Pass dot turns amber for degraded and
red for down, with the failing probe names in the label and a click that opens the Sources drawer in The Pass.
Absent block: today's behavior. Add test class `TestHubHealthFooter`: ok, degraded, down, absent.
**Acceptance checks:**
- `grep -q "class TestHubHealthFooter" tests/test_menubar_model.py`
- `make test-menubar_model`
**Assignment hint:** Small decode and view change; claude:sonnet.

### U10. Documentation catches up

**Goal:** The docs describe the app as it is.
**Requirements:** R10
**Dependencies:** U9
**Files:** `menubar/README.md`, `README.md`, `CHANGELOG.md`
**Approach:** Add what shipped undocumented (suggestions, search, Clear, peek, notify inbox, labels) and
everything in this plan: keys, vocabulary, notification kinds and tiers, the hub fields the app reads and how it
behaves without them. Correct the stale test count. One CHANGELOG entry per unit under Unreleased, with issue
numbers where they exist.
**Acceptance checks:**
- `grep -q "notify inbox" menubar/README.md`
- `grep -q "result_text" menubar/README.md`
- `grep -q "Keyboard verdicts" CHANGELOG.md`
**Assignment hint:** Prose from the diff; claude:sonnet.

## Verification

- **V1. The app builds without installing.** Check: `make build`
- **V2. The whole suite passes in one run.** Check: `make test`
- **V3. The expanded peek has a snapshot seam.** Check: `grep -q "class TestPeekExpandedSnapshot" tests/test_menubar_model.py`
- **V4. The count is trustworthy.** Check: `grep -q "class TestBadgeSemantics" tests/test_menubar_model.py`
- **V5. Pass results show in the peek.** Check: `grep -q "class TestPassResultPeek" tests/test_menubar_model.py`
- **V6. Verdicts work from the keyboard with undo.** Check: `grep -q "class TestKeyboardVerdicts" tests/test_menubar_model.py`
- **V7. Notifications are actionable and tiered.** Check: `grep -q "class TestNoticeCategories" tests/test_menubar_model.py`
- **V8. Hub health is visible.** Check: `grep -q "class TestHubHealthFooter" tests/test_menubar_model.py`
- **V9. The docs are current.** Check: `grep -q "result_text" menubar/README.md`
