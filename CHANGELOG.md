# Changelog

## Unreleased

### Fixed
- Task ids now carry the year (`yymmdd-hhmmss-slug`) and get a numeric suffix on same-second collisions, so a same-second queue can no longer overwrite an existing task and filename order survives New Year.

### Added
- Slack resume footer: tasks are told their own id and instructed to end any Slack message they post with `qt resume <id>` plus a `quicktask://resume/<id>` link.
- `qt install-handler` / `qt uninstall-handler`: register or remove a macOS `quicktask://` URL handler (applet in the qt data dir, qt path and `QT_DATA` baked in, no Dock icon) so resume links in Slack open the session in the preferred terminal. Link ids are validated to lowercase letters, digits, and hyphens before any shell call; install reports codesign and LaunchServices registration status honestly and stages rebuilds so a failure cannot destroy a working handler.
- `qt doctor` verifies the handler bundle, its scheme, and its signature.
- Hub mode, stage 1: `qt hub <dir>` (or `QT_HUB`) points qt at a checkout of The Pass; once set, every finished task also seeds an item into its ledger and writes a `jobs/qt-<id>-<timestamp>/job.json` + `output/RESULT.md`, so it surfaces in the Verify queue (done tasks land done, blocked tasks land blocked, failed/timeout tasks land failed, each with an error and a `qt resume <id>` hint). Off by default and a strict no-op until configured; the feed itself can never fail a task, only log to it. `qt hub off` / `qt hub status` clear or inspect it, and `qt doctor` reports whether it's configured and reachable.

### Fixed
- Bare `qt resume` / `qt log` / `qt untrust` now print usage instead of falling through and queueing a paid task with that word as the prompt.
- `qt resume` reports a clean error when the claude CLI is missing; `qt list <junk>` no longer tracebacks.
- Exact task ids always win id matching, so a task's own published resume link cannot be ambiguous.

## 2026-08-28

### Added
- Initial public release: `qt` CLI, Raycast script commands, interactive Raycast extension (Quick Tasks ledger + New Quick Task), `qt setup` onboarding, `qt doctor` health check, preferred-terminal resume with cmux auto-start.
