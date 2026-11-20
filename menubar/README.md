# Quicktask menu-bar widget

A macOS status-menu app for `qt` and The Pass. The menu-bar icon is a coloured
dot whose count badge is the hub's own "asks that need you" number; the
dropdown has the ask field at the top ("Ask for something…"), collapsible
sections for what is new, what needs you, what is running, and what is yours,
and a footer with the feed's health and the controls.

It is the front door to the whole loop, not just to `qt`: every quicktask and
every Pass job/item is an **ask** — one id, one address, one state machine,
one set of moves — and this menu is one of two views over the same JSON the
hub serves. An answer to read, a question the run ended on, a permission it is
blocked on, a failure to redo, and your own to-dos with reminders are all one
click from here.

```
●2                                       <- menu bar: dot + badge (asks that need you)

⚡ Ask for something…
  [ Run now | Ask me first ]
─────────────────────────────────────────
● 2 asks need you
─────────────────────────────────────────
⌄ New for you                        1
  ● Billing contact for the GitHub…  New answer · 3m   R ⇧R C ⏎ E
⌄ Needs you                         4
  ● Draft Q3 roadmap rev…  Asks you · 49m   (inline answer field)
  ● Prep the vendor renewal…  Needs your OK · 7d
  ● Shepherd app for Gonfalon    Blocked · 2h   A ⇧A X
  ● Dossier: Agent Platform…    Failed · 4h   ⏎ ↺ ✕ …
⌄ Working                            2
  ● Spinnaker stale pipeline…  Working 4:13 · searching Slack   X
  ● look thru atlas and see…   Working 0:41                     X
⌄ Yours today                        1
  ● Renew the SSL cert   Reminds you at 3:00 PM   E R D
─────────────────────────────────────────
Find any ask ⌘F · Open the desk ⌘D
Refreshed 11:55 AM  ● Pass        ▤ ↻ ⏻
Start at login  (  )
```

That is the asks view, drawn whenever the hub's `/asks.json` answers. When the
hub predates the ask API (a 404) the dropdown keeps the legacy Pass view —
Running, Needs you, Done today, Earlier, with the verdict and Run-it buttons
documented further down — and when no Pass answers at all it falls back to the
file ledgers, mapped to the same ask sections locally. Neither of those older
views changed.

## Install

Needs only Command Line Tools (`xcode-select --install`). No Xcode
project, no SwiftPM manifest, no signing identity, no Python packages.

```bash
cd menubar
./build.sh --run     # build, install to /Applications, launch now
./build.sh --agent   # ...and start it at login
```

`build.sh` compiles the sources with `swiftc`, assembles `Quicktask.app`
(the executable inside it keeps the name `QuicktaskStatus`, so CLI seams and
docs stay valid), writes its `Info.plist` (`LSUIElement`, so no Dock icon or
app-switcher entry), copies the LaunchAgent template into the bundle, ad-hoc
signs it, and copies it to `/Applications/Quicktask.app` -- overridable with
`QT_APP_DIR`. That is separate from `QT_DATA` (default `~/.quicktasks`),
which stays the data dir for tasks, logs, config, and
`QuicktaskResume.app`, and no longer holds the widget itself. A pre-existing
install under the old `~/.quicktasks/QuicktaskStatus.app` path is removed on
the next `build.sh` run, so login can never start a stale copy from there.

Other flags:

| Flag | Effect |
| --- | --- |
| `--no-install` | Build into `./build` only. What the tests use. |
| `--run` | Install and launch immediately. |
| `--agent` | Install a LaunchAgent that starts it at login. |

Opening the app again while it is already running -- from Finder, Spotlight,
or a stray `open`ing of the bundle -- does not draw a second menu-bar dot: it
asks the one running instance to show the same ask panel `⌥Q` opens,
then exits.

### Starting it at login

Either `./build.sh --agent` or the footer's **Start at login** switch writes
`~/Library/LaunchAgents/com.quicktasks.menubar.plist` from the template in this
directory. `build.sh` also bootstraps it; the switch leaves that to the next
login, since a bootout or bootstrap from inside the app would kill or double
the running widget. Both read the same template -- the toggle reads it
out of the app bundle, which is why `build.sh` copies it in -- so the two
cannot drift. `KeepAlive` is deliberately off, so the dropdown's power button is
a real quit and the widget comes back at the next login rather than three
seconds later.

Turning the switch off deletes the plist, so the next login starts nothing; the
widget keeps running until you quit it. To also unload the agent now, by hand:

```bash
launchctl bootout "gui/$(id -u)/com.quicktasks.menubar"
rm ~/Library/LaunchAgents/com.quicktasks.menubar.plist
```

If you would rather use a login item: System Settings → General → Login Items
→ **+** → `/Applications/Quicktask.app`.

## Using it

**The ask field, two ways.** Type into "Ask for something…" at the top and
press return. The segmented toggle under it decides what ⏎ does with the
words, and the choice is remembered. `Tab` flips it without touching the
field; `⌘1`/`⌘2` select Run now/Ask me first directly; `⌘⏎` fires with
whichever mode is *not* currently selected, once, without moving the
remembered default -- the hint caption under the field ("Tab swaps · ⌘⏎ fires
the other way") is there so this is never a party trick you have to remember.

- **Run now** shells out to `qt <your text>`, the same entry point a terminal
  uses, so the task lands in the same ledger with the same notification and
  resume behaviour. The directory it runs in is deliberately *not* one of the
  trusted dirs by default, so a menu-bar task runs under the default
  permission mode instead of silently escalating -- see **The directory
  chip** below for where that directory actually comes from and how to change
  it per fire, not just globally.
- **Ask me first** posts to `POST /asks` with `{text, mode: "ask_first",
  door, dir}` -- the `--in`/`@` prefix parsed and stripped, the resolved
  directory sent along -- so the hub files the words as an ask that waits for
  your OK rather than running anything. A hub old enough to answer 501/404
  gets today's behaviour instead: the raw, unstripped text to `POST /capture`,
  filed as a gate item, byte for byte the To-Pass fire it has always been, and
  the success line says so ("On the Pass: \<full text\>") rather than
  pretending the ask was created. That capture leg ignores the directory chip
  and any typed prefix outright, and refuses text over 4000 characters rather
  than sending it for the route's 400.

A successful fire leaves a **receipt** under the field -- the fixed words plus
the one thing you can still do about it. Run now: "Got it. Running. The
answer will come to you here." Ask me first: "Got it. It waits for your OK."
Run now's receipt carries an **Undo** (a 10-minute window, the same one the
hub's own undo tokens live for): it resolves the fired ask off the board,
stops the run (`qt stop`), and files the ask away (`drop`). The receipt is
drawn separately from the 1.2-second success flash on purpose -- the undo
window is minutes, not a blink, and the receipt is the only thing on the panel
that can still act after the fire itself is done.

**Ask again.** Under the field sits the recent done asks, newest first. A
click loads that ask's own words back into the field, so re-firing is one ⏎
in whichever mode is set, rather than a blind re-run of something finished
days ago.

**The directory chip**, next to the mode toggle, shows the directory Run now
will use, `~`-abbreviated, and dims when Ask me first is selected (that mode
sends the resolved directory along in its own POST; the chip itself is a
Run-now control). Clicking it opens a menu of the eight most recently used
directories (read off `run_cwd` in the `qt` task ledger, most recent first),
plus **Choose…** (pick any folder) and **Reset to default**. The chosen
directory is remembered across launches. You can also just type it: a prefix
of `--in <dir> ` or `@<dir> ` at the start of the field -- the same
convention `raycast/quick-task.sh` uses -- fires that one time in `<dir>` and
is stripped before the rest of the text is sent, without changing what the
chip remembers. Resolution order, highest first: the typed prefix, then
`QT_MENUBAR_FIRE_DIR`, then the chip's own last choice, then `$HOME`.

**Summon hotkey.** A global shortcut -- `⌥Q` by default, changeable (or
clearable) in Settings -- opens the ask panel from anywhere: it shows the panel,
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
same ask-field view rather than the real menu-bar dropdown; clicking the
menu-bar dot still opens the real dropdown exactly as before, unchanged.

**Firing feedback.** The ask field never leaves you unsure whether a fire
took: pressing return disables the field and the mode toggle and shows
"Firing…" (Run now) or "Asking…" (Ask me first) in place of the hint caption.
On success it shows "Fired: \<first 40 characters\>" (Run now) or "On the
Pass: \<full text\>" (the capture fallback on an older hub, never truncated)
for about 1.2 seconds, then clears the field -- and, in the summon
panel only, hides it too; the real dropdown never closes on a fire. While a
live receipt is drawing, the success line itself stays quiet so the same fact
is not said twice. On failure the field stays exactly as typed, disabled
state lifts, and the same message space shows the refusal in red -- "qt not
found; run install.sh", "could not run qt: …", "the Pass is not answering" --
until the next attempt replaces it. These states are shared by the summon
panel and the real dropdown's own ask field, since both host the same view.

**Sections (asks view).** New for you, Needs you, Working, Yours today. Click
a header to collapse it; the state is remembered in `UserDefaults`. None of
them starts collapsed: the sections that carry actions have to be open the
moment the menu opens, or the widget has buried the thing it exists to
surface.

- **New for you** holds the unseen answers -- the rows the bell rang about --
  first, because they are the reason the menu got opened.
- **Needs you** holds everything waiting on a decision, in attention order:
  questions first (a run ended asking you something), then blocked, then
  failed, then unknown states (a hub that grows a tenth state still surfaces
  its rows, not buries them), then wants-your-OK, then the rest -- because a
  question is the thing only you can answer and a verdict is the cheapest
  action available.
- **Working** holds the live runs: title, a stopwatch ticking every second
  off the wall clock, and the live line -- the hub's `now_line`, "searching
  Slack", "reading 14 files", "quiet for 2 min" -- when the hub sends one.
- **Yours today** holds your own to-dos (no live agent work), sorted
  soonest-reminder first, each showing when its nudge comes, or its age.
- Done and dropped asks are hidden, not re-bucketed: a done ask sitting in
  "Needs you" would be a lie with a chevron on it.

**Ask rows.** A row's status word is the hub's own state -- New answer,
Answer, Asks you, Blocked, Failed, Working, Needs your OK, Heard, Yours; an
unknown state keeps the hub's raw word, because the row should still say what
the hub called it rather than guess. The **eye button** at the row's tail
expands it in place: it fetches the thread (`GET /asks/<id>.json`) and draws
the full `answer_text` in a clipped, height-capped scroll -- one row at a
time, the same one-peek-at-a-time gesture the menu has always had, cached per
id + `updated_at` so re-expanding costs nothing, and opening on the hub's
`reason` first when the row is a failure. Expanding an unseen answer also
posts `seen`, which is the moment it stops counting toward the badge. The
**title**, and ⏎ on the highlight, open the ask's one address in the
browser instead -- reading a thread is the one thing every ask always allows,
so it is never dimmed.

**Move buttons and keys.** The buttons come from the hub's own `moves` list
-- the server is the source of truth -- so a move the hub did not offer is a
button the row does not draw, and a feed that carries no moves at all (the
file fallback, a Pass that is down) shows rows that read but do not act.
Curated per state:

| State | Buttons (key) |
| --- | --- |
| answer | Follow up… (R) · Redo with changes… (⇧R) · Copy (C) · Open (⏎) · Done (E) |
| failed | Try with changes… (⏎) · Try again · I'll do it · Drop |
| blocked | Allow once (A) · Always allow (⇧A) · Skip · Stop (X) |
| question | an inline Answer… field -- the one affordance a question has |
| working | Stop |

Text moves open a field right in the row. Try with changes opens it
prefilled with the ask's original words, because "what would you change" is a
question that starts from what was said; every other text move opens empty. A
failed row also carries a "Last attempt: 30m · $1.12 · Sonnet" line from its
own facts, and the hub's plain-word `reason` for the failure.

Every write whose response carries an undo token draws an **undo line** under
the row; `Z` spends the last one, and undo is about the last write, not the
row under the cursor. A 409 or 501 is an answer, not a fault: the hub's own
message shows (a 409 names the state the ask is actually in and the moves it
has now), never a dead button.

Keys are inert while any field has focus -- a row's editor, a question's
answer box, find, the remind picker -- which is what keeps typing into a
follow-up field from firing R, E, or Z under the words.

**Yours rows** carry their own bare keys, resolved the same way and gated on
the hub's `moves` list: `E` done, `R` remind (opens the same picker ⌥⏎ opens,
prefilled with the reminder the row already carries, so adjusting one is a
one-keystroke edit), `D` drop, and Run when the hub offers it. A yours row's
title opens the ask's address, the same rule every other row opens by.

**Find any ask (⌘F).** The find field asks the hub, not the local list:
`GET /asks/search` over every ask ever -- done and archived included, words,
titles, and answers -- and the results arrive as rows (title, where the query
matched, the snippet). Typing is debounced so a phrase is one request; a
click or ⏎ expands a result in place, the same expand a section row runs,
`seen` included when the found ask is still unseen. Esc or an emptied field
closes it and brings the sections back exactly as they were. Typing a bare
letter outside any field still starts the local **filter**, which narrows the
rows on screen across every section; Esc clears it.

**The desk (⌘D).** Opens the hub's desk -- the same asks, one per thread, on
the base URL every ask read and write uses. It is a browser page, so the
panel's business is only opening it.

**Legacy rows** (the `/status.json` view a hub without the ask API draws),
left to right after the status text:

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

**Revive** sends a delivered/done item back to Verify (LD-224). Whether it is
offered at all is The Pass's call, not the widget's: a row only gets the button
when `/status.json` sends `revivable: true`, and an older hub that omits the
field entirely gets no button, the same way a missing `can_run` means no Run
it. `POST /revive` takes just the item id; unlike `/run`'s 409, nothing about
the response is special-cased, so a 404 from a hub old enough to have no such
route just reads as a plain action error. A file-feed row never offers it,
same reasoning as Run it: the ledgers have no such field to read.

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
| ↓ / ↑ | Moves a highlight through the visible rows (ask sections, yours rows, find results). The ends do not wrap. |
| ⏎ | Takes the highlighted row's primary action. An ask row: its return-key button when it has one (Try with changes on a failed row), else opens the ask's one address. A legacy row: resume if there is a session, else the item's deep link. |
| R / ⇧R / C / E | On a highlighted answer row: Follow up… / Redo with changes… / Copy / Done. |
| A / ⇧A / X | On a highlighted blocked row: Allow once / Always allow / Stop. |
| E / R / D | On a highlighted yours row: Done / Remind… / Drop. |
| Z | Spends the last undo line's token. Undo is about the last write, not the row under the cursor. |
| any letter | Starts the local filter, narrowing the rows on screen across every section. |
| ⎋ | Backs out one thing at a time, innermost first: a row's open editor, the remind picker, find (its query first, then the field), the filter, the ask field, then the highlight. |
| Tab | (in the ask field) Flips Run now/Ask me first and remembers the flip. |
| ⌘1 / ⌘2 | (in the ask field) Selects Run now/Ask me first directly. |
| ⌘⏎ | (in the ask field) Fires with the other mode once, without moving the remembered default. |
| ⌥⏎ | (in the ask field) Remind me instead: opens the reminder picker over the typed words. |
| ⌘F | Opens find across every ask ever (the hub's `/asks/search`), results as rows. |
| ⌘D | Opens the hub's desk. |
| ⌥Q (configurable) | Summons the panel from anywhere, even while some other app is focused, and focuses the ask field every time; pressing it again while showing closes it. |

A field with focus owns every key, letters included -- the ask field, the
filter, find, the remind picker, a row's editor, a question's answer box --
which is what keeps "type, press return, ask fired" working and typing into a
follow-up field from firing R, E, or Z under the words. The first arrow key
the panel sees drops the field's focus, so the keys land on the list from
then on. Return is never a fire and never a done-without-undo: the write
keys post their move and draw the undo line the response carries, and a
keystroke that spends a job slot is not one to discover by accident. A
highlight whose row has left the feed is dropped rather than moved, because
the row under the cursor changing identity between polls is how you act on
the wrong thing.

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
| Orange | Something needs you. Count badge. |
| Blue | Nothing needs you; at least one run working. Count badge. |
| Grey | All quiet. |

In the asks view the count is the hub's own `counts.badge`, verbatim, and it
outranks working: an in-flight run changes on its own in the next few
seconds, an ask waiting on you does not. (The legacy `/status.json` view
keeps its own precedence -- running beats attention -- and its own count.)
Ask row dots follow the state: orange for question/blocked/failed, green for
working, blue for a wants-your-OK and for an unseen answer, grey for a seen
answer and anything quiet. Legacy row dots stay coloured by *why* the row
needs you, not by the job status underneath -- teal for verify, purple for a
gate, orange for blocked, red for failed, green for a clean finish -- because
a finished job awaiting a verdict is not green.

**Outcomes** (LD-201 v8). Every producer of "something just happened" --
quick-fire, a row action, the login-item toggle, a Restart Pass verdict,
Settings Apply, a Pass health change -- writes to one persistent queue
instead of the old `flash` string, which vanished the moment the dropdown
closed. The newest unseen outcome draws as a banner at the top of the row
list: "Fired: \<text\>", "Accepted", "Job finished: \<title\>", or an error
in red with the reason ("Restart failed" / "the Pass is not answering",
"Couldn't update the login item: …"). Clicking its **✕** dismisses it on the
spot; left alone, it is marked seen after about two seconds of the dropdown
being open, which just drops the banner without deleting the entry -- seen
outcomes still count toward "N earlier" below the banner, so a burst of
several (a poll that both restarted Pass and finished a job) is never lost
the moment the newest one is dismissed or ages out. The queue holds the
last 20, oldest dropped first, and survives a relaunch: it lives in
`UserDefaults` next to Settings, not in a `@State` that
`MenuBarExtra(.window)` would throw away with the view on close.

**Notifications** (LD-201 v8, health rules revised in v9). Settings has a
"Notify me when the dropdown is closed" toggle, on by default. When it is
on, and only while neither the real dropdown nor the summon panel is on
screen, the same outcomes that would draw a banner also post a macOS
notification: a job finishing or failing, a Pass health change, a Restart
Pass verdict, or a quick-fire failure. Flipping the toggle from off to on
asks macOS for permission once; flipping it off again never re-asks.
Clicking a notification shows the dropdown. All of this goes through one
`Notifier` protocol, so a test can inject a recorder and prove what *would*
have gone to Notification Center without a real notification ever reaching
the sandbox that runs the suite.

Pass health notifications are episode-based, not raw-transition-based (LD-
201 v9). v8 posted a "Pass isn't answering" / "Pass is back" pair on every
single transition, which meant an ordinary slow-under-load stretch -- one
skipped poll, nothing actually wrong -- read as a notification storm.
Instead, one continuous run of not-normal polls is treated as a single
episode: the "Pass isn't answering" notification fires only once that
episode has run for at least 45 seconds, or the widget has fallen all the
way back to file feeds, whichever comes first. "Pass is back" fires only if
a "down" notification actually went out earlier in that same episode. An
episode that resolves before ever crossing the 45-second line still shows up
in the outcome history, as an already-seen "Pass blipped for N s" entry --
it never draws an unread banner and never reaches the notifier. On top of
that, at most one down/back pair reaches Notification Center every ten
minutes: a second outage that starts inside that window still records its
own history-only outcomes, it just does not interrupt anyone a second time.

**Ask notifications** (Asks, slice 2). The hub's bell writes a v2 payload
into the notify inbox (`$QT_DATA/notify-inbox/<uuid>.json`, with
`"source": "hub-bell"`) for every event that deserves one -- an answer, a
failure, a block, a question, a receipt that an ask from a voice or Slack
door landed, a reminder coming due -- and each kind maps to its own
notification category, so the banner's buttons are the ones that ask
carries:

| Category | Buttons | Sound |
| --- | --- | --- |
| `ask.answer` | Follow up… (text input) · Copy · Open | no |
| `ask.failed` | Try again · Change it… (text input) · Open | yes |
| `ask.blocked` | Allow once · Always allow · Skip that step | yes |
| `ask.question` | Answer… (text input) | yes |
| `ask.receipt` | — | no |
| `ask.reminder` | — | yes |

Sound is what buys the time-sensitive interruption level, and only the
sounding kinds (failed, blocked, question, reminder) may set it: an answer or
a receipt is a passive banner that waits to be noticed, a block or a question
may interrupt. The text-input buttons are real notification text inputs: the
typed words POST as that move's body (`follow_up`, or `retry_with_changes`
for Change it…) through the same `AskClient` the rows use, to the same ask
id; every other button POSTs its own move; Copy and Open are client-only,
no route. Clicking the banner itself reveals the ask's row -- the panel
opens with that row highlighted and expanded -- and posts `seen`, so the
badge drops the moment you have looked: reading it from the banner is the
same read as expanding it in the list. A refused move answers in the hub's
own words as an outcome, because the banner is already gone. Older producers
keep dropping v1 payloads, which map to today's categories unchanged, and
the poll-detected fallback notices are suppressed when an inbox v2 notice
for the same ask has already landed -- an answer is one banner, not two.

**The dot's health** (LD-201 v8). Independent of the blue/orange/grey
busy-versus-attention colour above, the same dot carries a second signal for
whether what is on screen is trustworthy: a small notch punched out of its
upper-right edge means Pass has stopped answering but the widget is still
holding its last good read (still legitimately Pass data, just delayed); a
hollow ring instead of a filled dot means the hold window ran out and the
widget has fallen back to the file ledgers. Hovering names the state outright
-- "Holding since HH:MM · Pass isn't answering" or "Pass down since HH:MM ·
file feeds" -- so the shape and the tooltip can never disagree. A files-only
setup with Pass discovery switched off reads as perfectly healthy: there is
no Pass to be down, so nothing should look broken.

**The freshness line**, always visible in the footer next to the source
badge, says how long ago the state above was confirmed: "synced 12 s ago"
while healthy, ticking every second; "holding since HH:MM" while Pass is
stale but still trusted; "file feeds · Pass down since HH:MM" once the hold
window has run out. It is a deliberately separate line from the dot -- the
dot says *which* state, this says *how long ago that state was confirmed* --
so it can tick on its own timer without forcing the dot to redraw every
second too.

## Where the state comes from

Three feeds, in this order -- the ask API, then (only when the hub predates
it) the `/status.json` the menu has always read, then the file ledgers.

**The hub's ask list.** `GET /asks.json` every 5 seconds, with the previous
poll's `rev` riding along as `since_rev`, so an unchanged hub answers
`{unchanged: true, rev}` instead of resending everything. The payload:
`{v, rev, generated_at, counts:{badge, needs, working, done, yours, unseen},
asks:[row]}`. Each row carries `id`, `title`, `words`, `state`, `place`,
`unseen`, `suggested`, `door`, `ledger`, `ref`/`item_id`, the
`created_at`/`updated_at`/`finished_at` stamps, `now_line` (working rows),
`reason` (failed rows), `question`, `blocked_tools`, `answer_excerpt`,
`facts` (elapsed, cost, model, session, run dir), `moves`, `can_run`,
`remind_at`, and `url` -- the ask's one address. Two of those fields are
load-bearing by design:

- `counts.badge` is the menu-bar badge and the headline's number, verbatim --
  never recounted locally, because two clients counting differently is how a
  badge starts to lie. The working count stands in when nothing needs you.
- `moves` is the server-computed list of moves the ask accepts right now,
  and it is the source of truth for every button and key on the row: a move
  the hub did not offer is a button the row does not draw, whichever feed is
  live.

Threads come from `GET /asks/<id>.json` when a row expands (`answer_text`,
the timeline, the runs), fetched off the main thread and cached per id +
`updated_at` so re-expanding costs nothing. Writes are
`POST /asks/<id>/<move>`: a 409 carries `{ok:false, message, state, moves}`
and the row shows the hub's own message -- the state the ask is actually in
-- never an HTTP status or a dead button; a 501 (move registered but not
built) and a 503 (ledger busy) are answers the same way. Unknown fields are
ignored and an unknown state renders gray with the hub's raw word, never
fatal. The hub itself delegates a qt-ledger ask's run moves to the `qt` CLI
(`qt retry`, `qt stop`, `qt continue`, `qt resume --prompt`) -- the menu
never spawns anything but the fire and the receipt's Undo.

**The Pass, over HTTP (a hub without the ask API).** When `/asks.json`
answers 404, the same poll falls through to `GET /status.json` every 5
seconds, v2, exactly as before, and the dropdown draws the legacy view:

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
(or with this widget's ask field) does not reach The Pass until it finishes,
and "I just fired that and it is not in the list" is where the widget would lose
trust. The hub `jobs/` directory is *not* read in Pass mode: `/status.json`
already covers it, and reading both would give two answers for the same run.
In the asks view the same trust is the hub's to keep, and it does: the hub
derives `/asks.json` from the qt ledger itself, so a task fired seconds ago
is already on the board -- queued reads as heard, running as working -- long
before any finish feed could carry it.

**The files, when The Pass does not answer.** This is the whole v1 model, not a
degraded slice of it:

| Path | Written by | Contains |
| --- | --- | --- |
| `~/.quicktasks/tasks/<id>.json` | `qt` | quicktasks, plus finished Pass jobs copied in by `hub/run-job.sh` (tagged `"source": "pass"`) |
| `<hub>/jobs/<slug>/job.json` | hub `runner.py` | Pass jobs, plus finished quicktasks copied in by `qt`'s `_feed_hub()` (as `item_id: "qt-<task id>"`) |

In the asks era the file fallback still speaks asks: the qt task ledger is
read straight off disk and mapped to ask rows locally, with the same
status-to-state mapping the hub applies (queued → heard, running → working,
question → question, blocked → blocked, failed/timeout/stopped → failed,
done → answer, dropped → done), newest first, result text folded into the
excerpt/reason/question fields, denied tools into `blocked_tools`, and the
ask's address stitched in whenever the ledger knows the hub base. But it
knows nothing the files do not: no unseen (nothing is ever "New for you"),
no moves, no sidecar state -- so its rows read, open, and expand off the
recorded result, but offer no buttons, because every move goes through the
hub and the hub is the thing that is down. Bridge records (finished Pass
jobs copied back into the qt ledger) are skipped, same as the hub's own
derivation: they mirror jobs the hub already counts.

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
off the main thread, and the status fetch gives up after 8 seconds (loosened
from 1.5s in LD-201 v9, to stop an ordinary slow response under load from
reading as a Pass that is down); the lighter reachability probe gives up after
3 seconds (loosened from 1.0s the same release). If a poll is still in flight
when the next 5-second tick fires, that tick is skipped outright rather than
starting a second request on top of the first -- requests never stack.

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
QuicktaskStatus --dump-revive <id>               # the POST /revive body (LD-224)
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
QuicktaskStatus --post-revive <id>               # really send an item back to Verify through POST /revive
QuicktaskStatus --dump-restart                   # the POST /restart request: method, path, Origin
QuicktaskStatus --post-restart                   # really POST /restart and print the outcome
QuicktaskStatus --dump-outcomes show,login-on,restart,dismiss-newest   # drive outcome/notification producers headless
QuicktaskStatus --dump-notifications ok,fail,fail,ok \
  --poll-interval-seconds 5 --hold-window-seconds 10   # replay a poll sequence through the health-episode/job trackers
QuicktaskStatus --snapshot out.png               # render the dropdown to a PNG
QuicktaskStatus --snapshot out.png --expand <id-substring>   # ...with one ask row pre-expanded
QuicktaskStatus --snapshot-settings out.png      # render the settings window to a PNG
QuicktaskStatus --ask-dump-model [--ask-since-rev <rev>]
                                                # the ask feed: source, rev, counts, rows
QuicktaskStatus --ask-dump-rows [--ask-expand <id>] [--ask-done <id>] [--ask-undo]
                                                # the ask menu: badge, sections, rows, buttons, keys
QuicktaskStatus --ask-dump-thread <id> [--ask-updated-at <stamp>] [--ask-repeat <n>]
                                                # a thread fetch through the cache (n proves the cache hit)
QuicktaskStatus --ask-post <id> <move> [json]   # really POST one move; exit 1 when it did not take
QuicktaskStatus --ask-press <id> <key> [--ask-text <text>] [--ask-in-field]
                                                # the key walkthrough: what a bare key on that row posts
QuicktaskStatus --ask-notice <payload.json> [--ask-action <id>] [--ask-text <text>]
                                                # a bell payload as its notice: category, sound, actions, routes
QuicktaskStatus --ask-fire <text> [--ask-mode run|ask_first] [--ask-panel] [--ask-undo]
                                                # the ask field's fire, really performed, receipt and Undo included
QuicktaskStatus --ask-again [<id-substring>]    # the Ask-again list; with an id, the words it reloads
QuicktaskStatus --ask-remind "<text>" [--ask-at "<spec>"]
                                                # ⌥⏎'s write, really performed; --ask-row <id> is a
                                                # yours row's own remind move, --ask-at "none" clears
QuicktaskStatus --ask-find "<query>" [--ask-expand <id>]
                                                # ⌘F's search, really performed, results as rows
QuicktaskStatus --ask-desk                      # ⌘D's target: the desk URL, printed
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
reports whether the panel is visible, key, and has the ask field as
its first responder after each one; it is how the LD-201 v7 fix (focus
landing on every summon, not only the first) is tested without a display.
`--dump-fire-outcome <text> [--mode run|pass] [--panel]` really performs the
fire against whatever `QT_BIN`/`QT_PASS_URL` the environment points at, then
runs the result through the same `FireFieldOutcome.describe()` the ask field
itself calls, so the printed state/message/`hides_panel` can never
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
route, or refused the Origin. `--dump-outcomes <seq> [--seen-after <s>]`
(LD-201 v8) drives a real, headless `StatusController` through a
comma-separated sequence of tokens -- `show`/`hide`/`panel-show`/`panel-hide`
open and close the two windows the notification gate checks, `mark-seen`
fires the auto-seen timer early, `login-on`/`login-off`/`restart` exercise
the real (env-forced) login-item and restart producers, `apply`/
`apply-notify-on`/`apply-notify-off` commit a Settings change, `post-ok`/
`post-error`/`post-info`/`notify-ok`/`notify-error` post a synthetic outcome
directly, and `dismiss-newest` removes the top of the queue -- then prints
the resulting `tokens`, `login_item`, `notify_when_hidden`, `dropdown_visible`,
`panel_visible`, `outcomes[]`, `notified[]`, and `authorization_requests`.
Always constructed with `activatesGlobalHotkey: false`, which is what pins it
to a `RecordingNotifier` rather than the real `SystemNotifier` -- the
structural guarantee that nothing this seam does can ever post a real
notification. `--dump-notifications <seq> [--poll-interval-seconds <s>]
[--hold-window-seconds <s>]` (LD-201 v9) replays a comma-separated ok/fail
poll sequence through the same `Feed.load`/`Feed.pollFailed` pipeline a real
poll uses, on a simulated clock, driving one standalone
`HealthEpisodeTracker` and one `JobTransitionTracker` across the whole
sequence -- not a live controller, so it needs no display and posts nothing
real either way. `--hold-window-seconds` overrides `Feed.holdWindow` (90s in
production) so a test can force the files-only fallback within a few
simulated seconds instead of waiting out the real window. Prints each
step's outcome plus that step's `episode_started`/`notified_down`/
`last_pair_at` bookkeeping, and the cumulative `outcomes`/`notified` queues.
`--snapshot` and `--snapshot-settings` render the real view
against the real feeds using the view's own `cacheDisplay`, so neither needs
Screen Recording permission and both work over SSH. `--snapshot --expand
<id-substring>` pre-expands one ask row in the shot, through the same expand
plan a click runs.

The `--ask-*` family is the same idea pointed at the ask paths: every one of
them runs the real feed, the real `AskClient`, and the real decode, then
prints JSON, so a test -- or a person dogfooding -- asserts on what the
widget would show without a display or a live hub. Both spellings work
(`--dump-model --ask-dump-rows` or a bare `--ask-dump-rows`), since Entry
routes any `--ask-*` argument directly. The ones worth knowing by hand:
`--ask-dump-rows` is a read-only way to inspect the live ask menu (source,
badge, the sections with every row's detail, affordances, and move buttons,
plus the legacy ids when the hub predates the ask API); `--ask-dump-model`
the raw feed behind it; `--ask-post` performs one move for real (a 409 is an
answer, not a crash: exit 1, the hub's message printed);
`--ask-dump-thread` proves the thread cache (`--ask-repeat 2` makes the
second fetch hit the cache, no request); `--ask-press` resolves a bare key
the way the root key handler does, and posts what the resolved button would
(`--ask-in-field` proves the inert case); `--ask-notice` decodes one bell
payload into exactly the banner it becomes, category, sound, actions, and
the POST each action routes to; `--ask-remind` parses the same time specs
the picker accepts ("in 2h", "3p", "15:30", "tonight", "tomorrow 9a",
"none" to clear); and `--ask-fire` performs the ask field's fire through the
same calls the field makes -- where `--dump-fire` describes only the
fallback (capture) leg of Ask me first, `--ask-fire` covers both legs, lands
the receipt, and spends its Undo.

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `QT_DATA` | `~/.quicktasks` | quicktasks data dir |
| `QT_APP_DIR` | `/Applications` | where `build.sh` installs `Quicktask.app`, and the first place the login switch and `--agent` look for it |
| `QT_HUB` | `config.json`'s `hub_dir` | hub checkout; empty means the hub feed is off. Also where `.pass-url` is read from, and the hub dir `.pass-url` targets are checked against |
| `QT_PASS_URL` | discovery: 8811, else `.pass-url` for this hub, else the file ledgers | The Pass's base URL; taken as given and never falls back past it. Empty pins the widget to the file ledgers |
| `QT_PASS_DEFAULT_URL` | `http://127.0.0.1:8811` | The address discovery probes first; a test seam so 8811-probing never has to touch a real Pass |
| `QT_BIN` | `~/.local/bin/qt` and friends | path to the `qt` script |
| `QT_MENUBAR_FIRE_DIR` | the directory chip's own choice, else `$HOME` | working directory for quick-fired tasks; outranks the chip, loses to a typed `--in`/`@` prefix |
| `QT_MENUBAR_AGENT_PLIST` | `~/Library/LaunchAgents/…` | LaunchAgent path the login switch reads and writes |
| `QT_MENUBAR_DEFAULTS_SUITE` | the app's own | preferences domain for every stored setting -- the remembered collapse/toggle state, the directory chip's last choice, and the summon hotkey combo |
| `QT_MENUBAR_LOGINITEM_FORCE_OK` | unset | accepted and ignored: the switch no longer calls `launchctl`, so there is nothing to skip; point `QT_MENUBAR_AGENT_PLIST` at a scratch path instead |
| `QT_MENUBAR_LOGINITEM_FORCE_FAIL` | unset | non-empty fails the toggle before it touches the plist, so the toggle's revert-on-failure path is testable on demand |

The last four exist so a test or a snapshot can exercise the login read-back,
the login-item toggle's success and failure outcomes, and the remembered
settings, all without touching the real ones.

## Tests

```bash
make test                # everything, including the menubar modules
make test-quiet          # same, minus the modules whose seams put panels on screen
python3 -m unittest discover -s tests -p 'test_menubar_model.py' -v
```

317 tests in `tests/test_menubar_model.py` (722 across the whole suite, 38 of
them new for LD-201 v8: the persistent outcome queue's insert/cap/dismiss/
mark-seen behaviour, the login-item and Restart Pass outcomes in both their
success and forced-failure shapes, Settings Apply's outcome, the notification
gate's "only while hidden, only when the toggle is on" rule exercised from
every direction (dropdown open, panel open, toggle off, both clear), the
"asked exactly once" authorization guarantee across an off-to-on edge and a
re-apply of unchanged settings, the dot's three `IconHealth` states and the
freshness line's three text forms via `--dump-model --poll-sequence`, and the
rejected-hub message's exact wording; a further 8 new for LD-201 v9, via
`--dump-notifications`: a lone blip producing no notification and one seen
history-only outcome, ten sustained failures producing exactly one down/back
pair, a second episode inside the ten-minute rate-limit window recording its
own outcomes without notifying again, a files-only fallback notifying even
under the 45-second threshold, and a job that vanishes mid-blip and
reappears finished firing its outcome exactly once; a further 11 new for
quick-fire origin and Revive (LD-224): the `--dump-revive`/`--post-revive`
body, trim, and real round trip, a 404 on `/revive` reading as a plain
action error rather than anything special-cased the way `/run`'s 409 is, an
unreachable or unconfigured Pass still erroring rather than going silent, a
file-feed row never offering the button, a `revivable: true` done job
sorting into Done today with no new section, an older hub's payload
defaulting the flag false when the field is missing outright, and the real
subprocess environment threading `QT_ORIGIN=widget` from the dropdown
versus `QT_ORIGIN=summon` from the hotkey panel). A further 146 are new for Asks,
the daily driver, across six new modules that drive the real binary through
the `--ask-*` seams against an `AskFixturePass` loopback server recording
its POSTs: `test_asks_feed` (row/thread decode with unknown fields and
states, the asks → `/status.json` → files feed order, the qt ledger mapped
to asks locally, move POSTs and their 409 answers), `test_asks_rows`
(section order, the badge verbatim off the hub's counts, expand-fetches-and-
posts-seen, Open never dimmed, done with its undo line, the expanded
snapshot), `test_asks_moves_ui` (buttons from the hub's own `moves` list,
the try-with-changes prefill, keys posting their moves and inert inside a
field, undo from response tokens, the 501's own message), `test_asks_bell`
(a category per bell kind, sound only for the sounding kinds, a reply
posting its follow-up with the typed text, v1 payload fallback, no duplicate
against the poll's own notice), `test_asks_field` (run-now fires qt,
ask-me-first posts `/asks` with the `/capture` fallback, the receipt's undo
stops and drops, `now_line` and `reason` rendered), and `test_asks_yours`
(the Yours today section, remind posts in both its forms, find results, the
desk). The CLI side lands in the repo's own suite: `test_qt_moves`
(`qt stop` kills a fake-claude sleeper and its child, `qt retry` keeps the
id), `test_qt_continue` (allow-once lands in that run's settings only, the
skip prompt, the `ASK:` question status and its off switch),
`test_qt_stream` (events written, the result parsed from stream-json, the
json path kept), and `test_bell_delegation` (the banner skip when the hub
has `bell.py`, standalone and old-hub notifies unchanged). They build the
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
LaunchAgent, calls `launchctl`, posts to a real Pass, touches the app's real
preferences, or posts a real macOS notification: `--dump-outcomes` always
builds its `StatusController` the same way `--snapshot` does, which is what
pins it to the `RecordingNotifier` double rather than `SystemNotifier`, and
the login-item outcome tests point `QT_MENUBAR_AGENT_PLIST` at a scratch path
(the switch calls no `launchctl`) and force failures through
`QT_MENUBAR_LOGINITEM_FORCE_FAIL`.

The module skips rather than fails when `swiftc` is unavailable.

## Files

| File | Purpose |
| --- | --- |
| `Sources/Model.swift` | Status and reason vocabulary, `TaskRecord`, sections, `MenuModel`, aggregate, ordering, the keyboard highlight -- and the ask menu: `AskRowModel`, `AskSections`/`AskBoard` (badge, headline), `AskRowMoves`, `AskKeys`, `YoursMoves` |
| `Sources/Ask.swift` | The ask vocabulary: `AskState`, `Ask`, `AskCounts`, `AskThread` -- the contract's row and thread JSON decoded, unknown fields ignored, unknown states gray |
| `Sources/AskClient.swift` | The ask HTTP client: the list (with `since_rev`), threads (cached per id + `updated_at`), move POSTs and their 404/409/501/503 answers |
| `Sources/AskSeams.swift` | The `--ask-*` CLI seams: the ask tests (and dogfooding) drive the real paths through here |
| `Sources/PassStatus.swift` | Parsing `/status.json`; building the three POST bodies |
| `Sources/PassClient.swift` | The only file that touches the network; Pass discovery |
| `Sources/Feed.swift` | Feed selection and the Pass/ledger merge; the ask feed -- `/asks.json` with `since_rev`, the 404 and unreachable fallbacks, the qt ledger mapped to asks locally |
| `Sources/Store.swift` | Reads and deduplicates the two file ledgers |
| `Sources/Actions.swift` | Fire, capture, run, resume, open a report or an item, post a verdict; ask moves, the Ask-me-first fire, remind, find |
| `Sources/LoginItem.swift` | The "Start at login" switch |
| `Sources/MenuView.swift` | The dropdown, including the outcome banner, the ask sections and rows, yours, find, the remind picker, the receipt |
| `Sources/MenuBarIcon.swift` | The menu-bar dot, its busy/attention/idle colour, and its `IconHealth` (normal/held-stale/files-only) shape |
| `Sources/Outcome.swift` | The persistent outcome queue: `Outcome`, `OutcomeStore` |
| `Sources/Transitions.swift` | Turns a model change into an outcome: `HealthTransition`, `JobTransition`, and the cross-poll trackers behind them, `HealthEpisodeTracker` and `JobTransitionTracker` (LD-201 v9) |
| `Sources/Notifier.swift` | The `Notifier` protocol; `SystemNotifier` (real) and `RecordingNotifier` (tests, snapshots, every headless seam); the `ask.*` categories, their banner actions, and the routes they POST |
| `Sources/NotifyInbox.swift` | The notify-inbox watcher: v1 and v2 (bell) payloads decoded into notices, and the suppressions that keep a landed answer to one banner |
| `Sources/Freshness.swift` | The footer's always-on freshness line |
| `Sources/App.swift` | Entry point, polling controller (asks and legacy), `MenuBarExtra` scene, ask-banner routes |
| `Sources/DumpModel.swift` | `--dump-model`, `--dump-endpoint`, `--dump-capture`, `--dump-run`, `--dump-revive`, `--dump-decision`, `--dump-keys`, `--dump-fire`, `--dump-hotkey`, `--dump-recent-dirs`, `--post-run`, `--post-revive`, `--dump-restart`, `--post-restart`, `--dump-outcomes`, `--dump-notifications` (LD-201 v9, revive LD-224); hands any `--ask-*` argument to AskSeams |
| `Sources/Snapshot.swift` | `--snapshot`, `--snapshot-settings`, the ask pre-expand |
| `Sources/Hotkey.swift` | Carbon global hotkey registration, the mode-swap keys, the recorder control in Settings |
| `Sources/FireResolve.swift` | What a fire actually does: directory precedence, `--in`/`@` prefix parsing, the recent-dirs list, the shared description `--dump-fire` and ⌘⏎ both call, and `AskReceipt` -- the landing line and its Undo |
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
highest: the sources -- a couple dozen files by now -- are compiled by the
system `swiftc` with zero runtime
dependencies, versus a pip dependency that breaks on Python upgrades. No Xcode
needed, only Command Line Tools, verified against Swift 6.2.4 on macOS 26.4. The
repo already builds and ad-hoc signs an app bundle this way in
`qt install-handler`, so this follows an established pattern here.
