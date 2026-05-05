# Fix 9 - launcher-time model discovery

Branch: `mnemory` (the active branch carrying today's pool-expansion
work). Lands as a launcher-script change in
`scripts/opencode-session.sh`, not as an opencode source patch.
No rebuild required.

## What this fixes

When opencode launches, it reads the rendered `~/.config/opencode/
opencode.json` and adopts the top-level `"model"` field as the
session's primary. The template default is
`llama-primary/glm-4.7-flash`. **The router-mode primary may be
loaded with a different model already** — left over from a prior
session, a manual swap, or an automated test run. Until fix-9,
opencode and the router silently disagreed:

- **opencode**: "I'll send chat to glm-4.7-flash" (hardcoded default)
- **llama-primary-router**: "I have qwen3-next-80b-thinking loaded;
  glm is unloaded; you'll get a 400 if you ask for it"

The user typed `/models` (bare, list mode) early in the session,
saw the registry, then typed a real prompt. opencode dispatched the
prompt to `glm-4.7-flash`, the router returned **HTTP 400 "model is
not loaded"**, and the chat went silent — no error rendered to the
user, no recovery path.

## Why mid-session swaps weren't enough

The user's expectation is simple: *I open Zed because I want to
use it. The model that's loaded right now is the model I want to
use.* Forcing every session to start with a swap (or even an
implicit "swap to default" reload) is friction the prior gpt-oss-
120b + glm-4.7-flash design accidentally avoided — because glm was
both the default *and* the easiest model to reload (35s cold
start), most sessions started with glm already loaded.

With qwen3-next-80b-thinking now in the pool as the frontier
reasoning model, that accidental alignment broke. The model that's
loaded between sessions might be qwen, and there's no good UX in
"please re-pick the model you already wanted" before every prompt.

## What changed

`scripts/opencode-session.sh` gains a discovery step **after** the
endpoint readiness check and **before** the `exec opencode` call:

1. Query `http://${WS_PORT_PRIMARY}/models` for the currently-loaded
   model on the router.
2. Cross-check against `configs/workstation/primary-pool.json` —
   only adopt a model if it's in the registry. Out-of-registry
   models are left alone (logged as a warning) and the launcher
   falls through to step 4.
3. If a registered model is already loaded → patch the rendered
   `opencode.json` so its top-level `"model"` field reads
   `llama-primary/<id>`. opencode then opens with that model as
   its session primary, matching router state.
4. If no registered model is loaded → POST `/models/load` for
   `glm-4.7-flash` (fastest cold start at 35s), poll up to 90s for
   it to come up, then patch the rendered config to point at glm.
   On a fresh boot the user sees a brief notification ("loading
   glm-4.7-flash, ~35s") so the launcher pause is explained.
5. If `/models/load` fails (router unreachable, OOM, etc.), log
   loudly and fall through with the template default unchanged.
   opencode launches anyway; the user sees the failure once they
   try to chat. Better than refusing to launch entirely.

## What this does NOT fix

- **Mid-session swaps via `/models <id>`** — the v3 patch's
  permission-card flow handles those correctly when actually used.
- **Picker dispatch** (fix-8 candidate) — picker picks may not
  dispatch the synthetic `/models <id>` reliably. User has been
  instructed to use the chat command instead.
- **The 400 errors during a `/models <id>` swap** — those have
  always worked through the model-swap.sh permission card flow.

## How to verify after deploy

1. Stop llama-primary-router. Start it. Do not load anything.
   Launch zed-via-2gpu. Expected: glm-4.7-flash starts loading,
   "all endpoints up" line, brief 35s pause, opencode opens with
   glm as the primary.
2. Stop llama-primary-router. Start it. POST a load for
   `qwen3-next-80b-thinking` and wait for it to register. Launch
   zed-via-2gpu. Expected: opencode opens with
   qwen3-next-80b-thinking as the primary; the discovery step
   logs "adopted: qwen3-next-80b-thinking (loaded)".
3. With qwen3-coder-30b loaded, launch zed-via-2gpu. Type a real
   prompt. Expected: prompt goes to qwen3-coder-30b and responds
   without a 400.

## Anny's path

`scripts/opencode-session.sh` is local-only. anny's path uses the
remote-session script which has its own launcher chain. Fix-9 does
NOT touch anny's launcher. Her LAN-side model-discovery would need
a follow-up if it becomes a problem; she has been informed that
the picker doesn't work and has been told to use the typed `/models
<id>` form. Her experience is unchanged by this fix.

## Stale references this fix surfaces

- `configs/opencode/opencode.json.template` line 55:
  `"model": "llama-primary/gpt-oss-120b"` for the compaction agent.
  gpt-oss-120b was dropped from the primary pool earlier 2026-05-05
  (research/2026-05-03-from-one-model-to-an-agentic-stack.md
  Phase 11). The compaction agent should be qwen3-next-80b-thinking
  (highest context_tokens at 96K). Updated alongside fix-9.
