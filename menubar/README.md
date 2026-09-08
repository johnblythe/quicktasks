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
  ● Prep the vendor renewal…  Needs go · 7d ▶
  ● Shepherd app for Gonfalon    Blocked · 2h ↗
  ● Dossier: Agent Platform…    Failed · 4h ✓ ↺ ✕
⌄ Done today                           2
  ● Secure hiring approval…        Done · 1h ▤ ↗
› Earlier                              1
─────────────────────────────────────────
Recent runs only · the Pass has 412 jobs
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
remembered. `Tab` flips it without touching the field; `⌘1`/`⌘2` select Run
now/To Pass directly; `⌘⏎` fires with whichever mode is *not* currently
selected, once, without moving the remembered default -- the hint caption
under the field ("Tab swaps · ⌘⏎ fires the other way") is there so this is
never a party trick you have to remember.

- **Run now** shells out to `qt <your text>`, the same entry point a terminal
  uses, so the task lands in the same ledger with the same notification and
  resume behaviour. The directory it runs in is deliberately *not* one of the
  trusted dirs by default, so a menu-bar task runs under the default
  permission mode instead of silently escalating -- see **The directory
  chip** below for where that directory actually comes from and how to change
  it per fire, not just globally.
- **To Pass** posts to `POST /capture`, which files it as an item needing your
  go rather than running it. The flash message names the id The Pass assigned
  (`cap-20260904-153933-7ab83a9`). Text over 4000 characters is refused here
  rather than sent, since the route answers 400 for it. To Pass ignores the
  directory chip and any typed `--in`/`@` prefix outright: the raw text,
  prefix included, goes to `/capture` unstripped, because a gate item has no
  directory field to put one in.

**The directory chip**, next to the mode toggle, shows the directory Run now
will use, `~`-abbreviated, and dims when To Pass is selected since it does
not apply there. Clicking it opens a menu of the eight most recently used
directories (read off `run_cwd` in the `qt` task ledger, most recent first),
plus **Choose…** (pick any folder) and **Reset to default**. The chosen
directory is remembered across launches. You can also just type it: a prefix
of `--in <dir> ` or `@<dir> ` at the start of the field -- the same
convention `raycast/quick-task.sh` uses -- fires that one time in `<dir>` and
is stripped before the rest of the text is sent, without changing what the
chip remembers. Resolution order, highest first: the typed prefix, then
`QT_MENUBAR_FIRE_DIR`, then the chip's own last choice, then `$HOME`.

**Summon hotkey.** A global shortcut -- `⌥Q` by default, changeable (or
clearable) in Settings -- opens quick-fire from anywhere: it shows the panel,
brings the app forward, and focuses the field, so typing can start
immediately. That focus lands the same way on every summon, not just the
first: the panel is activated and made a real key window before
`@FocusState` is set, and it is set twice -- once on the next run-loop turn,
once again ~50ms later as belt-and-braces -- because SwiftUI silently drops
a `@FocusState` write made before its hosting window is actually key. `⏎`
fires with whichever mode is currently selected, then hides the panel; `⎋`
closes it; pressing the hotkey again while it is showing closes it too. It
is registered with Carbon's `RegisterEventHotKey`, the same mechanism
menu-bar utilities have used for years, specifically so this needs no
Accessibility or Input Monitoring permission -- unlike
`NSEvent.addGlobalMonitorForEvents`, which would ask for one. Because
SwiftUI's `MenuBarExtra` has no supported way to trigger its own dropdown
from code, the summon hotkey opens a separate floating window hosting the
same quick-fire view rather than the real menu-bar dropdown; clicking the
menu-bar dot still opens the real dropdown exactly as before, unchanged.

**Firing feedback.** The quick-fire field never leaves you unsure whether a
fire took: pressing return disables the field and the mode toggle and shows
"Firing…" (Run now) or "Sending to the Pass…" (To Pass) in place of the hint
caption. On success it shows "Fired: \<first 40 characters\>" (Run now) or
"On the Pass: \<full text\>" (To Pass, never truncated) for about 1.2
seconds, then clears the field -- and, in the summon panel only, hides it
too; the real dropdown never closes on a fire. On failure the field stays
exactly as typed, disabled state lifts, and the same message space shows the
refusal in red -- "qt not found; run install.sh", "could not run qt: …", "the
Pass is not answering" -- until the next attempt replaces it. These states
are shared by the summon panel and the real dropdown's own quick-fire field,
since both host the same view.

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
| ▶ | `/status.json` says `can_run` | Posts `{"id": …}` to `POST /run` |
| ✓ ↺ ✕ | the item's `state` is `verify` | Posts `accept` / `redo` / `reject` |
| ↗ | there is a session to reopen | Opens `quicktask://resume/<slug>` |

The verdict buttons key off the item's **state**, not its reason, matching
`template.html`'s `ACTIONS` map, which gives `verify` exactly those three. The
distinction matters for a job that died in the verify lane: The Pass reports it
as `state: "verify"` with `reason: "failed"`, so the row reads "Failed" and a
verdict is still the action it needs.

**Run it** fires the item's own kickoff prompt as a headless job, which is the
action a gate row exists to be given. Whether it is offered at all is The
Pass's call, not the widget's: `/status.json` sends `can_run` per row, computed
by the same rule the review page's `canRun()` applies (a non-empty prompt, and
a lane that is not already `running` or `verify`), so the two cannot drift. The
prompt itself never travels -- `POST /run` takes the item id and the server
reads the prompt out of its own ledger. A file-feed row never offers it: the
ledgers do not carry the prompt or the lane.

A 409 is an answer, not a fault. The Pass refuses a fire when the item is
already running or when all three job slots are busy, and the widget says so in
the header ("Already running", "Job slots full, not fired") rather than
surfacing an HTTP status.

Clicking the **title** opens the item in The Pass, using the
`item_url_template` the payload carries (`…/?item={item_id}`) with the id
substituted as a query value. On a v1 payload, or on a freshly fired quicktask
The Pass has not heard about yet, it falls back to the Pass root -- landing on
the page beats a dead click.

**Redo** expands an inline field for the note, because a redo without one is
not much of an instruction. **Reject** and **Run it** both ask first, and swap
the row's icons for a confirm pair rather than opening a dialog, which a
menu-bar panel handles badly. They ask for different reasons: reject throws a
finished job's work away, and Run it spends one of three job slots and a
model's time.

**Keyboard**, deliberately minimal:

| Key | Does |
| --- | --- |
| ↓ / ↑ | Moves a highlight through the visible rows. The ends do not wrap. |
| ⏎ | Takes the highlighted row's primary action: resume if there is a session, else the item's deep link. |
| ⎋ | Clears the quick-fire field, then the highlight. |
| Tab | (in the quick-fire field) Flips Run now/To Pass and remembers the flip. |
| ⌘1 / ⌘2 | (in the quick-fire field) Selects Run now/To Pass directly. |
| ⌘⏎ | (in the quick-fire field) Fires with the other mode once, without moving the remembered default. |
| ⌥Q (configurable) | Summons the panel from anywhere, even while some other app is focused, and focuses the quick-fire field every time; pressing it again while showing closes it. |

The quick-fire field owns the arrows and return while it has focus, which is
what keeps "type, press return, task fired" working. The first arrow key the
panel sees drops that focus, so the keys land on the list from then on. Return
is never a verdict and never a fire: both of those ask first, and a keystroke
that spends a job slot is not one to discover by accident. A highlight whose row
has left the feed is dropped rather than moved, because the row under the cursor
changing identity between polls is how you act on the wrong thing.

**Tooltips** carry what the row has no width for: the item id, its lane, the
permission-denial count, the output count, and the error text from a run that
died. That is the same set the file-feed rows have always shown, now fed by
`/status.json`'s own `error` and `denials` in Pass mode.

A verdict posts the same body the review page's Save button posts, and any
decision already sitting unreconciled in `hub/decisions.json` rides along with
it. `serve.py` overwrites that file wholesale on every save, so a one-row post
would otherwise discard a review saved in the browser and not yet reconciled.

**Elapsed time** on in-flight rows ticks every second off the wall clock, not
off the feed, so an open menu counts up between polls. Finished rows keep the
coarse relative age (`2h`).

**The footer** shows when the model was last read, which feed it came from,
then buttons for The Pass, a manual refresh, and quit, plus the login switch.
Its Pass dot's tooltip names the resolved base URL and how it was found, since
"the Pass is not answering" reads very differently depending on whether the
widget guessed port 8811 or read a live URL off disk. When The Pass reports
`counts.truncated` -- it caps `jobs` at 200 -- a line above says so with the
real total, because a widget quietly showing a slice of the history is the kind
of thing you only notice when it matters.

**Restart Pass**, in the settings window behind the footer's gear, POSTs
`/restart` behind a confirm sheet ("Jobs in flight keep running; the page and
this widget reconnect in a few seconds."). A launchd-supervised Pass
(`KeepAlive`) comes back on its own within a bounded ~20s poll, and the sheet
says so first ("Restarting… back in a few seconds") and then either "Pass is
back" or that it is still not answering. A hand-started Pass just stops, and
the sheet says how to start it again by hand. A Pass old enough to predate the
route (404) leaves the button enabled and reports that rather than disabling
it; an Origin the gate refused (403) reports the refusal.

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

**The Pass, over HTTP.** `GET /status.json` every 5 seconds, v2:

```json
{"generated_at": "...", "pass_url": "http://127.0.0.1:8811/",
 "item_url_template": "http://127.0.0.1:8811/?item={item_id}",
 "groups":    [{"key": "gate", "label": "Needs your go", "count": 2, "undone": 1}],
 "counts":    {"running": 2, "verify": 1, "gate": 1, "blocked": 1, "failed": 1,
               "done_today": 4, "total_jobs": 412, "truncated": true},
 "jobs":      [{"item_id": "...", "title": "...", "state": "...", "status": "...",
                "started": "...", "elapsed_s": 252, "failed": false,
                "blocked": false, "session_id": "...", "resume_url": "...",
                "report": "/job/<item_id>/output/report.html", "outputs": [...],
                "finished": "..." , "error": null, "denials": 0,
                "can_run": false}],
 "needs_you": [{"item_id": "...", "title": "...", "state": "...",
                "reason": "verify|gate|blocked|failed", "resume_url": "...",
                "report": "...", "session_id": "...", "started": "...",
                "can_run": true}]}
```

v2 made `needs_you` self-sufficient: it carries its own `resume_url`, `report`,
`session_id`, `started`, and `can_run`. That matters most when a row's job has
been capped out of `jobs` -- the row still resumes and still has its report --
and it means a gate item, which has no job at all, finally arrives with a real
timestamp (its own ledger date) instead of borrowing `generated_at` for
ordering. The join onto `jobs` by `item_id` is still done and still earns its
keep: `elapsed_s`, `outputs`, `error`, and `denials` live only on the job side.
Each field is taken from the `needs_you` entry first and from the job second, so
a stale `jobs` entry cannot rename a row or move it between lanes.

**Done today is decided by `finished`.** Every terminal job now sends one, so
the day a row belongs to is the day it actually ended, not the day
`started + elapsed_s` lands on. That old reconstruction is still there as the
fallback for a v1 payload, and a row with no `finished` and no `started` still
falls back to `generated_at` for *ordering only*: the row sorts and counts as
today without being given an age it does not have. "Needs go - 2s" on an item
held for a week would be a lie, and one that resets on every poll.

Everything v2 added is read as optional, so a v1 payload still parses: no
`finished`, no `can_run` (the Run-it button stays off), no
`item_url_template` (titles open the Pass root), and `denials` read as either
the new count or the old array. Titles are now always sent, but an empty one
still falls back to the item id -- a blank row is worse than an ugly one.
Timestamps arrive as UTC with six fractional digits and a `+00:00` offset.

**Finding The Pass.** It walks `PORT..PORT+9` looking for a free port, so where
it is listening is not something the widget can assume. Four sources, in order:

| Order | Source | Notes |
| --- | --- | --- |
| 1 | `QT_PASS_URL` | Taken as given, and never falls back past it -- an override or a test pins an address the widget should not second-guess. Empty pins the widget to the file ledgers. |
| 2 | `http://127.0.0.1:8811` | The default port, tried before the `.pass-url` file. |
| 3 | `<hub>/.pass-url` | Written by `serve.py` on bind, removed on a graceful shutdown. Only trusted for the *same* hub this widget is configured for. |
| 4 | file feeds | The v1 model: `qt` and hub ledgers read straight off disk. |

8811 now outranks `.pass-url`: a restart race or a stray test server can leave
the file pointing at some other port (commonly 8812) well after the real Pass
has come back up on the default one, and a widget that trusted the file over a
live 8811 would show that stale target's numbers as if they were the hub's own.
Trying 8811 first means a healthy default-port Pass is never shadowed by a
leftover file.

`.pass-url` is only trusted once its own `/status.json` says it is answering
for *this* hub: the payload's `instance.hub_dir`, realpath-resolved, has to
match the widget's own configured hub dir (`~/code/hub` when none is set). A
mismatch is not treated as "unreachable" -- it is reported by name, because a
different Pass answering is a more specific problem than one not answering at
all:

```
rejected: "http://127.0.0.1:8812 serves /Users/john/code/other-hub"
```

An older Pass whose payload has no `instance` field at all cannot make this
claim either way, so it is accepted only once 8811 has already failed to
answer -- exactly the case that predates this check, never as a way to shadow
a live default-port Pass. Discovery re-runs on every poll rather than only at
launch, so a Pass that restarts on another port is followed without
relaunching the widget. A discovered URL has to be `http` on `127.0.0.1` or
`localhost`: this is a file read without anyone asking, so it does not get to
choose the host. A malformed, empty, or non-loopback file is reported in the
footer tooltip and then ignored, so a file caught mid-write cannot take the feed
down with it. An absent file is not a problem at all -- it is the normal state
when The Pass is down.

A `.pass-url` naming a target that does not answer is treated the same way as
a rejected one: a single loopback `GET /status.json`, given about a second to
respond, decides whether the file is trusted or the widget falls through to
the files instead. The footer tooltip and `--dump-endpoint` both still show the
raw file contents alongside whichever address was actually used, so a fallback
or a rejection never looks identical to a live read.

**Holding the last good model.** The Pass server is single-threaded and stalls
occasionally; without this, a single slow poll would flip the headline from a
Pass count to a file count and back on the very next 5-second tick. Instead, a
failed poll after at least one Pass success keeps rendering the last
successful Pass model, unchanged, for up to 90 seconds -- the footer dot turns
amber and its tooltip reads `Pass unreachable since HH:MM · showing HH:MM`
(the last good refresh time). Only once that window runs out does the model
fall back to the files, and the headline then says so:
`<headline> · file feeds only, Pass down`. The very first poll after The Pass
answers again snaps back immediately, whether that recovery lands mid-hold or
after the window has already expired and the widget is already showing files.
Counts never alternate between the two sources on consecutive polls.

Three states, visible in both the footer and `--dump-model`:

| State | Footer dot | `source` | `pass_reachable` | `pass_stale_since` | `held_until` |
| --- | --- | --- | --- | --- | --- |
| Pass live | green | `pass` | `true` | `null` | `null` |
| Pass held (stale) | amber | `pass` | `false` | set | set |
| Files only | grey | `files` | `false` | set once The Pass has gone down, else `null` | `null` |

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
QuicktaskStatus --dump-endpoint                  # where the Pass was found, and how
QuicktaskStatus --dump-capture "call dan"        # the POST /capture body
QuicktaskStatus --dump-run <id>                  # the POST /run body
QuicktaskStatus --dump-decision <id> accept      # the POST /save body
QuicktaskStatus --dump-decision <id> redo "note"
QuicktaskStatus --dump-keys down,down,up         # where the keyboard highlight lands
QuicktaskStatus --dump-keys tab,cmd-return \
  --mode pass --draft "fix it"                   # the mode flip, and what ⌘⏎ would fire
QuicktaskStatus --dump-fire "--in ~/code/hub fix it"   # the resolved argv or /capture body
QuicktaskStatus --dump-fire "call dan" --mode pass
QuicktaskStatus --dump-hotkey                    # the registered summon shortcut, and whether it took
QuicktaskStatus --dump-summon summon,escape,summon   # drives the real ⌥Q/Escape code path, headless
QuicktaskStatus --dump-fire-outcome "call dan" --mode pass --panel   # what the field would show, no display
QuicktaskStatus --dump-recent-dirs               # the chip's recency menu, off the qt ledger
QuicktaskStatus --post-run <id>                  # really fire an item through POST /run
QuicktaskStatus --dump-restart                   # the POST /restart request: method, path, Origin
QuicktaskStatus --post-restart                   # really POST /restart and print the outcome
QuicktaskStatus --snapshot out.png               # render the dropdown to a PNG
QuicktaskStatus --help
```

`--dump-model` runs the real feed selection, merge, and ordering code and prints
the result: both a test seam and a read-only way to inspect live state without
opening the menu. The three `--dump-*` payload flags print request bodies
without sending them, because payload construction is the part of an HTTP client
most worth pinning down and the part least worth a live server to check.
`--dump-endpoint` prints the resolved base URL, which of the four sources it
came from, and why a `.pass-url` was ignored if it was -- either `fallback`
(did not answer) or `rejected` (answered, but for a different hub). 8811 is
probed first via `QT_PASS_DEFAULT_URL` (default `http://127.0.0.1:8811`, a
seam so a test can point the probe at a guaranteed-closed loopback address
instead of ever depending on, or touching, a real Pass on the real port); a
`.pass-url` target is probed only when that fails, with one loopback
`GET /status.json` each, so most of discovery stays testable without
depending on what is really listening. `--dump-model --poll-sequence
ok,fail,fail` replays a whole run of polls -- `ok` makes a real call against
whatever `QT_PASS_URL` points at, `fail` synthesizes a timeout with no network
call at all -- each one `--poll-interval-seconds` (default 5) apart on a
synthetic clock, and prints a `poll_sequence` array with each step's `source`,
`pass_reachable`, `pass_stale_since`, `held_until`, `headline`, and
`record_count`: the seam the hold-timer tests drive. `--dump-keys` walks the highlight over the visible rows
(default collapse, as a freshly opened menu would show them) and prints where
it lands and what return would do there; `tab`, `cmd-1`, `cmd-2`, and
`cmd-return` drive the same mode flip and one-shot other-mode fire the field's
own hotkeys do, with `--mode` seeding which side it starts on and `--draft`
seeding the text `cmd-return` would fire. `--dump-fire <text>` prints exactly
what a Run-now or To-Pass fire of that text would do -- the resolved `argv`
(directory, its source, and the stripped text) or the `/capture` body --
through the same `FireResolve.describe()` that `cmd-return` calls, so the two
can never describe a fire two different ways; `--mode pass` switches it to
the To-Pass side, which ignores any directory entirely. `--dump-hotkey`
registers and immediately unregisters its own copy of the summon shortcut
and prints the key code, modifiers, display string, and whether registration
actually succeeded, without touching a real running widget's own
registration. `--dump-summon <tokens>` drives `toggleHotkeyPanel()` and
`hideHotkeyPanel()` directly -- the same calls the real hotkey and Escape
make -- through a comma-separated sequence of `summon`/`escape` tokens, and
reports whether the panel is visible, key, and has the quick-fire field as
its first responder after each one; it is how the LD-201 v7 fix (focus
landing on every summon, not only the first) is tested without a display.
`--dump-fire-outcome <text> [--mode run|pass] [--panel]` really performs the
fire against whatever `QT_BIN`/`QT_PASS_URL` the environment points at, then
runs the result through the same `FireFieldOutcome.describe()` the quick-fire
field itself calls, so the printed state/message/`hides_panel` can never
drift from what the field would show; `--panel` reports as the standalone
summon panel (which closes on a successful fire) rather than the real
dropdown (which never does). `--dump-recent-dirs` prints the directory chip's recency menu,
read off `run_cwd` in the `qt` task ledger. `--post-run` is the one seam that
really posts: it fires an item through `POST /run` against whatever
`QT_PASS_URL` points at, and exits non-zero with the widget's own wording for a
409. `--dump-restart` prints the `POST /restart` request -- method, path, and
the `Origin` header the gate requires -- without sending it; `--post-restart`
gives that same request the real-round-trip treatment `--post-run` gets, and
prints whether the Pass reports itself supervised, stopped, too old for the
route, or refused the Origin. `--snapshot` renders the real view against the
real feeds using the view's own `cacheDisplay`, so it needs no Screen Recording
permission and works over SSH.

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `QT_DATA` | `~/.quicktasks` | quicktasks data dir |
| `QT_HUB` | `config.json`'s `hub_dir` | hub checkout; empty means the hub feed is off. Also where `.pass-url` is read from, and the hub dir `.pass-url` targets are checked against |
| `QT_PASS_URL` | discovery: 8811, else `.pass-url` for this hub, else the file ledgers | The Pass's base URL; taken as given and never falls back past it. Empty pins the widget to the file ledgers |
| `QT_PASS_DEFAULT_URL` | `http://127.0.0.1:8811` | The address discovery probes first; a test seam so 8811-probing never has to touch a real Pass |
| `QT_BIN` | `~/.local/bin/qt` and friends | path to the `qt` script |
| `QT_MENUBAR_FIRE_DIR` | the directory chip's own choice, else `$HOME` | working directory for quick-fired tasks; outranks the chip, loses to a typed `--in`/`@` prefix |
| `QT_MENUBAR_AGENT_PLIST` | `~/Library/LaunchAgents/…` | LaunchAgent path the login switch reads and writes |
| `QT_MENUBAR_DEFAULTS_SUITE` | the app's own | preferences domain for every stored setting -- the remembered collapse/toggle state, the directory chip's last choice, and the summon hotkey combo |

The last two exist so a test or a snapshot can exercise the login read-back and
the remembered settings without touching the real ones.

## Tests

```bash
python3 -m unittest discover -s tests -p 'test_menubar_model.py' -v
```

240 tests in `tests/test_menubar_model.py` (252 across the whole suite, 13 of
them new for LD-201 v7: focus landing on every summon rather than only the
first, and the quick-fire field's firing/fired/failed states). They build the
app and drive the
real binary against throwaway fixtures, matching the repo's existing style of
testing the real thing as a subprocess rather than reimplementing its logic.
Coverage: `/status.json` v2 parsing field by field and the `needs_you` join in
both directions, needs-you ordering, gate rows with no job, Done today decided
by `finished` (and the v1 reconstruction it falls back to), report URL
construction, the deep link's substitution and its two fallbacks, the job
booleans outranking the status string, `can_run` and the `POST /run` body, the
409 wordings and the 400 that is not dressed up as one, Pass discovery in all
four orders including a malformed, empty, non-loopback, or non-http
`.pass-url`, falling back to the files when a discovered file names a target
that does not answer, `.pass-url` rejected by a mismatched `instance.hub_dir`
even with 8811 down, realpath-resolved hub-dir equality rather than string
equality, a payload with no `instance` field accepted only once 8811 has
failed, `QT_PASS_URL` never falling back even with both 8811 and the file
live, the full hold-timer lifecycle from a good poll through a run of failures
to the fallback and an immediate snap-back on recovery (mid-hold and after the
window has already expired), `POST /restart`'s supervised, unsupervised, 404,
and 403 outcomes, the keyboard highlight's walk and its clamped ends, fallback to
the files when The Pass is unreachable or answers garbage or answers something
that is not a status payload, the Pass/ledger merge in both directions, capture
and decisions payload construction including the carry-forward of unreconciled
decisions and the capture length limit, section membership and collapse
defaults, aggregate precedence, resume affordances, both file dedup directions,
staleness resolution, hub-feed-off, limit trimming, malformed input, the
mode-swap keys' flips and one-shot other-mode fire in both starting modes, the
fire directory's full precedence order down to an invalid prefix falling
through, To Pass's refusal to carry a directory at all, the recent-dirs list's
dedup/order/cap, the summon hotkey's default and an overridden combo each in
their own isolated preferences suite so neither can read or write the real
widget's settings, and one read-only pass over the machine's actual ledgers
asserting only invariants that hold for any real state.

`TestRealStatusSample` and `TestStatusV2Sample` hold real `/status.json` bodies
verbatim, as raw bytes rather than rebuilt from the test helpers, so the suite
keeps checking the widget against what the server actually sends. The v1 sample
pins the back-compatible reading of absent keys, a trailing slash on `pass_url`,
six-digit fractional UTC, zero-count groups, and a failed job in the verify
lane. The v2 sample pins every key the current server sends, in its order,
including a `finished` deliberately different from `started + elapsed_s` so a
parsed finish time cannot be confused with a reconstructed one.

The Pass cases stand up a real loopback server on an ephemeral port rather than
mocking one, because the thing most worth proving about that path is that the
round trip works and that its absence is handled. Every file-feed case sets
`QT_PASS_URL=""` so it stays deterministic on a machine where the real Pass
happens to be up, and most of the discovery cases go through `--dump-endpoint`
in a way that still makes no request. The cases proving the fallback instead
point `--dump-endpoint` at a real fixture or a deliberately closed port, so the
probe itself is exercised rather than assumed. Nothing in the suite writes a
LaunchAgent, calls `launchctl`, posts to a real Pass, or touches the app's real
preferences.

The module skips rather than fails when `swiftc` is unavailable.

## Files

| File | Purpose |
| --- | --- |
| `Sources/Model.swift` | Status and reason vocabulary, `TaskRecord`, sections, `MenuModel`, aggregate, ordering, the keyboard highlight |
| `Sources/PassStatus.swift` | Parsing `/status.json`; building the three POST bodies |
| `Sources/PassClient.swift` | The only file that touches the network; Pass discovery |
| `Sources/Feed.swift` | Feed selection and the Pass/ledger merge |
| `Sources/Store.swift` | Reads and deduplicates the two file ledgers |
| `Sources/Actions.swift` | Fire, capture, run, resume, open a report or an item, post a verdict |
| `Sources/LoginItem.swift` | The "Start at login" switch |
| `Sources/MenuView.swift` | The dropdown |
| `Sources/MenuBarIcon.swift` | The menu-bar dot and count |
| `Sources/App.swift` | Entry point, polling controller, `MenuBarExtra` scene |
| `Sources/DumpModel.swift` | `--dump-model`, `--dump-endpoint`, `--dump-capture`, `--dump-run`, `--dump-decision`, `--dump-keys`, `--dump-fire`, `--dump-hotkey`, `--dump-recent-dirs`, `--post-run`, `--dump-restart`, `--post-restart` |
| `Sources/Snapshot.swift` | `--snapshot`, `--snapshot-settings` |
| `Sources/Hotkey.swift` | Carbon global hotkey registration, the mode-swap keys, the recorder control in Settings |
| `Sources/FireResolve.swift` | What a fire actually does: directory precedence, `--in`/`@` prefix parsing, the recent-dirs list, and the shared description `--dump-fire` and ⌘⏎ both call |
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
