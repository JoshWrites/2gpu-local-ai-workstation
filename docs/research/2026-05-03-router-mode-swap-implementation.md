# Router-mode model-swap implementation -- what shipped and what didn't

**Date:** 2026-05-03
**Branch:** `router-mode-swap`
**Status:** working in production with one known limitation
**Audience:** future-us when we revisit the swap UX, and anyone porting
this to a different agent stack.

---

## What ships

A swap-on-demand primary model with a yad confirm-then-load popup. The
chain:

```
User picks model in Zed footer dropdown
  -> Zed updates its local picker state (no RPC to opencode)
  -> User types and sends a message
  -> Zed sends POST /session/.../message with the new model field
  -> opencode-acp's prompt loop calls our patch's check
  -> Patch sees status=unloaded on the local router
  -> Patch forks scripts/model-swap.sh <target>
  -> Script shows yad confirm dialog (--center --on-top --sticky)
  -> System notify-send banner fires alongside the popup
  -> User clicks Swap (or Cancel)
  -> On Swap: yad pulsate progress while polling /models for `loaded`
  -> Script exits 0 -> opencode-acp resumes the prompt loop
  -> Message goes through normally on the now-loaded model
```

Six commits on the branch:

1. `e9ecba7` -- router-mode primary unit replaces the prior two-unit
   design, single port, both models declared in
   `configs/workstation/llama-router.ini`.
2. `f1be489` -- pin `agent.compaction.model` to gpt-oss-120b in the
   opencode template (largest-context model in the pool, used
   automatically when a session needs compaction).
3. `dcf023a` -- `scripts/model-swap.sh`. Reads
   `configs/workstation/primary-pool.json` for per-model metadata,
   queries the router's `/models`, predicts memory headroom, shows
   yad popup with depth-aware time estimate, polls until `loaded`.
4. `a50d525` -- `our-patch-router-swap.diff`. Adds the on-message
   check in `prompt.ts:1330` that forks the swap script when the
   target model isn't loaded.
5. `7dca188` -- popup foreground fix (`--center --on-top --sticky`
   on every yad call, plus `notify-send -u critical` at popup start
   and on success/failure). Patch v2 also tries to hook
   `unstable_setSessionModel` for picker-change-time fire; this
   branch ended up dead code (see "what didn't" below).
6. `5503a6d` -- pin `agent.title.model` to llama-secondary
   (qwen3-4b-instruct-2507). Without this, the title-generator agent
   inherits the compaction-model pin (gpt-oss-120b) and races with
   the swap popup on every new session.

## What didn't work, and why

### Picker-change-time popup fire

**Goal that didn't ship:** When the user changes the model in Zed's
footer picker, fire the popup immediately -- before any message is
sent -- so the user sees feedback the moment they decide to switch.

**What I tried:** Patch `acp/agent.ts:unstable_setSessionModel` to
detect router-mode targets and spawn `model-swap.sh` detached.

**Why it doesn't fire:** Zed's model picker is a client-side widget.
**Changing the picker doesn't send any ACP RPC to opencode-acp at
all.** The model selection is bundled into the *next* `POST
/session/.../message` payload. Confirmed by enumerating every RPC
opencode-acp received during a picker-change session -- only `GET
/config/providers` (config polling) and `GET /session/.../message`
(state polling), no setter RPC.

`unstable_setSessionModel` exists in opencode's ACP agent surface
but Zed's current dropdown UI doesn't call it. It would be reachable
from a different ACP client that does.

**Resolution:** The hook is left in our-patch-router-swap.diff as
dead code. Removing it requires another rebuild + binary install
for no functional gain. If we ever swap clients or Zed adds a
setter RPC for the picker, the patch is already in place and will
fire automatically.

**The user-facing consequence:** the popup appears at message-send
time, not at picker-change time. There is one extra "step" where
the user has typed but the popup hasn't appeared yet. In practice
this is fine -- the workflow is "pick model, type question, hit
send, see popup, confirm, answer arrives." The popup at
message-send time is the natural feedback moment.

### Pre-swap compaction orchestration

**Stub-only**, with comments in `model-swap.sh:run_compaction_via_opencode`
explaining why. The honest reason: with `--models-max 1`, we cannot
have OSS loaded for compaction WHILE GLM is loaded for inference.
A future router with `--models-max 2` and explicit compaction-vs-inference
selection would let us orchestrate this; today, opencode's
`agent.compaction.model = gpt-oss-120b` pin handles the post-swap
case where compaction would otherwise route to the wrong model.

### Remote-user popup

The yad popup runs on the workstation's local display. SSH'd-in
remote users won't see it. Documented as deferred in commit message;
revisit when we have a clearer picture of remote workflow.

## Critical operational facts (worth memorizing)

1. **Router mode requires `OPENCODE_MODEL_SWAP_SCRIPT` env var.** Set
   in Zed's isolated profile `agent_servers.opencode.command.env`.
   Without it, picking a not-loaded model in Zed silently 400s with
   no feedback.

2. **Title agent must be pinned to llama-secondary.** Otherwise it
   inherits the compaction-agent pin (gpt-oss-120b) and races with
   swap-popup logic on every new session. The pin lives in
   `configs/opencode/opencode.json.template` under `agent.title.model`.

3. **The compaction agent should always be the largest-context model
   in the pool.** Today that's gpt-oss-120b. If we add a model with
   a larger window, update `agent.compaction.model` accordingly.
   model-swap.sh's pool registry lists `context_tokens` for each
   model; pick the max.

4. **Router unit + INI preset are the source of truth for tuning.**
   `configs/workstation/llama-router.ini` carries every per-model
   flag. Adding a model means: (a) section in the INI, (b) entry in
   `configs/workstation/primary-pool.json`, (c) provider model
   declaration in `configs/opencode/opencode.json.template`, (d)
   recompute compaction-agent assignment if the new model has the
   largest context.

5. **Picker change does not trigger anything until the next message.**
   This is a Zed limitation, not an opencode bug. UX-wise, the
   popup appears on send, not on pick. Don't try to fix this by
   patching opencode again -- the ACP surface doesn't expose a
   setter RPC that Zed actually calls.

6. **Old units (`llama-primary.service`, `llama-primary-experiment.
   service`) are masked, not deleted.** Files removed from
   `/etc/systemd/system/` then `systemctl mask`-ed. If router mode
   ever needs to be rolled back: `unmask`, copy the unit files back
   from `systemd/` in the repo, `daemon-reload`, start.

## Files touched on this branch

```
configs/workstation/llama-router.ini             (new)
configs/workstation/primary-pool.json            (new)
configs/workstation/system.env.example           (-WS_PORT_EXPERIMENT)
systemd/llama-primary-router.service             (new)
systemd/llama-shutdown                           (units list updated)
scripts/model-swap.sh                            (new)
scripts/opencode-session.sh                      (-compute_active_units)
scripts/2gpu-launch.sh                           (-compute_active_units)
configs/opencode/opencode.json.template          (collapsed providers,
                                                  added agent.compaction
                                                  and agent.title pins)
opencode-zed-patches/our-patch-router-swap.diff  (new, 5th in chain)
opencode-zed-patches/README.md                   (updated)
opencode-zed-patches/install-and-wire.md         (updated)
```

Net diff vs `opencode-gpt-oss-120b` (the parent branch): about +700
lines, mostly the new files. The old launcher complexity (compute
which units to start, two-unit substitution logic) shrank by ~50
lines.

## Sources

- [llama.cpp Discussion #15396 -- official gpt-oss running guide](https://github.com/ggml-org/llama.cpp/discussions/15396)
- [HF blog: Model Management in llama.cpp (router mode)](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp)
- [Glukhov: llama-server router mode walkthrough (April 2026)](https://medium.com/@rosgluk/llama-server-router-mode-dynamic-model-switching-without-restarts-4e7d6fb19906)
- [opencode session-on-model-change research](2026-05-03-opencode-session-on-model-change.md)
- [opencode router-mode-validation research](2026-05-03-router-mode-validation.md)
