---
title: Replacing osascript banners with a first-party UNUserNotificationCenter notifier
date: 2026-11-03
category: integration-issues
module: quicktasks menubar app (Notifier.swift, NotifyInbox.swift) + qt/hub notify paths
problem_type: integration_issue
component: tooling
severity: high
related_components:
  - development_workflow
tags: [macos, notifications, swift, terminal-notifier, osascript, file-drop-ipc, launchd]
---

# Replacing osascript banners with a first-party UNUserNotificationCenter notifier

## Problem

macOS banners fired by `osascript -e 'display notification …'` are
attributed to Script Editor: clicking one opens Script Editor, and they
can never carry actions or URLs. Three producer paths (qt notify, hub
local_notify, hub runner._notify) each fell back to it for different
reasons — an opt-in config gate nobody set, a `shutil.which` that fails
under launchd/Raycast/summon's minimal PATH, and a hardcoded osascript
call. See notification-authority-and-slack-read-blocks-2026-10-28.md (hub
docs/solutions) for the incident.

## What worked

**A file-drop inbox as IPC.** Producers write one JSON file (atomic
tmp+rename) into `$QT_DATA/notify-inbox/`; the menubar app watches with a
DispatchSource vnode source *plus* a per-poll sweep (a directory replace
drops vnode events). No ports, no sockets, works from any launchd/Raycast
context, testable via a `--dump-inbox-notice <file>` CLI seam that prints
the mapped notice. Producers probe `pgrep -xq QuicktaskStatus` (1s budget)
and fall back to terminal-notifier-by-absolute-path, osascript last.
Kill-switch env (`QT_NOTIFY_INBOX=0`) so a dev machine's real app doesn't
swallow banners mid-test.

**Rich notices**: UNNotificationCategory per shape (blocked with
Resume/Always-Allow/Open-in-Pass; outcome with Open; plain), payload in
userInfo, banner click deep-links into the app (open panel, highlight +
expand the row) keyed by a taskID.

## Gotchas that only surfaced in review/build

- **Delete-after-deliver, not before**: removing the inbox file before
  the notification hand-off means a crash eats the notice. Deliver, then
  delete on the main thread; accept at-least-once redelivery.
- **Serialize sweeps**: vnode handler (bg queue) + poll sweep (main)
  could interleave and double-decode; funnel every sweep onto one queue.
- **Match UNNotificationDefaultActionIdentifier explicitly** — the
  `default:` branch of the delegate also sees dismissals; don't pop the
  panel on a swipe-away.
- **Swift init-order**: a closure capturing `self` can't run before all
  stored properties are initialized (watcher setup goes last in init).
- **`FileManager.replaceItemAt` fails when the destination doesn't exist
  yet** — first-time writes need a remove+move fallback.
- **Big dictionary-literal JSON payloads blow the compiler's type-check
  budget** ("unable to type-check this expression in reasonable time") —
  hoist any closure-bearing map into a helper function; splitting the
  literal alone wasn't enough.
- **`UNNotificationRequest(identifier:)` doubles as grouping**: a stable
  id (e.g. `inbox-<task>-blocked`) makes repeat notices replace in place
  instead of stacking.
