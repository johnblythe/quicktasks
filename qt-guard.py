#!/usr/bin/env python3
"""qt-guard: PreToolUse hook for headless quick-fires when no hub feed is
configured (see resolve_slack_guard_cmd() in `qt`).

LD-224 incident: a quick-fire with no Slack-destination check at all
posted to a public channel. qt now always wires *some* Slack guard as a
PreToolUse hook on every mcp__ld-tools__ld_slack_* tool call; this is the
one used when qt isn't pointed at a hub checkout (qt hub <dir>). When a
hub *is* configured, qt uses the hub's own guard.py + pass-config.json
instead, so hub-fired jobs and hub-fed quick-fires obey one policy.

Policy, read from QT_DATA/config.json (default ~/.quicktasks/config.json,
the same file `qt setup`/`qt doctor` use):
- slack_owner_id: the owner's Slack member id (starts with U). With no
  owner id configured, every Slack write is denied -- there is no
  hardcoded fallback id, so a fresh install fails closed instead of
  guessing whose DM is safe.
- slack_allowed_channels: list of additional channel/conversation ids a
  write may target beyond the owner's own id.
- slack_allow_public_channels (bool, default false): when true, any
  channel is allowed, including one with no channel field to check at
  all. Opt-in only; never the default.

Read-only Slack tools (search, history, threads, channel/user lookups,
etc.) are always allowed -- this hook only gates tools that can change
what other people see.

Contract: JSON on stdin, at least {"tool_name": str, "tool_input": dict}.
Allow: exit 0, no output. Deny: one-line, actionable reason on stderr
naming the config key to fix, exit 2. Anything this hook cannot fully
account for is denied.

QT_DATA env override matches `qt` itself, so tests can point this at a
throwaway config without touching a real install.
"""
import json
import os
import sys

QT_DATA = os.path.expanduser(os.environ.get("QT_DATA", "~/.quicktasks"))
CONFIG_PATH = os.path.join(QT_DATA, "config.json")

SLACK_PREFIX = "mcp__ld-tools__ld_slack_"

# Never mutate anything another person sees -- always allowed, no owner
# id or channel check needed.
READ_TOOLS = {
    "search", "history", "thread", "threads", "channel_info", "channels",
    "mentions", "unreads", "pins", "reactions_get", "files",
    "user_by_email", "usergroups", "users_conversations",
    "channel_members", "expand",
}


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def deny(reason):
    sys.stderr.write(reason + "\n")
    sys.exit(2)


def allow():
    sys.exit(0)


def _str_field(tool_input, *names):
    for name in names:
        v = tool_input.get(name)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None


def check_write(tool_name, tool_input, cfg):
    owner = cfg.get("slack_owner_id")
    if not (isinstance(owner, str) and owner.strip()):
        deny(f"qt-guard: {tool_name}: no slack_owner_id configured, denying every "
             "Slack write; run `qt setup` to set slack_owner_id, or set "
             "slack_allow_public_channels: true in ~/.quicktasks/config.json to "
             "allow posting anywhere")
        return
    owner = owner.strip()

    allow_public = bool(cfg.get("slack_allow_public_channels", False))
    allowed = {
        c.strip() for c in (cfg.get("slack_allowed_channels") or [])
        if isinstance(c, str) and c.strip()
    }

    if not isinstance(tool_input, dict):
        deny(f"qt-guard: {tool_name}: tool_input is not an object, denying")
        return

    channel = _str_field(tool_input, "channel", "channel_id")
    if channel is None:
        if allow_public:
            allow()
            return
        deny(f"qt-guard: {tool_name}: no channel/channel_id to check, denying; "
             "set slack_allow_public_channels: true in ~/.quicktasks/config.json "
             "to allow this")
        return

    if channel == owner or channel in allowed or allow_public:
        allow()
        return
    deny(f"qt-guard: {tool_name}: channel {channel!r} is not the owner DM ({owner}) "
         "or in slack_allowed_channels, denying; add it to slack_allowed_channels or "
         "set slack_allow_public_channels: true in ~/.quicktasks/config.json")


def main():
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, UnicodeDecodeError):
        deny("qt-guard: could not parse stdin as JSON, denying")
        return
    if not isinstance(payload, dict):
        deny("qt-guard: stdin JSON is not an object, denying")
        return

    tool_name = payload.get("tool_name")
    if not isinstance(tool_name, str):
        deny("qt-guard: tool_name missing or not a string, denying")
        return

    if not tool_name.startswith(SLACK_PREFIX):
        # The PreToolUse matcher only ever sends Slack tools here, but stay
        # honest about scope if something else ever reaches this hook.
        allow()
        return

    short = tool_name[len(SLACK_PREFIX):]
    if short in READ_TOOLS:
        allow()
        return

    check_write(tool_name, payload.get("tool_input"), load_config())


if __name__ == "__main__":
    main()
