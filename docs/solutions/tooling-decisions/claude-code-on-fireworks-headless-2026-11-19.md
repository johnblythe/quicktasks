---
title: Routing headless Claude Code runs through Fireworks - env overlay, launchd-safe key, per-run provider crossing
date: 2026-11-19
category: docs/solutions/tooling-decisions
module: qt runner / provider routing
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - Running Claude Code headless (claude -p / stream-json) against Fireworks' Anthropic-compatible endpoint
  - Spawning such runs from a GUI/launchd process where the interactive shell's env does not exist
  - Letting a single run opt back onto the ambient Anthropic login
tags: [fireworks, claude-code, glm, anthropic-compatible, launchd]
---

# Routing headless Claude Code runs through Fireworks — env overlay, launchd-safe key, per-run provider crossing

## Context

Quick-fires (qt's headless one-shot tasks) shell out to the same `claude` CLI an interactive session uses. To run them on Fireworks models (GLM 5.3 default) instead of Anthropic, the CLI must be pointed at Fireworks' Anthropic-compatible endpoint *per run*, including runs spawned by the menu-bar widget — which runs under launchd and never sources zshrc, so the key and any env conventions set up interactively are invisible to it.

## Guidance

The conventions (matching John's zsh `claude-fireworks` function, now encoded in qt's provider layer):

```json
// ~/.quicktasks/config.json — the whole opt-in
{"provider": "fireworks", "model": "glm-5p3"}
```

```python
# The per-run env overlay for the claude subprocess:
env.pop("ANTHROPIC_API_KEY")          # login gate: two credentials = conflict
env.update({
    "ANTHROPIC_BASE_URL": "https://api.fireworks.ai/inference",   # no /v1
    "ANTHROPIC_AUTH_TOKEN": key,       # Bearer; NOT ANTHROPIC_API_KEY (x-api-key)
    "ANTHROPIC_MODEL": "accounts/fireworks/models/glm-5p3",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": ..., "ANTHROPIC_DEFAULT_SONNET_MODEL": ...,
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": ...,   # slots so alias refs resolve
})
```

- **Key resolution order**: `FIREWORKS_API_KEY` env, then the `export FIREWORKS_API_KEY=…` line in `~/.secrets.zsh` — the file fallback is what makes launchd-spawned runs work.
- **Short names expand**: `glm-5p3` → `accounts/fireworks/models/glm-5p3` (bare → models/, `x/y` → `accounts/fireworks/x/y`). The `-m` flag, config, and the menubar model chip all carry short names; only the spawn expands.
- **Deny WebSearch in the per-run `--settings`**: Fireworks rejects Anthropic's server-side web_search outright, so a model that reaches for it fails mid-run; denied up front it works around it.
- **Per-run provider crossing**: a model reference that looks Anthropic (`sonnet[1m]`, `claude-*`, any `[variant]` suffix) skips the overlay entirely — one fire can go back to the ambient login without touching config.

## Why This Matters

Cost and locality: quick-fires on GLM 5.3 rather than billed Anthropic models, with the same CLI, tools, and session semantics. The launchd trap is the part that costs hours if missed — a run works from every terminal and fails only when fired from the menu bar, which looks like a widget bug and is actually a missing env.

One honest number to remember: any Claude Code harness run carries ~150k tokens of system prompt, so a trivial ask on GLM 5.3 still costs ~$0.20 — the floor is the harness, not the reply.

## When to Apply

- Any headless Claude Code against a third-party Anthropic-compatible endpoint (same pattern for BigModel, etc. — only base URL and key name change)
- Any tool that spawns processes from both a shell and a GUI agent: assume the two environments differ and give the tool its own key resolution

## Examples

```bash
qt "summarize the incident"                       # glm-5p3 via Fireworks (config default)
qt -m glm-5p3-flash "quick take"                  # one fire on the flash model
qt -m sonnet[1m] "use anthropic for this one"     # one fire on the ambient login
```

## Related

- qt provider layer: `provider_fireworks / fireworks_env / claude_spawn_env / claude_model_arg`
- `tests/test_fireworks_routing.py` — argv+env pinned end-to-end with a fake claude that logs both
