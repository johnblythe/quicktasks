# Quicktask menu-bar widget

A macOS status-menu app for `qt` and The Pass. The menu-bar icon is a coloured
dot showing aggregate state; the dropdown has a quick-fire text field at the
top, one row per recent run with a status dot and one-click resume, and a
footer with the refresh time.

It makes `qt` usable without Raycast: fire a task, see what is blocked, reopen
it, all from the menu bar.

```
  ●3                                   <- menu bar: dot + count

  ⚡ Fire a quick task…
  ─────────────────────────────────────
  ● 3 tasks need you
  ─────────────────────────────────────
  ● send out a swarm of rese…  Blocked · 1d  ↗
  ● Dossier: Agent Platform…    Failed · 4d  ↗
  ● look thru atlas to see if…   Done · 40m  ↗
  ─────────────────────────────────────
  Refreshed 9:46 AM         ▤   ↻   ⏻
```

## Install

Needs only the Command Line Tools (`xcode-select --install`). No Xcode
project, no SwiftPM manifest, no signing identity, no Python packages.

```bash
cd menubar
./build.sh --run      # build, install to ~/.quicktasks, launch now
./build.sh --agent    # ...and start it at every login
```

`build.sh` compiles the sources with `swiftc`, assembles
`QuicktaskStatus.app`, writes its `Info.plist` (`LSUIElement`, so no Dock icon
or app-switcher entry), ad-hoc signs it, and copies it to
`~/.quicktasks/QuicktaskStatus.app`.

Other flags:

| Flag | Effect |
| --- | --- |
| `--no-install` | Build into `./build` only. What the tests use. |
| `--run` | Install and launch immediately. |
| `--agent` | Install a LaunchAgent that starts it at login. |

### Starting it at login

`./build.sh --agent` writes `~/Library/LaunchAgents/com.quicktasks.menubar.plist`
from the template in this directory and bootstraps it. `KeepAlive` is
deliberately off, so the dropdown's power button is a real quit and the widget
comes back at the next login rather than three seconds later.

Remove it with:

```bash
launchctl bootout "gui/$(id -u)/com.quicktasks.menubar"
rm ~/Library/LaunchAgents/com.quicktasks.menubar.plist
```

If you would rather use a login item: System Settings → General → Login Items
→ **+** → `~/.quicktasks/QuicktaskStatus.app`.

## Using it

**Quick-fire.** Type into the field at the top and press return. This shells out
to `qt <your text>`, the same entry point a terminal uses, so the task lands in
the same ledger with the same notification and resume behaviour. It runs with
`$HOME` as the working directory, which is deliberately *not* one of your
trusted dirs, so a menu-bar task runs under the default permission mode instead
of silently escalating. Point it somewhere else with `QT_MENUBAR_FIRE_DIR`.

**Resume.** Click any row that shows the ↗ arrow. That opens
`quicktask://resume/<id>`, the same URL scheme Slack resume links use, so it
respects your `qt setup` terminal choice, including cmux. If the handler is not
registered it falls back to running `qt` directly; register it with
`qt install-handler`. Rows without a session id show no arrow, because there is
nothing to reopen and a dead click would be worse than no click.

**The footer** shows when the model was last read, then buttons for The Pass
(`http://127.0.0.1:8811/`), refresh now, and quit.

**Row order** is three bands: in-flight, then needs-you, then everything that
finished cleanly, newest first within each band. Blocked and failed runs pin
above successful ones so the resume click is actually one click and not one
click after a scroll.

**The dot**:

| Colour | Meaning |
| --- | --- |
| Blue | At least one run is running or queued. Count is the badge. |
| Orange | Nothing running; something is blocked, failed, or timed out. |
| Grey | All quiet. |
| Green | A finished, successful run (rows only). |
| Red | A failed or timed-out run (rows only). |

Running beats attention in the aggregate, because an in-flight run is the thing
most likely to change in the next few seconds.

## Where the state comes from

Two ledgers hold the truth, and each mirrors into the other when a run
finishes:

| Path | Written by | Contains |
| --- | --- | --- |
| `~/.quicktasks/tasks/<id>.json` | `qt` | quicktasks, plus finished Pass jobs copied in by `hub/run-job.sh` (tagged `"source": "pass"`) |
| `<hub>/jobs/<slug>/job.json` | hub `runner.py` | Pass jobs, plus finished quicktasks copied in by `qt`'s `_feed_hub()` (as `item_id: "qt-<task id>"`) |

Both are read and deduplicated. Reading only the qt ledger would miss a Pass
job while it is still running, which is exactly the state the widget exists to
show. The dedup key is the id `qt resume` accepts:

- a qt task → its own id
- a hub job with `item_id` `qt-<t>` → `t`, collapsing onto the qt ledger row
- any other hub job → its directory name, which is what `hub/run-job.sh`
  registers as a quicktask id, collapsing onto the mirrored `"source": "pass"`
  row

When both copies of a run exist, whichever has a `finished` timestamp wins: the
two writers land at different moments and either can be the stale one.

**Why files and not `serve.py`.** The Pass exposes `GET /` (full HTML),
`/search`, and `/job/<item_id>`, so there is no aggregate JSON route to poll.
Reading files also means the widget keeps working when The Pass is not running,
which is most of the time.

The hub location follows `qt`'s own `resolve_hub_dir()`: `QT_HUB` overrides
`config.json`'s `hub_dir`, and unset means the hub feed is off and only the qt
ledger is read.

Polling is every 5 seconds with a 2.5s tolerance so the system can coalesce the
wakeups, plus an immediate read whenever the menu opens. Reads happen off the
main thread. **No network calls** beyond opening `127.0.0.1:8811` in the
browser when you click the footer button.

## Command line

The app is also a small CLI, which is how the tests drive it:

```bash
QuicktaskStatus --dump-model              # the computed menu model, as JSON
QuicktaskStatus --dump-model --limit 500  # all rows, not just the visible ones
QuicktaskStatus --snapshot out.png        # render the dropdown to a PNG
QuicktaskStatus --help
```

`--dump-model` runs the real state-reading and ordering code and prints the
result, so it is both the test seam and a read-only way to inspect live state
without opening the menu. `--snapshot` renders the real view against the real
ledgers using the view's own `cacheDisplay`, so it needs no Screen Recording
permission and works over SSH. Both are useful for iterating on the layout.

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `QT_DATA` | `~/.quicktasks` | quicktasks data directory |
| `QT_HUB` | `config.json`'s `hub_dir` | hub checkout; empty means hub feed off |
| `QT_BIN` | `~/.local/bin/qt` and friends | path to the `qt` script |
| `QT_MENUBAR_FIRE_DIR` | `$HOME` | working directory for quick-fired tasks |

## Tests

```bash
python3 -m unittest discover -s tests -p 'test_menubar_model.py' -v
```

34 tests in `tests/test_menubar_model.py`. They build the app and drive the
real binary with `--dump-model` against throwaway fixture ledgers, matching
this repo's existing style of testing the real thing as a subprocess rather
than reimplementing its logic. Coverage: aggregate precedence, resume
affordances, both dedup directions, staleness resolution, hub-feed-off, band
ordering, limit trimming, malformed input, and one read-only pass over the
machine's actual ledgers asserting only invariants that hold for any real
state. The module skips rather than fails when `swiftc` is unavailable.

## Files

| File | Purpose |
| --- | --- |
| `Sources/Model.swift` | Status vocabulary, `TaskRecord`, `MenuModel`, aggregate, ordering |
| `Sources/Store.swift` | Reads and deduplicates the two ledgers |
| `Sources/Actions.swift` | Fire, resume, open The Pass; explicit binary resolution |
| `Sources/MenuView.swift` | The dropdown |
| `Sources/MenuBarIcon.swift` | The menu-bar dot and count |
| `Sources/App.swift` | Entry point, polling controller, `MenuBarExtra` scene |
| `Sources/DumpModel.swift` | `--dump-model` |
| `Sources/Snapshot.swift` | `--snapshot` |
| `build.sh` | Compile, bundle, sign, install, optionally register the agent |
| `com.quicktasks.menubar.plist` | LaunchAgent template |

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
inline text field, real coloured dots, hover states, and a footer row. It also
turned out to be the *lowest*-maintenance option, not the highest: eight source
files compiled by the system `swiftc` with zero runtime dependencies, versus a
pip dependency that breaks on Python upgrades. No Xcode needed, only Command
Line Tools, verified against Swift 6.2.4 on macOS 26.4. The repo already builds
and ad-hoc signs an app bundle this way in `qt install-handler`, so this
follows an established pattern here.
