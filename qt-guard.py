#!/usr/bin/env python3
"""qt-guard: PreToolUse hook for headless quick-fires when no hub feed is
configured (see resolve_slack_guard_cmd() in `qt`).

LD-224 incident: a quick-fire with no Slack-destination check at all
posted to a public channel. qt now always wires *some* Slack guard as a
PreToolUse hook on every mcp__ld-tools__ld_slack_* tool call; this is the
one used when qt isn't pointed at a hub checkout (qt hub <dir>). When a
hub *is* configured, qt uses the hub's own guard.py + pass-config.json
instead, so hub-fired jobs and hub-fed quick-fires obey one policy.

Follow-up gap: a headless run inherits the user's other configured MCP
servers, so a Slack send denied on mcp__ld-tools__ld_slack_send could
just route around this guard through a different Slack-flavored MCP
tool (e.g. mcp__claude_ai_Slack__slack_send_message,
mcp__plugin_slack_slack__slack_send_message). qt's PreToolUse matcher
(SLACK_GUARD_MATCHER in `qt`) is now broad enough to send every one of
those here too. Each is classified by name (is_read_only_tool): a clear
read (search/history/thread/lookups -- a read has no destination to
protect, and denying reads outright was blocking headless runs on pure
lookups) is allowed; writes and anything unrecognized are denied unless
slack_allow_public_channels is set, since only the ld-tools path
understands enough about the destination to check it against
slack_owner_id/slack_allowed_channels. Classification is conservative:
send-like indicators win over read indicators, and a name carrying
neither is treated as a write.

User allowlist (steering): a shared quicktask:// ecosystem affordance
(the "Always allow" button, `qt allow`) writes allow.json --
{"allow": [tool_name, ...]} at $QT_ALLOW_FILE, else $QT_DATA/allow.json.
A tool named there is allowed immediately after tool_name validation,
before any connector routing -- unless its name is send-like
(is_send_like_tool), because writes always keep the LD-224 destination
checks below. A missing or malformed file is an empty list, never an
error.

Denial ledger: every deny() also appends one best-effort JSON line
({"ts", "guard": "qt", "tool_name", "reason"}) to $QT_DENIALS_LOG, else
$QT_DATA/logs/denials.jsonl, so the blocked-runs view can show what
headless runs kept hitting. Never raises, never prints to stdout, never
changes the stderr/exit-2 denial contract.

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
import re
import sys
from datetime import datetime, timezone

QT_DATA = os.path.expanduser(os.environ.get("QT_DATA", "~/.quicktasks"))
CONFIG_PATH = os.path.join(QT_DATA, "config.json")
# Steering/observability side channels (see the header docstring) -- the
# env overrides exist for tests and power users, same as QT_DATA itself.
ALLOWLIST_PATH = os.environ.get("QT_ALLOW_FILE") or os.path.join(QT_DATA, "allow.json")
DENIALS_LOG_PATH = (os.environ.get("QT_DENIALS_LOG")
                    or os.path.join(QT_DATA, "logs", "denials.jsonl"))

SLACK_PREFIX = "mcp__ld-tools__ld_slack_"

# Never mutate anything another person sees -- always allowed, no owner
# id or channel check needed.
READ_TOOLS = {
    "search", "history", "thread", "threads", "channel_info", "channels",
    "mentions", "unreads", "pins", "reactions_get", "files",
    "user_by_email", "usergroups", "users_conversations",
    "channel_members", "expand",
}

# Name classifiers for the security decision on non-ld-tools Slack
# connectors and the allowlist's read-only gate.
#
# 2026-11-03 review rebuild: the first cut matched indicator SUBSTRINGS
# ("read", "channel", "list") and trusted "send-like wins" to cover every
# mutating verb. Both halves were wrong: slack_set_channel_topic,
# slack_blocklist_add and slack_channel_pin all matched a read substring
# while their verbs sat outside the send-like list -- writes sailing
# through the read path with no destination check. Tokens fix the shape:
# verbs and nouns are different tokens, so a broad noun list ("channel",
# "pins") is safe the moment the verb token is checked first. A name
# carrying no known token of either kind is treated as a write: when in
# doubt, deny. Keep in sync with hub/guard.py's copy.
def _name_tokens(tool_name):
    """The tool name after the final "__", lowercased and split on every
    non-alphanumeric boundary into tokens."""
    short = tool_name.rsplit("__", 1)[-1].lower()
    return [t for t in re.split(r"[^a-z0-9]+", short) if t]


# Mutating-verb tokens. Over-inclusive on purpose: a read misread as
# send-like is a block (safe, steerable), a write misread as a read is
# LD-224 again.
SEND_LIKE_TOKENS = frozenset({
    "send", "post", "message", "reply", "upload", "share", "invite",
    "kick", "archive", "unarchive", "join", "leave", "rename", "set",
    "create", "delete", "update", "patch", "schedule", "add", "remove",
    "edit", "publish", "move", "mute", "unmute", "pin", "unpin",
    "bookmark", "mark", "star", "unstar", "close", "open", "approve",
    "decline", "enable", "disable",
})
# Read-noun/verb tokens. None of these appear as the verb of a mutating
# call in any Slack connector we've seen; a mutator carrying one anyway
# is still caught, because its verb token is in SEND_LIKE_TOKENS and
# send-like is checked first.
READ_ONLY_TOKENS = frozenset({
    "read", "search", "list", "get", "lookup", "find", "view", "fetch",
    "describe", "history", "thread", "threads", "channel", "channels",
    "members", "pins", "files", "mentions", "unreads", "usergroups",
    "expand", "user", "users", "profile", "conversations", "reactions",
    "info", "whoami",
})


def is_send_like_tool(tool_name):
    """True when any name token is a mutating verb -- these are never
    allowed by the read-parity path or the user allowlist."""
    return any(t in SEND_LIKE_TOKENS for t in _name_tokens(tool_name))


def is_read_only_tool(tool_name):
    """Conservative read classification: send-like wins first, then a
    read token must be present. Anything unrecognized is NOT a read."""
    tokens = _name_tokens(tool_name)
    if any(t in SEND_LIKE_TOKENS for t in tokens):
        return False
    return any(t in READ_ONLY_TOKENS for t in tokens)


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def load_allowlist():
    """The user-managed allowlist ({"allow": [tool_name, ...]}) written by
    the shared quicktask:// ecosystem's "Always allow" affordances (`qt
    allow`, the button). A missing or malformed file is an empty list,
    never an error."""
    try:
        with open(ALLOWLIST_PATH) as f:
            data = json.load(f)
    except (OSError, ValueError):
        # OSError: gone/unreadable. ValueError covers JSONDecodeError AND
        # UnicodeDecodeError -- a non-UTF-8 file must read as empty, not
        # crash the guard into a non-blocking exit-1 (2026-11-03 review).
        return set()
    entries = data.get("allow") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        return set()
    return {e for e in entries if isinstance(e, str)}


# Set by main() once the payload's tool_name is known, so deny() can name
# the tool in the denial ledger without changing any existing call site.
_CURRENT_TOOL_NAME = None


def _append_denial_ledger(reason, tool_name):
    """Best-effort: one JSON line per denial so the blocked-runs view can
    show what headless runs kept hitting. Never raises, never prints,
    never affects the stderr/exit path it decorates."""
    try:
        parent = os.path.dirname(DENIALS_LOG_PATH)
        if parent:  # a bare filename in QT_DENIALS_LOG means cwd; no makedirs
            os.makedirs(parent, exist_ok=True)
        record = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "guard": "qt",
            "tool_name": tool_name if isinstance(tool_name, str) else None,
            "reason": reason,
        }
        with open(DENIALS_LOG_PATH, "a") as f:
            f.write(json.dumps(record) + "\n")
    except Exception:
        pass


def deny(reason, tool_name=None):
    _append_denial_ledger(reason, tool_name if tool_name is not None else _CURRENT_TOOL_NAME)
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
    """Fail-closed wrapper: under PreToolUse semantics exit 1 is
    NON-blocking (the tool call proceeds), so an unexpected error anywhere
    in the guard must become a deny, never a traceback (2026-11-03 review)."""
    try:
        _main()
    except SystemExit:
        raise
    except Exception as e:
        deny(f"qt-guard: unexpected error ({e!r}); failing closed")


def _main():
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

    global _CURRENT_TOOL_NAME
    _CURRENT_TOOL_NAME = tool_name

    # User allowlist (steering): an exact tool_name listed in allow.json
    # is allowed before any routing -- but only for a positively-classified
    # read-only MCP tool (2026-11-03 review: a send-like veto alone let
    # allow.json whitelist mutating Slack tools whose verbs sat outside the
    # old indicator list, e.g. slack_publish_canvas).
    if (tool_name.startswith("mcp__") and tool_name in load_allowlist()
            and is_read_only_tool(tool_name)):
        allow()
        return

    if not tool_name.startswith(SLACK_PREFIX):
        if tool_name.startswith("mcp__") and "slack" in tool_name.lower():
            # Some other MCP server's Slack connector. Read parity first:
            # a read has no destination to protect, so gating it on the
            # write policy only produced spurious blocks. Send-like names
            # and anything unrecognized fall through to the denial below
            # -- this hook has no way to check their destination the way
            # check_write() does for ld-tools, so they're denied outright
            # unless the config has opted into public posting.
            if is_read_only_tool(tool_name):
                allow()
                return
            if bool(load_config().get("slack_allow_public_channels", False)):
                allow()
                return
            deny(f"qt-guard: {tool_name}: Slack connectors other than ld-tools are off; "
                 "use mcp__ld-tools__ld_slack_send (slack_allow_public_channels=false)")
            return
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
