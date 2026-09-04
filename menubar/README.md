# Quicktask menu-bar widget

A macOS status-menu app for `qt` and The Pass. The menu-bar icon is a coloured
dot showing aggregate state; the dropdown has a quick-fire field at the top,
collapsible sections for what is running, what needs you, and what finished, and
a footer with the feed's health and the controls.

It is the front door to the whole loop, not just to `qt`: a run in flight, an
item the router held at a gate, a finished job waiting on a verdict, and a dead
run are all one click from here.

```
●3                                       <- menu bar: dot + count

⚡ Fire a quick task…
  [ Run now | To Pass ]
─────────────────────────────────────────
● 3 tasks need you
─────────────────────────────────────────
⌄ Running                              2
  ● Spinnaker stale pipeline…  Running 4:13 ↗
  ● look thru atlas and see…   Running 0:41 ↗
⌄ Needs you                            4
  ● Draft Q3 roadmap rev…  Verify · 49m ▤ ✓ ↺ ✕ ↗
  ● Prep the vendor renewal…      Needs go
  ● Shepherd app for Gonfalon    Blocked · 2h ↗
  ● Dossier: Agent Platform…      Failed · 4h
⌄ Done today                           2
  ● Secure hiring approval…        Done · 1h ▤ ↗
› Earlier                              1
─────────────────────────────────────────
Refreshed 11:55 AM  ● Pass        ▤ ↻ ⏻
Start at login  (  )
```

## Install

Needs only Command Line Tools (`xcode-select --install`). No Xcode
project, no SwiftPM manifest, no signing identity, no Python packages.

```bash
cd menubar
./build.sh --run     # build, install to ~/.quicktasks, launch now
./build.sh --agent   # ...and start it at login
```

`build.sh` compiles the sources with `swiftc`, assembles
`QuicktaskStatus.app`, writes its `Info.plist` (`LSUIElement`, so no Dock icon
or app-switcher entry), copies the LaunchAgent template into the bundle,
ad-hoc signs it, and copies it to `~/.quicktasks/QuicktaskStatus.app`.

Other flags:

| Flag | Effect |
| --- | --- |
| `--no-install` | Build into `./build` only. What the tests use. |
| `--run` | Install and launch immediately. |
| `--agent` | Install a LaunchAgent that starts it at login. |

### Starting it at login

Either `./build.sh --agent` or the footer's **Start at login** switch writes
`~/Library/LaunchAgents/com.quicktasks.menubar.plist` from the template in this
directory and bootstraps it. Both read the same template -- the toggle reads it
out of the app bundle, which is why `build.sh` copies it in -- so the two
cannot drift. `KeepAlive` is deliberately off, so the dropdown's power button is
a real quit and the widget comes back at the next login rather than three
seconds later.

Turning the switch off boots the agent out and deletes the plist. By hand:

```bash
launchctl bootout "gui/$(id -u)/com.quicktasks.menubar"
rm ~/Library/LaunchAgents/com.quicktasks.menubar.plist
```

If you would rather use a login item: System Settings → General → Login Items
→ **+** → `~/.quicktasks/QuicktaskStatus.app`.

## Using it

**Quick-fire, two ways.** Type into the field at the top and press return. The
segmented toggle under it decides where the text goes, and the choice is
remembered:

- **Run now** shells out to `qt <your text>`, the same entry point a terminal
  uses, so the task lands in the same ledger with the same notification and
  resume behaviour. It runs with `$HOME` as the working directory, deliberately
  *not* one of the trusted dirs, so a menu-bar task runs under the default
  permission mode instead of silently escalating. Point it somewhere else with
  `QT_MENUBAR_FIRE_DIR`.
- **To Pass** posts to `POST /capture`, which files it as an item needing your
  go rather than running it. The flash message names the id The Pass assigned.

**Sections.** Running, Needs you, Done today, Earlier. Click a header to
collapse it; the state is remembered in `UserDefaults`. Only Earlier starts
collapsed: the two sections that carry actions have to be open the moment the
menu opens, or the widget has buried the thing it exists to surface. Inside
Needs you the order is fixed -- verify, gate, blocked, failed -- because a
verdict is the cheapest action available and it is holding a finished job's
result.

**Row actions**, left to right after the status text:

| Icon | Shown when | Does |
| --- | --- | --- |
| ▤ | the job wrote a report | Opens `pass_url` + `report` in the browser |
| ✓ ↺ ✕ | the row is a verify row | Posts `accept` / `redo` / `reject` |
| ↗ | there is a session to reopen | Opens `quicktask://resume/<slug>` |

Clicking the **title** opens The Pass. It opens the root, not the item: The
Pass has no per-item deep link today (`serve.py` strips the query string before
routing and the page never reads `location.hash`).

**Redo** expands an inline field for the note, because a redo without one is
not much of an instruction. **Reject** asks first -- it is the one action that
throws a finished job's work away -- and swaps the verdict icons for a confirm
pair rather than opening a dialog, which a menu-bar panel handles badly.

A verdict posts the same body the review page's Save button posts, and any
decision already sitting unreconciled in `hub/decisions.json` rides along with
it. `serve.py` overwrites that file wholesale on every save, so a one-row post
would otherwise discard a review saved in the browser and not yet reconciled.

**Elapsed time** on in-flight rows ticks every second off the wall clock, not
off the feed, so an open menu counts up between polls. Finished rows keep the
coarse relative age (`2h`).

**The footer** shows when the model was last read, which feed it came from,
then buttons for The Pass, a manual refresh, and quit, plus the login switch.

**The dot**:

| Colour | Meaning |
| --- | --- |
| Blue | At least one run running or queued. Count badge. |
| Orange | Nothing running; something needs you. |
| Grey | All quiet. |

Row dots are coloured by *why* the row needs you, not by the job status
underneath -- teal for verify, purple for a gate, orange for blocked, red for
failed, green for a clean finish -- because a finished job awaiting a verdict is
not green.

Running beats attention in the aggregate, because an in-flight run is the thing
most likely to change in the next few seconds.

## Where the state comes from

Two feeds, in this order.

**The Pass, over HTTP.** `GET /status.json` every 5 seconds:

```json
{"generated_at": "...", "pass_url": "http://127.0.0.1:8811",
 "groups":    [{"key": "gate", "label": "Needs your go", "count": 2, "undone": 1}],
 "counts":    {"running": 2, "verify": 1, "gate": 1, "blocked": 1, "failed": 1},
 "jobs":      [{"item_id": "...", "title": "...", "state": "...", "status": "...",
                "started": "...", "elapsed_s": 252, "failed": false,
                "blocked": false, "session_id": "...", "resume_url": "...",
                "report": "/job/<item_id>/output/report.html", "outputs": [...]}],
 "needs_you": [{"item_id": "...", "title": "...", "state": "...",
                "reason": "verify|gate|blocked|failed"}]}
```

`needs_you` carries no `resume_url` and no `report`, so its rows are joined onto
`jobs` by `item_id` to pick up their affordances. A gate item has no job at all,
which is why the reason has to be able to stand in as the row's status text on
its own. `jobs` carries no `finished`, so a terminal row's end time is
reconstructed from `started + elapsed_s`, which only has to be accurate enough
to sort the row and place it in today versus earlier.

Even in Pass mode the qt ledger is still read and merged. A task fired with `qt`
(or with this widget's quick-fire) does not reach The Pass until it finishes,
and "I just fired that and it is not in the list" is where the widget would lose
trust. The hub `jobs/` directory is *not* read in Pass mode: `/status.json`
already covers it, and reading both would give two answers for the same run.

**The files, when The Pass does not answer.** This is the whole v1 model, not a
degraded slice of it:

| Path | Written by | Contains |
| --- | --- | --- |
| `~/.quicktasks/tasks/<id>.json` | `qt` | quicktasks, plus finished Pass jobs copied in by `hub/run-job.sh` (tagged `"source": "pass"`) |
| `<hub>/jobs/<slug>/job.json` | hub `runner.py` | Pass jobs, plus finished quicktasks copied in by `qt`'s `_feed_hub()` (as `item_id: "qt-<task id>"`) |

The footer's Pass dot says which feed is live, green for The Pass and grey for
the files, with the reason in its tooltip. It has to be visible: "all quiet" and
"I cannot see The Pass" must never look the same, because gates and verify rows
are invisible to the file feed.

**One dedup key across every feed**, the id `qt resume` accepts:

- a qt task → its own id
- a Pass row with a `resume_url` → the slug out of the URL
- a hub job or Pass item with `item_id` `qt-<t>` → `t`, collapsing onto the qt
  ledger row
- any other hub job → its directory name, which is what `hub/run-job.sh`
  registers as a quicktask id

When both copies of a run exist, whichever is further along wins its status --
the two writers land at different moments and either can be the stale one -- but
The Pass wins on identity, reason, and report, since it is the only source that
has them. A pending verdict outlives a status change: a job whose ledger row
says done is exactly the job The Pass is asking about.

The hub location follows `qt`'s own `resolve_hub_dir()`: `QT_HUB` overrides
`config.json`'s `hub_dir`, and unset means the hub feed is off.

Polling is every 5 seconds with a 2.5s tolerance so the system can coalesce the
wakeups, plus an immediate read whenever the menu opens. Reads and posts happen
off the main thread, and the poll gives up after 1.5 seconds: a hung request is
indistinguishable from a Pass that is down, so it may as well fall back.

**No `Origin` header is sent.** `serve.py`'s `_origin_blocked()` lets a request
through when `Origin` is absent (browsers always send one cross-origin, CLIs
never do), which is the hole a native app is meant to come in by. The only hosts
ever contacted are `127.0.0.1` and whatever `pass_url` says.

## Command line

The app is also a small CLI, which is how the tests drive it:

```bash
QuicktaskStatus --dump-model                     # the computed menu model, as JSON
QuicktaskStatus --dump-model --limit 500         # all rows, not just visible ones
QuicktaskStatus --dump-capture "call dan"        # the POST /capture body
QuicktaskStatus --dump-decision <id> accept      # the POST /save body
QuicktaskStatus --dump-decision <id> redo "note"
QuicktaskStatus --snapshot out.png               # render the dropdown to a PNG
QuicktaskStatus --help
```

`--dump-model` runs the real feed selection, merge, and ordering code and prints
the result: both a test seam and a read-only way to inspect live state without
opening the menu. The two `--dump-*` payload flags print request bodies without
sending them, because payload construction is the part of an HTTP client most
worth pinning down and the part least worth a live server to check. `--snapshot`
renders the real view against the real feeds using the view's own `cacheDisplay`,
so it needs no Screen Recording permission and works over SSH.

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `QT_DATA` | `~/.quicktasks` | quicktasks data dir |
| `QT_HUB` | `config.json`'s `hub_dir` | hub checkout; empty means the hub feed is off |
| `QT_PASS_URL` | `http://127.0.0.1:8811` | The Pass's base URL; empty pins the widget to the file ledgers |
| `QT_BIN` | `~/.local/bin/qt` and friends | path to the `qt` script |
| `QT_MENUBAR_FIRE_DIR` | `$HOME` | working directory for quick-fired tasks |
| `QT_MENUBAR_AGENT_PLIST` | `~/Library/LaunchAgents/…` | LaunchAgent path the login switch reads and writes |
| `QT_MENUBAR_DEFAULTS_SUITE` | the app's own | preferences domain for the remembered collapse and toggle state |

The last two exist so a test or a snapshot can exercise the login read-back and
the remembered UI state without touching the real ones.

## Tests

```bash
python3 -m unittest discover -s tests -p 'test_menubar_model.py' -v
```

82 tests in `tests/test_menubar_model.py`. They build the app and drive the
real binary against throwaway fixtures, matching the repo's existing style of
testing the real thing as a subprocess rather than reimplementing its logic.
Coverage: `/status.json` parsing and the `needs_you` join, needs-you ordering,
gate rows with no job, report URL construction, the job booleans outranking the
status string, fallback to the files when The Pass is unreachable or answers
garbage or answers something that is not a status payload, the Pass/ledger
merge in both directions, capture and decisions payload construction including
the carry-forward of unreconciled decisions, section membership and collapse
defaults, aggregate precedence, resume affordances, both file dedup directions,
staleness resolution, hub-feed-off, limit trimming, malformed input, and one
read-only pass over the machine's actual ledgers asserting only invariants that
hold for any real state.

The Pass cases stand up a real loopback server on an ephemeral port rather than
mocking one, because the thing most worth proving about that path is that the
round trip works and that its absence is handled. Every file-feed case sets
`QT_PASS_URL=""` so it stays deterministic on a machine where the real Pass
happens to be up. Nothing in the suite writes a LaunchAgent, calls `launchctl`,
posts to a real Pass, or touches the app's real preferences.

The module skips rather than fails when `swiftc` is unavailable.

## Files

| File | Purpose |
| --- | --- |
| `Sources/Model.swift` | Status and reason vocabulary, `TaskRecord`, sections, `MenuModel`, aggregate, ordering |
| `Sources/PassStatus.swift` | Parsing `/status.json`; building the two POST bodies |
| `Sources/PassClient.swift` | The only file that touches the network |
| `Sources/Feed.swift` | Feed selection and the Pass/ledger merge |
| `Sources/Store.swift` | Reads and deduplicates the two file ledgers |
| `Sources/Actions.swift` | Fire, capture, resume, open a report, post a verdict |
| `Sources/LoginItem.swift` | The "Start at login" switch |
| `Sources/MenuView.swift` | The dropdown |
| `Sources/MenuBarIcon.swift` | The menu-bar dot and count |
| `Sources/App.swift` | Entry point, polling controller, `MenuBarExtra` scene |
| `Sources/DumpModel.swift` | `--dump-model`, `--dump-capture`, `--dump-decision` |
| `Sources/Snapshot.swift` | `--snapshot` |
| `build.sh` | Compile, bundle, sign, install, optionally register the agent |
| `com.quicktasks.menubar.plist` | LaunchAgent template, shared by `build.sh` and the toggle |

## Why a Swift app

Three shells were on the table.

**SwiftBar/xbar plugin.** A script that prints menu lines. Trivial to write,
but it has no text field, so quick-fire would have to pop an AppleScript dialog
or a terminal. It also needs a third-party app installed that is not currently
on this machine, and coloured status dots would have to be emoji. Rejected on
fidelity: quick-fire is the ticket's headline feature.

**Python `rumps` app.** A menu-bar app in ~150 lines with a real modal text
input. But `rumps` needs `pip install rumps` and pyobjc, neither of which is
installed here, and a Homebrew Python upgrade breaks a pyobjc virtualenv
regularly enough to be a real recurring cost. Its text input is also a separate
modal window rather than the inline field the reference design shows.

**Swift `MenuBarExtra` app.** Chosen. `.menuBarExtraStyle(.window)` renders
arbitrary SwiftUI, which is the only one of the three that gives a genuine
inline text field, real coloured dots, hover states, inline verdict buttons, and
a footer row. It also turned out to be the *lowest*-maintenance option, not the
highest: twelve source files compiled by the system `swiftc` with zero runtime
dependencies, versus a pip dependency that breaks on Python upgrades. No Xcode
needed, only Command Line Tools, verified against Swift 6.2.4 on macOS 26.4. The
repo already builds and ad-hoc signs an app bundle this way in
`qt install-handler`, so this follows an established pattern here.
