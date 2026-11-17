# quicktasks (`qt`)

Fire-and-forget one-shot tasks for Claude Code. Like tagging Claude in Slack, except from anywhere on your Mac: a Raycast hotkey or a one-line CLI. No session to babysit, no orphaned terminal tabs. Every run lands in a ledger with a status, a result, and a session id you can reopen later.

```
qt "pull the confluence draft at <url> into my writing den ideas folder"
# → queued 0822-141530-pull-the-confluence
# ...a couple minutes later, a desktop notification with the outcome
```

## Install

1. From this directory, run `./install.sh`. It symlinks `qt` into `~/.local/bin` and, if run interactively, offers to run `qt setup` right away.
2. `qt setup` (skip if you already ran it above) picks your terminal for resume (cmux, Ghostty, iTerm, Terminal, or a custom launch template), offers a one-off test launch to confirm it works, sets your permission mode, and lets you add trusted dirs.
3. `qt doctor` checks the whole chain: claude CLI, data dir, config, terminal readiness, notifier, PATH, trusted dirs. Read-only, exits nonzero only on a hard failure.
4. Raycast, pick one or both:
   - **Script commands** (zero dependencies): Settings → Extensions → Script Commands → Add Script Directory → the `raycast/` folder here. Three commands: **Quick Task** (fire), **Quick Task List** (recent tasks + results), **Quick Task Resume** (reopen a blocked task; empty argument = latest blocked).
   - **Extension** (interactive ledger, needs Node 22+): `cd raycast-ext && npm install && npm run dev`, then Ctrl-C once Raycast has picked it up; it stays installed as a local dev extension. **New Quick Task** fires a task with an optional run dir. **Quick Tasks** is a native list of recent tasks: search, a status filter, blocked tasks pinned in their own section, and per-row actions to resume in your terminal, view the log, copy the resume command or session id or task id, open the log file, re-run, or delete.

   Suggested hotkeys either way: ⌥Q on the fire command (Quick Task, or New Quick Task), ⌥⇧Q on the browse command (Quick Task List, or Quick Tasks).
5. Menu-bar widget (optional, no Raycast needed): `cd menubar && ./build.sh --agent`. See [Menu-bar widget](#menu-bar-widget) below.

Requires: `claude` CLI, python3, macOS. The Raycast extension additionally needs Node 22+. The menu-bar widget additionally needs the Command Line Tools (`xcode-select --install`).

## Menu-bar widget

A native status-menu app so `qt` is usable with no Raycast and no terminal. The
menu-bar icon is a coloured dot whose count is the hub's own "asks that need
you" badge; the dropdown has the ask field ("Ask for something…", ⏎ Run now /
⌘⏎ Ask me first), one row per ask in sections — New for you, Needs you,
Working, Yours today — that expand in place to the answer and carry their moves
as buttons and keys, and a refreshed-at footer. A hub that predates the ask
API (or the Pass being down) draws the legacy run list exactly as before.

```bash
cd menubar
./build.sh --run      # build, install to /Applications, launch now
./build.sh --agent    # ...and start it at every login
```

It reads both ledgers, `~/.quicktasks/tasks/` and the hub's `jobs/`, so an
in-flight job fired from The Pass shows up alongside your quicktasks. Blocked
and failed runs pin to the top of the list. Clicking a row opens
`quicktask://resume/<id>`, the same handler Slack resume links use, so it
honours your `qt setup` terminal choice. Nothing but local files and
`127.0.0.1`.

Full documentation, including the CLI (`--dump-model`, `--snapshot`) and why
this is a Swift app rather than a SwiftBar plugin or a `rumps` script, is in
[`menubar/README.md`](menubar/README.md).

## No Raycast? Hotkey via macOS Shortcuts

Every Mac ships with Shortcuts, and it supports global hotkeys. Two shortcuts cover the whole flow:

**Fire** (the ⌥Q equivalent):
1. New shortcut → add **Ask for Input** (Text), prompt: "what should Claude do?"
2. Add **Run Shell Script**, Pass Input: **as arguments**, script:
   ```bash
   "$HOME/.local/bin/qt" "$1"
   ```
3. In the shortcut's detail pane, **Add Keyboard Shortcut** and record one (⌥Q is usually free).

**Ledger** (the list view):
1. New shortcut → **Run Shell Script**: `"$HOME/.local/bin/qt" list 15`
2. Add **Show Result**. Bind ⌥⇧Q.

Shortcuts runs a bare shell, hence the absolute path; `qt` locates `claude` on its own. Hammerspoon/skhd/BetterTouchTool users can bind the same one-liners to whatever prompt UX they prefer, and plain `qt` in any terminal is the universal fallback.

## Usage

| Command | What it does |
|---|---|
| `qt "do a thing"` | queue, return immediately, notify on finish |
| `qt -w "do a thing"` | run in the foreground, print the result |
| `qt --in <dir> "..."` | run the task in `<dir>` (in place if trusted) |
| `qt -m <model> "..."` | override the model for this task |
| `qt list` | recent tasks with status glyphs |
| `qt log <id>` | full record + raw log path (unique id fragment works) |
| `qt open <id>` | open the ask page (hub on), else the task's result |
| `qt stop <id>` | kill a running task (marks it stopped) |
| `qt retry <id> [--prompt "<text>"\|-]` | run the same task again under the same id (attempts accumulate) |
| `qt resume <id>` | reopen a task as an interactive session |
| `qt resume <id> --prompt "<text>"` | continue a run headlessly with `<text>` as the next turn (also answers an `ASK:` question) |
| `qt continue <id> (--allow-once <tool>)... \| --skip` | continue a blocked run headless; the tools are allowed for that run only |
| `qt resume-log [n]` | last n resume-launch records (terminal, branch, outcome) |
| `qt setup` | pick terminal, trusted dirs, permission mode, default model |
| `qt doctor` | read-only environment health check |
| `qt install-handler` / `qt uninstall-handler` | register or remove `quicktask://` links (clickable Slack resume); sweeps any other bundle already claiming the scheme |
| `qt trust [dir]` / `qt untrust <dir>` | manage trusted dirs |
| `qt hub <dir>` / `qt hub off` / `qt hub status` | feed finished tasks into a Pass ledger, or check |

## How it works

`qt` detaches a `claude -p` run. By default it runs in a fixed workspace (`~/.quicktasks/workspace/`), so your global CLAUDE.md, tools, and memory apply no matter where you fired it from. The workspace CLAUDE.md tells the agent it's unattended: never ask questions, lead with the outcome, don't expand scope. Each task is one JSON file in `~/.quicktasks/tasks/`; raw transcripts in `~/.quicktasks/logs/`. The invocation directory is passed as context so "this repo" works from a terminal.

## Asks: one id, one address, many runs

With a hub configured, every quicktask is also an **ask** in the hub's derived list: id `qt-<tid>` — the same id before and after it reaches the hub, stable from queue time — one address `http://127.0.0.1:<port>/ask/qt-<tid>`, and a state machine the hub computes by reading qt's own ledger. A **run** is one claude invocation inside an ask: the first fire, a retry, a follow-up, a continue. Redoing or steering an ask never spawns a new one; runs accumulate (`attempts[]` on the task record) under the same id. The hub delegates an ask's moves back to these verbs, and everything below works from the shell too:

- **`qt retry <id> [--prompt "<text>"|-]`** runs the same task again under the same id. The attempt is appended to `attempts[]` (the original run counts as 1), the previous outcome, session, denials, and question are cleared, and the run is spawned detached exactly like a fresh queue. `--prompt` replaces the words; `-` reads them from stdin. Exit 0 queued, 2 if the task is still running or queued (stop it first), 1 unknown id.
- **`qt stop <id>`** kills the run's whole process group (SIGTERM, then SIGKILL after 3 s), marks the task `stopped` with the result "Stopped by you", and feeds the hub. Exit 0 also when the task is not running — it just prints "not running" — so a stop triggered from a notification, a menu row, or a script never needs to check first. A run that finishes on its own mid-stop wins: the status it earned is kept.
- **`qt continue <id> (--allow-once <tool>)... | --skip [--prompt "<text>"]`** is the move after a blocked run. It resumes the run's session headlessly, exactly like `qt resume <id> --prompt`, but `--allow-once` renders the named tools into that one run's `--settings` allow list — nothing persists; `qt allow <tool>` is the permanent version — and `--skip` sends the standard "That tool is not available to you; skip that step and finish the rest." instruction instead. The two flags are exclusive; `--prompt` replaces either's default wording.
- **`qt open <id>`** opens the ask's one address in the browser when a hub is configured. Without one it keeps today's behavior: the hub mirror's `RESULT.md` first, then the run dir's, then the recorded result text.

### The question convention

A headless run can't answer a question mid-flight, so the ones that matter move to the end. With config `questions` on (the default), every task prompt carries a tail telling the model: if you cannot finish without the owner's input, end your final message with one line `ASK: <question>` — and only when truly stuck, otherwise make the most reasonable assumption and finish. A result whose last non-empty line starts `ASK:` stamps the task `question` rather than `done`, so the ask waits for you instead of masquerading as finished, and the question itself rides into the hub job record, the menu bar's row, and the notification. Answer it wherever you saw it: `qt resume <id> --prompt "<answer>"`, the row's inline answer field, or the banner's Answer… button — all the same follow-up. With `questions` off, the tail is not sent and a trailing `ASK:` line is just text in a normal done result.

### Streaming events

Every run kind — first fire, retry, follow-up, continue — runs claude with `--output-format stream-json` and appends the events to `$QT_DATA/logs/<tid>.events.jsonl` (recorded as `events_path` on the task). Each run truncates the file, so it always holds the current (or most recent) run's events; that file is what the hub's live "now line" reads while the ask is working, which is how a working row in the menu bar can say "reading 14 files" or "searching Slack" instead of just a stopwatch. The final `result` event is parsed into the same fields as the old plain-json output, so `qt list`, `qt log`, and the hub feed are unchanged, and a run whose stream can't be parsed falls back to the json path.

### One bell per ask

When the configured hub's checkout has a `bell.py`, the hub owns the bell: it rings for a qt ask itself when its `notice.py` sees the job record qt already wrote, so qt skips its own finish/blocked/failed/timeout/continuation banners — one bell per ask, not two. The check is per finish and never cached, so a hub upgraded mid-flight is honored immediately. Standalone qt (no hub) and an older hub without `bell.py` keep every banner exactly as before. The DM-fallback "DM not sent" notice is deliberately not gated on this: it reports qt's own Slack send failing, an event the hub has no record of, so it always rings.

## Permissions: trusted dirs and the blocked flow

Two tiers, both explicit:

- **Trusted dirs** (`qt trust ~/code/writing-den` or via `qt setup`): tasks fired in a trusted dir run in that dir itself, under `auto` permissions (see below). Set config `"trusted_permissions": "bypassPermissions"` if you want trusted dirs to skip approval entirely. Firing `qt` from inside a trusted dir runs the task there automatically; from anywhere else, target one with `--in`. The list starts empty; every entry is your call.
- **Everywhere else**: permission mode resolves `QT_PERMISSIONS` env > config `"permissions"` > `acceptEdits`, plus whatever your global `~/.claude/settings.json` allowlist already permits. Headless runs can't prompt, so anything outside that is auto-denied.

`auto` mode is the useful middle ground, and the default for trusted dirs: Claude Code's classifier (a Sonnet 5 model, independent of your session model) approves safe tool calls and denies risky ones, so far fewer tasks come back blocked than under `acceptEdits`. Setting `"permissions": "auto"` applies the same everywhere else. Caveat: auto mode requires a session model that supports it (Sonnet 4.6+/Opus 4.6+/Fable 5). Unsupported models like Haiku silently downgrade to Manual, which in headless means everything non-allowlisted is denied; don't pair `-m haiku` with auto and expect it to work.

A denied run is marked **blocked** (`⊘` in `qt list`), records the exact denied tool call, and raises a notification naming what was denied. Resume it without touching a terminal: Raycast → **Quick Task Resume** (script command; empty argument targets the latest blocked task) or **Resume in Terminal** (extension, on any task with a session id) opens your preferred terminal on that exact session; approve the denied action there and the task picks up where it stopped. With cmux configured, that's a new workspace named after the task, and if the cmux app isn't already running, qt starts it and waits up to about 10 seconds for its socket before retrying, so you don't need cmux open in advance. Any fallback away from your configured terminal (cmux unreachable, Ghostty missing, a custom template that fails) opens Terminal.app instead and raises a notification saying so, so a wrong-terminal resume is never silent. `qt resume <id>` does the same from a shell. Tasks stay resumable forever; missing a notification never loses anything.

### Resume links in Slack

Tasks that post to Slack end their messages with a resume line: the plain `qt resume <id>` command plus a `quicktask://resume/<id>` link. Run `qt install-handler` once to make that link clickable: it registers a small macOS URL handler (an applet in your qt data dir, with your qt path and any `QT_DATA` override baked in, plus an extended PATH and `CMUX_QUIET=1` so a cmux resume works even from the handler's minimal shell environment) that opens the task's session in your preferred terminal, with no Dock icon. Both `qt install-handler` and `qt uninstall-handler` sweep every other bundle registered under the same identifier first, so a stale duplicate from an old build can't quietly win the click. `qt uninstall-handler` removes the app and its scheme registration. Slack asks for confirmation on the first click of the scheme. Link ids are validated to lowercase letters, digits, and hyphens before anything reaches a shell.

A hub job slug (`qt-<id>-<timestamp>`, the directory name The Pass gives a qt-originated run) resolves to the original quicktask too, so a resume link built from that slug -- Slack, the menubar widget, or The Pass itself -- still finds its task even though it isn't qt's own id.

**If a resume link opens Terminal.app instead of your terminal, run `qt doctor`.** Every resume launch is logged to `~/.quicktasks/logs/resume.log` (`qt resume-log` prints recent entries) with the terminal it tried, what actually ran, and why any fallback happened, e.g. "cmux CLI not found" or "cmux new-workspace failed (rc 1): ...". `qt doctor`'s "resume handler" section shows why: every LaunchServices bundle currently claiming the `quicktask://` scheme (and which one is flagged as an extra), the interpreter and qt path baked into the installed handler, and what `find_cmux()` resolves to under the bare PATH a clicked link actually runs with. A common specific cause: cmux 0.64+ defaults its socket to `cmuxOnly` control mode, which only accepts connections from processes started *inside* cmux -- a resume click has launchd ancestry and no TTY, so cmux answers "Access denied" and qt falls straight back to Terminal.app rather than retrying. `qt doctor` runs an outside-cmux probe (from a process detached the same way a resume click is) and flags this by name; the fix is cmux Settings → Automation → Socket control → `password`, then `cmux reload-config`.

Notifications use osascript (shows as Script Editor), which displays reliably without setup. terminal-notifier support exists behind `"notifier": "terminal-notifier"` in config, which makes blocked notifications directly clickable, but on modern macOS its notifications are silently dropped until you authorize the app in System Settings → Notifications; only opt in if you've done that and verified it displays.

Note: your global allowlist is inherited by headless runs, and sandbox-safe read-only commands auto-approve. If your allowlist is generous (e.g. `Bash(bash:*)`), conservative mode is less conservative than it sounds. Audit it once before assuming the default tier is tight.

## Config

`qt setup` writes `~/.quicktasks/config.json`: `terminal` (cmux | Ghostty | iTerm | Terminal | custom template with `{script}`), `trusted_dirs`, `permissions` (see above, also set by `qt setup`), `trusted_permissions` (mode inside trusted dirs, default `auto`), `model` (default for all tasks; `qt setup` recommends `sonnet[1m]`, Claude Code 2.1.266+'s 1M-context alias, but leaves it unset unless you pick it), `questions` (the `ASK:` convention, default on — see [Asks](#asks-one-id-one-address-many-runs)), optional `notifier: "osascript"` to force the fallback, and `slack_owner_id` / `slack_allowed_channels` / `slack_allow_public_channels` (see Slack safety, below).

Model resolution per task: `-m` flag > `QT_MODEL` env > config `"model"` > your CLI default. Leaving `model` unset (the default if you skip that step in `qt setup`) always falls through to whatever the `claude` CLI itself defaults to; setup never writes a model choice you didn't make.

`qt setup --defaults [--hub <dir>]` skips every prompt, for scripted installs (e.g. the hub's one-command installer): `permissions` → `acceptEdits`, `model` → `sonnet[1m]`, `terminal` → the same auto-detected choice plain `qt setup` offers as its default. `--hub <dir>` turns the hub feed on for that dir exactly like `qt hub <dir>` (`dir` must contain `serve.py`) and leaves `slack_owner_id` unset, since a configured hub's own `guard.py` governs Slack policy instead; omit `--hub` and the hub feed stays off. Idempotent and scoped: reruns only touch the keys above, so `trusted_dirs`, `notifier`, `trusted_permissions`, and any existing `slack_owner_id` are left exactly as they were.

Env vars, all optional: `QT_DATA` (default `~/.quicktasks`), `QT_TIMEOUT` (seconds, default 1800), `QT_MODEL`, `QT_PERMISSIONS`, `QT_HUB` (see below).

### Hub mode

`qt hub <dir>` points qt at a checkout of The Pass (a separate ledger app; `dir` must contain its `seed.py`); `qt hub off` clears it; `qt hub status` shows the current setting. Unset (the default) is a strict no-op: nothing changes. Set it and every finished task also seeds an item into that ledger (`seed.py`, so a re-run never duplicates) and writes a `jobs/qt-<id>-<timestamp>/job.json` + `output/RESULT.md`, so it shows up in the ledger's Verify queue: done tasks land as `done`, blocked tasks land as `blocked`, and failed/timeout tasks land as `failed`, each with an error explaining why and a `qt resume <id>` hint. `QT_HUB` overrides the config value. This never blocks or fails the task itself; a hub-feed problem is logged to the task's log file at most.

With a hub configured, each task is also an **ask** — see [Asks](#asks-one-id-one-address-many-runs) — with the id, address, verbs, question convention, streaming events, and bell delegation described there: `qt open` opens the ask page, the state machine (`stopped`, `question`, and the rest) maps straight into the hub's ask list, and the hub's bell rings so qt's own banners don't.

### Slack safety

Every headless `claude -p` a quick-fire launches carries a `--settings` file wiring a PreToolUse hook on every `mcp__ld-tools__ld_slack_*` tool call, and every other MCP tool whose name contains "slack" (`mcp__claude_ai_Slack__*`, `mcp__plugin_slack_slack__*`, etc.) -- not a tool allowlist, so a quick-fire keeps its normal freedom, but a deterministic gate on where it can post. This closed an incident where a quick-fire posted to a public channel with no Slack-destination check at all; quick-fires' Slack path is ld-tools only, so any non-ld-tools Slack connector is denied outright unless `slack_allow_public_channels` is set, the same opt-in the ld-tools path itself uses when it can't tell where a write is headed.

- **Hub feed configured** (`qt hub <dir>`, and that checkout has a `guard.py`): quick-fires reuse the hub's own `guard.py` and `pass-config.json` policy, the same one hub-fired jobs already obey. Nothing to configure in qt itself.
- **No hub feed**: quick-fires run under qt's own `qt-guard.py`, reading two `config.json` keys `qt setup` writes:
  - `slack_owner_id`: the owner's Slack member id (Slack profile → More → Copy member ID, starts with `U`). With none set, **every Slack write is denied** -- there's no hardcoded fallback.
  - `slack_allowed_channels`: an array of extra channel/conversation ids a write may target beyond the owner's own DM.
  - `slack_allow_public_channels` (bool, default `false`): opt-in escape hatch that allows any channel, including a write with no channel field to check at all. Off unless you turn it on.

  Read-only Slack tools (search, history, thread lookups, channel/user lookups, etc.) are always allowed; only tools that can change what someone else sees go through the channel check.

A task that asks for a DM ("send me", "dm me", "slack me", ...) is also enforced by the shell, not just the prompt: if the session transcript shows the model never sent a Slack message, qt sends the result to `slack_owner_id` itself (before the hub feed, so the item can't auto-close first) and stamps `dm_fallback` on the task. With a hub configured it sends through the hub's `pass-slack.py`; without one it needs `ld_cli` in `config.json` set to the ld CLI binary (not a bare `ld`, which is the system linker). If that send fails, you get a "DM not sent" notification that resumes the task.

`qt doctor` prints one "Slack guard" line: which guard is active (`hub` or `qt-guard.py`), the owner id in effect (or `DENY-ALL` when none is configured), and whether public-channel posting is on.

The same `--settings` file also carries a `permissions.allow` list of the hub's own read-only `ld-tools`/`fff` tools plus Slack send: a fresh install has no personal allowlist for `mcp__ld-tools__*`, so under headless `acceptEdits` the very first quick-fire that touches one of those MCP tools was denied outright, with no guard involved at all. This list only closes that fresh-install gap; it never narrows `--permission-mode` and it's not an `--allowedTools` change, so a quick-fire otherwise keeps its normal tool freedom -- the guard hook above still decides where a Slack message can go. Separately, the prompt every quick-fire runs under now names the owner's Slack id directly (hub configured: `owner_slack_id` from the hub's `pass-config.json`; otherwise `slack_owner_id` from qt's own config) so "slack me" or "DM the owner" sends straight to that id instead of the model looking the owner up by email first. With no owner id configured anywhere, the prompt says Slack delivery is unavailable and to write the result to the task output instead.

### Testing against another Pass

Three env vars, all optional, let you point a qt install at a different Pass checkout for testing without touching your real one: `QT_HUB=<hub dir>` selects which Pass `qt` itself feeds and reads Slack policy from; `QT_PASS_URL=<url>` is the same override the menu-bar widget reads for its own feed; `QT_DATA=<dir>` relocates `qt`'s entire data dir (tasks, logs, config) away from `~/.quicktasks`. Set all three together to run a fully isolated qt + Pass pair alongside your real one.

## Troubleshooting

Start with `qt doctor`. It's read-only and checks the whole chain: claude CLI, data dir, config, terminal readiness, notifier, PATH, trusted dirs, and (see below) the resume handler.

- **Hard failures** (nonzero exit): the `claude` CLI isn't on PATH, or `~/.quicktasks` isn't writable. Everything else prints as a warning with a one-line remedy next to it.
- **Resume opened Terminal.app instead of my terminal.** Run `qt doctor`; it shows why. Every resume launch is logged to `resume.log` with the specific reason for any fallback (e.g. "cmux CLI not found", "cmux socket not answering after 10 s", "cmux refused an outside process (socket control mode is cmuxOnly)", or a `new-workspace` failure with its exit code and stderr) instead of a generic "unreachable" — `qt doctor`'s "resume handler" section surfaces the last few of those, plus every LaunchServices bundle currently claiming `quicktask://` in case a stale duplicate is the real culprit. qt auto-starts cmux and waits for its socket before falling back, so this should be rare; check the notification qt raised, or run `qt resume-log` for the full history. If the reason names "cmuxOnly"/"access denied", set cmux Settings → Automation → Socket control to `password` and `cmux reload-config` -- `qt doctor` and `qt setup` both detect and flag this by running an outside-cmux probe.
- **Raycast extension isn't showing up.** Re-run `npm run dev` from `raycast-ext/`; it needs to run, even briefly, for Raycast to pick up the local dev extension again.

## Portability notes

- Single-file python3 stdlib script; no jq, no npm required for `qt` itself. terminal-notifier optional. The Raycast extension is a separate, optional piece that needs Node 22+.
- All state under one directory; delete `~/.quicktasks` to reset.
- Terminal launch strategies degrade gracefully: cmux down → qt starts it, waits up to ~10s for the socket, retries, then falls back to Terminal.app; unknown terminal → custom `{script}` template.
- Notifications are the only macOS-specific piece; swap `notify()` for `notify-send` on Linux.
