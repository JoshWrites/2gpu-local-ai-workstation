# llama-server router mode -- validation on HIP, dual-model preset

**Date:** 2026-05-03
**Branch context:** `opencode-gpt-oss-120b`
**Purpose:** Capture the validation run that proved router mode works
on our HIP build with both GLM-4.7-Flash and GPT-OSS-120B as preset
entries, and that model swaps land at the API level the way the docs
claim.

This doc closes the question that motivated it (does router mode
actually work on our stack?), and surfaces a follow-up question
the validation cannot answer (what happens to conversation context
when the underlying model swaps?).

---

## Background

The current 2GPU stack uses two separate systemd units for the
primary slot — `llama-primary.service` (GLM, Vulkan, port 11434) and
`llama-primary-experiment.service` (GPT-OSS-120B, HIP, port 11444).
A `compute_active_units()` function in the launcher detects which is
running and substitutes appropriately. This works but it has costs:

- Two units to maintain, two ports, two binary paths
- Zed picker shows both providers (`llama-primary` and
  `llama-experiment`) as separate entries; the user has to know
  which is currently live
- Mid-session model swap (the workflow the user actually wants) is
  not supported -- requires a manual `systemctl stop X / start Y`
  cycle

The literature (HF model-management blog, Glukhov 2026, llama-swap
docs) suggests the cleaner pattern is **router mode**: one
llama-server process bound to one port, with a preset file declaring
multiple models, swapped on demand via API. The architecture
question was whether router mode actually works on our HIP build,
and whether it preserves the per-model tuning the production unit
embeds.

This validation answers: **yes, both.**

## Test setup

- Binary: `/usr/local/lib/llama.cpp-hip/llama-server` (the existing
  HIP build at `b1-0929436`)
- INI preset at `/tmp/router-test.ini` with two `[section]` entries
  carrying every flag from the production units
- Launched outside systemd via plain shell, port 11434, env vars
  `HIP_VISIBLE_DEVICES=1 LLAMA_SET_ROWS=1`
- Flags: `--models-preset /tmp/router-test.ini --models-max 1
  --no-models-autoload --host 127.0.0.1 --port 11434`

The ini-file syntax is undocumented in the public README at the time
of this writing; reverse-engineered from the binary's behavior. Each
section's keys are llama-server CLI flag names without the leading
`--`. Boolean flags like `flash-attn` and `jinja` accept `on`/`true`.
The router echoes the resolved child-process argv on `/models`, so
verification of the parse is straightforward.

## What router mode actually does

Architecturally:

- The parent llama-server process binds the port and stays up
  forever. It does not load any model itself.
- On `POST /models/load {"model": "X"}`, the parent forks a child
  llama-server process configured from the X preset entry, with the
  full set of CLI flags resolved from the INI.
- The child handles inference; the parent proxies HTTP calls to it.
- `--models-max 1` enforces mutex: requesting load of model B when
  model A is loaded immediately reaps A's child before forking B.
- `/v1/models` and `/models` both return current registry status
  (each model: `unloaded` / `loading` / `loaded` / `error`), with
  the child's full argv listed for the loaded model.

Two things this gives us that the unit-based design does not:

1. **The HTTP layer is asynchronous on load.** `/models/load` returns
   `{"success": true}` immediately and the load runs in the
   background. Status is pollable via `/models`. This is the missing
   primitive we need for a progress popup -- we can show a yad UI
   that polls `/models` until status flips to `loaded`, without
   holding any HTTP request open during the 5-minute load.
2. **The model swap is API-driven, not service-driven.** No systemd
   start/stop dance, no port juggling. The popup script just calls
   `POST /models/load` and waits.

## Results

### Test 1 -- single preset (GPT-OSS-120B only)

Validates that router mode launches at all on HIP, and that our
production OSS config carries forward unchanged.

| Metric | Value | vs unit-based bench |
|---|---:|---:|
| Router launch time | <1 s | n/a |
| OSS load time (cold) | 236 s | comparable (~5 min) |
| OSS gen tok/s | 18.6 | 17.3 (slightly faster) |
| OSS prompt eval (small prompt) | 15.4 tok/s | comparable |
| `--swa-checkpoints 64` active | yes | yes |
| Harmony channels active (reasoning + content) | yes | yes |

**Conclusion:** OSS via router is indistinguishable from OSS via
the dedicated unit. All tuning (`--n-cpu-moe 28`, `-ub 2048`,
`--cache-reuse 256`, `--swa-checkpoints 64`, sampler pinning,
`--alias`) carries through the INI faithfully.

### Test 2 -- two-preset swap (GLM <-> GPT-OSS-120B)

Validates that swap works, that mutex is enforced, and -- the
unanticipated finding -- that GLM benefits from running on the HIP
binary.

| Metric | Value |
|---|---:|
| GLM cold load via HIP | 33 s |
| GLM gen tok/s on HIP | **72.7** |
| GLM gen tok/s on Vulkan (production baseline) | ~30 |
| GLM swap-out time when OSS requested | <1 s |
| OSS swap-in time after GLM | 240 s |
| OSS gen tok/s post-swap | 19.75 |
| GLM swap-back from OSS | 35 s |

**Conclusion:** Swap works. Mutex is enforced (`--models-max 1`
instantly unloaded GLM when OSS was requested). And **GLM is 2.4x
faster on HIP than on Vulkan**, which is independently a strong
argument for switching its production binary regardless of the
router-mode decision.

The asymmetric swap times (~35s back to GLM, ~240s to OSS) reflect
the model-size difference: GLM is 17 GB on disk and lives entirely
on the GPU; OSS is 60 GB total with 46 GB streaming through the HIP
host buffer. The popup will need to show progress for both; OSS-load
is the regime where it actually matters.

### Behavior of `/models` during load

```
[0s]   glm=unloaded oss=loading  vram=18GB  (GLM child reaped)
[240s] glm=unloaded oss=loaded   vram=20GB
```

The router unloads the previous model **before** the new model
starts loading -- even at t=0 in the swap above, GLM was already
gone. This means VRAM is fully released before the new model needs
it. No gap-handling logic needed in our popup script.

## What this enables

**Architecturally** the router-mode design replaces:

```
llama-primary.service  (GLM,  Vulkan, port 11434)
llama-primary-experiment.service  (OSS, HIP, port 11444)
compute_active_units() in opencode-session.sh and 2gpu-launch.sh
WS_PORT_EXPERIMENT in system.env
"llama-experiment" provider in opencode.json template
```

with:

```
llama-primary-router.service  (HIP, port 11434, preset file)
configs/workstation/llama-router.ini  (both models declared)
```

The `compute_active_units` substitution logic disappears entirely.
The opencode template lists both models under one `llama-primary`
provider with the same `api: http://localhost:11434/v1`. Zed's
picker shows both, picking either triggers a request that opencode
forwards. If the requested model isn't loaded, opencode-session.sh
or a model-swap helper runs the load + waits.

The popup-during-swap UX from the user's stated requirement now has
a clean implementation:

```
user picks model in Zed
  -> Zed sends ACP session-update with new {providerID, modelID}
  -> opencode-acp (patched) detects the model id changed
  -> calls /models to check if target is already loaded
  -> if not, fires `model-swap.sh <target>`:
        yad confirm dialog ("From X to Y, ~4 min, OK / Cancel")
        on OK: POST /models/load, then poll /models for status
                show yad progress bar updating from poll results
                close popup when status=loaded
        on cancel: don't load; opencode reverts session model
  -> opencode forwards original request to now-loaded model
```

No `compute_active_units`, no port branching, no separate
`llama-primary-experiment.service`. Same UX the user described,
clean implementation surface.

## What this validation does **not** answer

The validation only tested **process-level** swap mechanics. The
question of what happens to **conversation state** when the
underlying model swaps mid-session is open:

- When GLM is loaded with a 30K-token KV cache from an active Zed
  conversation, and the user picks OSS, the GLM child process is
  killed and OSS spawns. **The KV cache is gone.** When the user's
  next request lands on OSS, what does opencode send?
  - Just the new turn (assuming the prior conversation was the
    model's working state)?
  - The full conversation history reconstructed from opencode's
    session storage, forcing OSS to re-evaluate everything from
    cold?
  - The session resets and the user starts a fresh conversation?

This is the next research question. The answer probably lives in
opencode's session manager (how it stores and replays messages)
rather than in llama.cpp.

## Cleanup

```
pkill -f "llama-server.*models-preset.*router-test"
```

Test INI lives at `/tmp/router-test.ini` -- ephemeral. The
production version belongs at `configs/workstation/llama-router.ini`
once we move forward.

## Sources

- [HF blog: Model Management in llama.cpp (router mode introduction)](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp)
- [Glukhov: llama-server Router Mode (April 2026)](https://medium.com/@rosgluk/llama-server-router-mode-dynamic-model-switching-without-restarts-4e7d6fb19906)
- [llama.cpp tools/server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [llama.cpp Discussion #10431 -- serving multiple models](https://github.com/ggml-org/llama.cpp/discussions/10431)
- [opencode issue #2979 -- keep_alive not propagated; relevant background on opencode's model lifecycle](https://github.com/anomalyco/opencode/issues/2979)
