# Changelog

## Unreleased

### Added
- Slack resume footer: tasks are told their own id and instructed to end any Slack message they post with `qt resume <id>` plus a `quicktask://resume/<id>` link.
- `qt install-handler`: registers a macOS `quicktask://` URL handler (applet in `~/.quicktasks/`) so resume links in Slack open the session in the preferred terminal. Link ids are validated to letters, digits, and hyphens before any shell call.
- `qt doctor` now reports whether the resume link handler is installed.

## 2026-08-28

### Added
- Initial public release: `qt` CLI, Raycast script commands, interactive Raycast extension (Quick Tasks ledger + New Quick Task), `qt setup` onboarding, `qt doctor` health check, preferred-terminal resume with cmux auto-start.
