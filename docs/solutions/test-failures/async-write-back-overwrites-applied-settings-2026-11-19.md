---
title: Flaky menubar authorization-edge tests - an async refresh write-back overwrote just-applied settings
date: 2026-11-19
category: docs/solutions/test-failures
module: menubar StatusController
problem_type: test_failure
component: frontend_stimulus
severity: medium
symptoms:
  - "test_turning_it_off_then_on_requests_exactly_once_more fails ~15% under load with '1 != 2'"
  - "test_two_off_on_edges_add_two_more_requests_not_three fails the same way ('2 != 3')"
  - "Failures surfaced in full-suite runs, passed in isolation and on retry, pre-existing on main"
root_cause: async_timing
resolution_type: code_fix
tags: [flaky, swiftui, settings, race, configgen]
---

# Flaky menubar authorization-edge tests — an async refresh write-back overwrote just-applied settings

## Problem

The widget's notification-authorization tests failed intermittently (~15% under load, both the single off→on edge and the double-edge variants). The symptom: an off→on toggle's "request authorization exactly once more" read as a no-op. Reproduced in a tight binary-level loop (`--dump-outcomes` 6/40 failures) — and the same two failures had been seen and shrugged at in earlier full-suite runs.

## Symptoms

- `authorization_requests: 1 != 2` / `2 != 3` — an edge's request never fired
- Never failed twice the same way in one run; always green in isolation

## What Didn't Work

- Assuming environment (cfprefsd cache, defaults CLI timing) — the loop reproduced on a single process with no concurrent writers
- Testing harder: the flake's ~15% rate meant any "fix" passed by luck for a week

## Solution

The race was in `StatusController`, not the tests:

1. `refresh()` hops to a background queue, re-resolves config (including `Settings.load()` from disk), and writes it back on the main thread: `self?.config = config`.
2. `apply(new)` sets `config` synchronously and *then* calls `refresh()` — so an in-flight refresh (the launch-time one especially) could land its **stale** resolve after the apply, resurrecting the pre-apply settings. The next apply then read `oldNotify = true` from the resurrected config and skipped the edge.

Two-part fix:

```swift
private var configGen = 0                    // bumped by every apply()

func apply(_ new: Settings) {
    configGen += 1                            // in-flight refreshes lose the race
    config = StoreConfig.resolve(settings: new)
    ...
}

func refresh() {
    let settingsNow = config.settings         // main-thread snapshot
    let gen = configGen
    DispatchQueue.global(qos: .utility).async {
        let config = StoreConfig.resolve(settings: settingsNow, probeDiscovery: true)
        DispatchQueue.main.async {
            if let self, self.configGen == gen { self.config = config }   // only if no apply won
            ...
        }
    }
}
```

The background resolve also **pins its settings to the snapshot** — the async hop would otherwise re-read disk and could race the very apply that triggered it.

Verification: the loop that failed 6/40 → 0/40 and 0/30; the class 6× green; the full menubar suite (which had shown these two failures for weeks) clean.

## Why This Works

The generation counter turns "last writer wins" into "the most *authoritative* writer wins": an apply is authoritative by definition, so a refresh that started before it must not write back. The pinned settings remove the second, quieter race where even the winning refresh could read stale values.

## Prevention

- Any async write-back over shared state needs a generation/token check against synchronous writers — and its inputs snapshotted on the dispatching thread
- A flaky test with a stable ~15% rate is a race, not an environment problem: write a tight loop against the seam (`--dump-outcomes`) before theorizing

## Related Issues

- `tests/test_menubar_model.py TestNotificationAuthorization` — the tests that caught it (eventually)
