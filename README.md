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

Requires: `claude` CLI, python3, macOS. The Raycast extension additionally needs Node 22+.

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
| `qt resume <id>` | reopen a task as an interactive session |
| `qt setup` | pick terminal, trusted dirs, permission mode |
| `qt doctor` | read-only environment health check |
| `qt install-handler` / `qt uninstall-handler` | register or remove `quicktask://` links (clickable Slack resume) |
| `qt trust [dir]` / `qt untrust <dir>` | manage trusted dirs |
| `qt hub <dir>` / `qt hub off` / `qt hub status` | feed finished tasks into a Pass ledger, or check |

## How it works

`qt` detaches a `claude -p` run. By default it runs in a fixed workspace (`~/.quicktasks/workspace/`), so your global CLAUDE.md, tools, and memory apply no matter where you fired it from. The workspace CLAUDE.md tells the agent it's unattended: never ask questions, lead with the outcome, don't expand scope. Each task is one JSON file in `~/.quicktasks/tasks/`; raw transcripts in `~/.quicktasks/logs/`. The invocation directory is passed as context so "this repo" works from a terminal.

## Permissions: trusted dirs and the blocked flow

Two tiers, both explicit:

- **Trusted dirs** (`qt trust ~/code/writing-den` or via `qt setup`): tasks fired in a trusted dir run in that dir itself, under `auto` permissions (see below). Set config `"trusted_permissions": "bypassPermissions"` if you want trusted dirs to skip approval entirely. Firing `qt` from inside a trusted dir runs the task there automatically; from anywhere else, target one with `--in`. The list starts empty; every entry is your call.
- **Everywhere else**: permission mode resolves `QT_PERMISSIONS` env > config `"permissions"` > `acceptEdits`, plus whatever your global `~/.claude/settings.json` allowlist already permits. Headless runs can't prompt, so anything outside that is auto-denied.

`auto` mode is the useful middle ground, and the default for trusted dirs: Claude Code's classifier (a Sonnet 5 model, independent of your session model) approves safe tool calls and denies risky ones, so far fewer tasks come back blocked than under `acceptEdits`. Setting `"permissions": "auto"` applies the same everywhere else. Caveat: auto mode requires a session model that supports it (Sonnet 4.6+/Opus 4.6+/Fable 5). Unsupported models like Haiku silently downgrade to Manual, which in headless means everything non-allowlisted is denied; don't pair `-m haiku` with auto and expect it to work.

A denied run is marked **blocked** (`⊘` in `qt list`), records the exact denied tool call, and raises a notification naming what was denied. Resume it without touching a terminal: Raycast → **Quick Task Resume** (script command; empty argument targets the latest blocked task) or **Resume in Terminal** (extension, on any task with a session id) opens your preferred terminal on that exact session; approve the denied action there and the task picks up where it stopped. With cmux configured, that's a new workspace named after the task, and if the cmux app isn't already running, qt starts it and waits up to about 10 seconds for its socket before retrying, so you don't need cmux open in advance. Any fallback away from your configured terminal (cmux unreachable, Ghostty missing, a custom template that fails) opens Terminal.app instead and raises a notification saying so, so a wrong-terminal resume is never silent. `qt resume <id>` does the same from a shell. Tasks stay resumable forever; missing a notification never loses anything.

### Resume links in Slack

Tasks that post to Slack end their messages with a resume line: the plain `qt resume <id>` command plus a `quicktask://resume/<id>` link. Run `qt install-handler` once to make that link clickable: it registers a small macOS URL handler (an applet in your qt data dir, with your qt path and any `QT_DATA` override baked in) that opens the task's session in your preferred terminal, with no Dock icon. `qt uninstall-handler` removes the app and its scheme registration. Slack asks for confirmation on the first click of the scheme. Link ids are validated to lowercase letters, digits, and hyphens before anything reaches a shell.

Notifications use osascript (shows as Script Editor), which displays reliably without setup. terminal-notifier support exists behind `"notifier": "terminal-notifier"` in config, which makes blocked notifications directly clickable, but on modern macOS its notifications are silently dropped until you authorize the app in System Settings → Notifications; only opt in if you've done that and verified it displays.

Note: your global allowlist is inherited by headless runs, and sandbox-safe read-only commands auto-approve. If your allowlist is generous (e.g. `Bash(bash:*)`), conservative mode is less conservative than it sounds. Audit it once before assuming the default tier is tight.

## Config

`qt setup` writes `~/.quicktasks/config.json`: `terminal` (cmux | Ghostty | iTerm | Terminal | custom template with `{script}`), `trusted_dirs`, `permissions` (see above, also set by `qt setup`), `trusted_permissions` (mode inside trusted dirs, default `auto`), `model` (default for all tasks), optional `notifier: "osascript"` to force the fallback.

Model resolution per task: `-m` flag > `QT_MODEL` env > config `"model"` > your CLI default.

Env vars, all optional: `QT_DATA` (default `~/.quicktasks`), `QT_TIMEOUT` (seconds, default 1800), `QT_MODEL`, `QT_PERMISSIONS`, `QT_HUB` (see below).

### Hub mode

`qt hub <dir>` points qt at a checkout of The Pass (a separate ledger app; `dir` must contain its `seed.py`); `qt hub off` clears it; `qt hub status` shows the current setting. Unset (the default) is a strict no-op: nothing changes. Set it and every finished task also seeds an item into that ledger (`seed.py`, so a re-run never duplicates) and writes a `jobs/qt-<id>-<timestamp>/job.json` + `output/RESULT.md`, so it shows up in the ledger's Verify queue: done tasks land as `done`, failed/timeout/blocked tasks land as `failed` with an error explaining why and a `qt resume <id>` hint. `QT_HUB` overrides the config value. This never blocks or fails the task itself; a hub-feed problem is logged to the task's log file at most.

## Troubleshooting

Start with `qt doctor`. It's read-only and checks the whole chain: claude CLI, data dir, config, terminal readiness, notifier, PATH, trusted dirs.

- **Hard failures** (nonzero exit): the `claude` CLI isn't on PATH, or `~/.quicktasks` isn't writable. Everything else prints as a warning with a one-line remedy next to it.
- **Resume opened Terminal.app instead of my terminal.** Your configured terminal was unreachable at that moment, most often cmux not running yet. qt auto-starts cmux and waits for its socket before falling back, so this should be rare; check the notification qt raised (it names what happened) and run `qt doctor` to confirm the terminal is ready.
- **Raycast extension isn't showing up.** Re-run `npm run dev` from `raycast-ext/`; it needs to run, even briefly, for Raycast to pick up the local dev extension again.

## Portability notes

- Single-file python3 stdlib script; no jq, no npm required for `qt` itself. terminal-notifier optional. The Raycast extension is a separate, optional piece that needs Node 22+.
- All state under one directory; delete `~/.quicktasks` to reset.
- Terminal launch strategies degrade gracefully: cmux down → qt starts it, waits up to ~10s for the socket, retries, then falls back to Terminal.app; unknown terminal → custom `{script}` template.
- Notifications are the only macOS-specific piece; swap `notify()` for `notify-send` on Linux.
