# llama services reference

Per-role decisions for the four llama-server units that make up this
stack. What runs where, why, and what changes if you want to swap a
model out.

## The problem

Local agentic coding wants more than one model. It wants a chat model
that thinks (the primary), a fast small model that summarizes
retrieved content (the distiller's worker), an embedding model for
semantic retrieval, and an edit-prediction model for the editor.
Running all four at once on a single GPU forces eviction every time
the active workload changes, which breaks any retrieval or
edit-prediction step that happens mid-turn. Running them serially
behind a swap orchestrator adds load latency to every chained tool
call.

A two-GPU box should not have this problem. Three of the four roles
are small enough to fit on a secondary card, and the asymmetric
24 GB + 8 GB pair I have is a good test of whether the architecture
holds up: can the small card host three concurrent llama-server
processes without VRAM contention or driver pathologies?

## What solving this gets you

If your hardware fits the same envelope (24 GB primary + 8 GB
secondary, both AMD, both with working Vulkan), you get:

- Chat model resident on the big card with no eviction pressure from
  retrieval or edit prediction.
- Three concurrent sidecars on the small card, each loaded once and
  staying loaded across an entire work session.
- All four endpoints reachable as plain `http://127.0.0.1:PORT/v1/...`
  -- standard OpenAI-compatible API. Any client that speaks that API
  works (opencode, Zed edit-prediction, curl).
- No swap orchestrator. No model load latency mid-turn. No question
  about whether the right model is currently resident.

The total VRAM on the secondary card runs at ~8.12 GB out of 8.57 GB
under sustained load -- 95% utilized, validated for two hours
continuous on 2026-04-29 with zero failures, zero VRAM drift, zero
GPU-class dmesg events. The envelope is tight but it holds.

## How I solved it

Four llama-server systemd units, one per role, each pinned to its
GPU via Vulkan device index, each independently restartable.

### The four roles

| Service | Role | GPU | Port | Default model | Context |
|---|---|---|---|---|---|
| `llama-primary` | Chat | 7900 XTX (Vulkan0) | 11434 | GLM-4.7-Flash UD-Q4_K_XL | 64K |
| `llama-secondary` | Summarize | 5700 XT (Vulkan1) | 11435 | Qwen3-4B-Instruct-2507 Q4_K_M | 32K |
| `llama-embed` | Embed | 5700 XT (Vulkan1) | 11437 | multilingual-e5-large Q8_0 | 512 |
| `llama-coder` | Edit prediction | 5700 XT (Vulkan1) | 11438 | Qwen2.5-Coder-3B-Instruct Q4_K_M | 4K |

The role names are descriptive, not prescriptive. Each service
serves an OpenAI-compatible HTTP API; the role name is what the
launcher and the regression script use to refer to it, but any
client can hit any endpoint.

Port 11436 is reserved for `llama-librarian` (a future role) and
intentionally unused today; see `WS_PORT_LIBRARIAN` in
`configs/workstation/system.env.example` for the placeholder.

### Why these models

**Primary -- GLM-4.7-Flash.** The chat model is the agent's
interactive surface. It needs to be smart enough to plan, fast
enough to feel responsive, and small enough to leave headroom for
its own KV cache at 64K context. GLM-4.7-Flash at Q4_K_XL fits in
~10 GB of weights and runs at ~50-70 tok/s on the 7900 XTX with
Vulkan, leaving ~14 GB for the 64K KV cache. This is the model the
README's "What this gets you" promises by default; swap any other
16-22 GB Q4 model into the same slot if you have a different
preference. See `WS_PRIMARY_MODELS_AVAILABLE` in `system.env` for
the slot's catalog.

**Secondary -- Qwen3-4B-Instruct-2507.** The summarizer's job is to
distill retrieved web pages and document chunks down to a 1-5 KB
answer. Qwen3-4B is small enough to fit on the secondary card
alongside two other services (~2 GB at Q4_K_M), supports tool
calling, has a long context (32K) for cases where the input is
genuinely large, and turns prose into structured summaries reliably.
Aya-Expanse-8B is the documented alternative for non-English
sources -- bigger, slower, but bilingual.

**Embed -- multilingual-e5-large.** Retrieval has to find content
across languages. The umbrella's user works with Hebrew documents
sometimes; an English-only embedder makes those invisible.
multilingual-e5-large covers 90+ languages at 1024 dimensions, and
its Q8_0 quant (~0.6 GB) is small enough that the quality cost of
quantizing isn't worth thinking about. The earlier version of this
slot ran `mxbai-embed-large` (English-only, slightly stronger on
English-only retrieval); the migration to multilingual-e5-large in
April 2026 was an honest trade -- a small English-quality regression
in exchange for actual multilingual coverage. See
`docs/research/2026-04-25-...` for the comparison work.

**Coder -- Qwen2.5-Coder-3B-Instruct.** Editor edit-prediction wants
sub-second latency on every keystroke pause. The 3B model at Q4_K_M
loads fast (~1.5 s cold), runs at ~120 tok/s on the
`/v1/completions` endpoint (which Zed targets), and produces good
enough next-edit predictions for normal coding work. Qwen2.5-Coder-7B
would be quality-equivalent to Zed's hosted Zeta but does not fit
co-resident with the other two sidecars; it would force a Shape B
architecture (sole-resident on the secondary card with eviction-driven
embed and summarize). See `Library/docs/edit-prediction-on-secondary-research.md`
for the experiment series (E1/E2/E3) that validated 3B as a
co-resident tenant.

### Why Vulkan, not ROCm

The 5700 XT is gfx1010 (RDNA1). ROCm has effectively no first-party
math-library support for that generation as of 2026, and PyTorch on
ROCm broke gfx1010 entirely in version 2.0 and later. Vulkan via
llama.cpp is the only mature path on that card.

The 7900 XTX is gfx1100 and runs both backends. I benchmarked them
head-to-head on 2026-04-16: same model, same flags, same llama.cpp
build (b8799). Vulkan won decisively on token generation
(151 tok/s vs 82 tok/s, +84%) while ROCm won on prompt processing
(391 tok/s vs 282 tok/s, +39%). Token generation dominates real chat
latency, so the win goes to Vulkan. Full numbers in
`docs/vulkan-vs-rocm-benchmark.md`.

The decision was: use Vulkan everywhere. The four llama-* units all
target Vulkan device indices (`Vulkan0` for the primary card,
`Vulkan1` for the secondary). This keeps the toolchain uniform
across both GPUs.

### Why the VRAM math works

The secondary card is 8.57 GB of usable VRAM (Vulkan reports the full
8 GB minus reserved regions). Steady-state under all three sidecars:

- Qwen3-4B Q4_K_M weights: ~2.4 GB
- multilingual-e5-large Q8_0 weights: ~0.6 GB
- Qwen2.5-Coder-3B Q4_K_M weights: ~1.9 GB
- KV caches (32K + 512 + 4K, all q8_0 keys/values): ~2.5 GB combined
- Vulkan driver overhead: ~0.7 GB

That sums to ~8.1 GB, leaving ~0.45 GB free. Tight, but stable. The
2-hour soak test on 2026-04-29 (E3) confirmed VRAM start = end = max
= 8.12 GB, no drift, no spikes.

The primary card runs much looser: GLM-4.7-Flash weights are ~10 GB,
the 64K KV cache (q8_0) is ~7 GB, leaving ~7 GB headroom for prompt
processing buffers. No contention concerns on the big card.

### Why the unit files are mostly identical

All four units have the same shape:

```
[Service]
Type=simple
EnvironmentFile=/etc/workstation/system.env
ExecStart=/usr/local/lib/llama.cpp/llama-server <model and flags>
Restart=on-failure
RestartSec=5s
KillSignal=SIGTERM
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal
```

Only the `ExecStart` arguments differ -- model path, device index,
context size, port, and role-specific flags (`--embedding --pooling mean`
for embed; `--jinja` and `-ctk q8_0 -ctv q8_0` for chat-shaped
services). Everything else (restart policy, kill behavior, logging)
is identical because the failure modes are identical: a llama-server
process either stays up serving requests, or it dies and systemd
restarts it five seconds later. There's no role-specific lifecycle
to encode.

The units are not enabled at boot. They start on demand from the
launcher, stay up across an entire work session, and stop politely
via `llama-shutdown` when nobody is using them. See
`docs/lifecycle-management.md` for that flow.

### The binary-path constraint

systemd resolves the first `ExecStart` token before applying
`EnvironmentFile` substitution. That means `/usr/local/lib/llama.cpp/llama-server`
in each unit is a literal path, not a `${WS_LLAMA_BIN}` template.
Updating the binary requires editing all four unit files by hand.

This is annoying. It's not fixable from systemd's side; the
work-around in other projects (a wrapper script that does its own
env resolution) was rejected here because the wrapper would itself
need to know its own location, which gets us back to the same
hardcoding problem one level up. Living with the four-edit cost
when llama.cpp upgrades is the cleanest option.

The `system.env` file documents this constraint near `WS_MODELS_DIR`,
so the next person who edits the env file knows the binary path is
not in scope.

### How to swap a model

Three steps:

1. Pull the new GGUF to `/var/lib/llama-models/<slug>/<filename>.gguf`.
2. Edit the relevant unit's `ExecStart -m` argument to point at the
   new GGUF. Optionally update `WS_<ROLE>_MODEL_DEFAULT` in
   `system.env` (advisory only -- the unit hardcodes the filename).
3. `sudo systemctl daemon-reload && sudo systemctl restart llama-<role>.service`.

The `WS_<ROLE>_MODELS_AVAILABLE` lists in `system.env` are advisory
catalogs, not load instructions. They exist so a future llama-swap
orchestrator (see below) can read them as the swap pool. Listing a
model in `_AVAILABLE` does not load it; only the filename in the
unit's `ExecStart` matters at runtime.

### What about llama-swap

llama-swap is a Go-based proxy that fronts multiple llama-server
instances and swaps them in and out based on which model the request
asks for. It would let the secondary card host more model-roles than
fit concurrently -- pick a 7B coder, evict it when summarize is
needed, etc.

I did not deploy it. Two reasons:

1. The current four-resident layout works. The 8 GB envelope holds
   under load. Adding a swap layer to fit a fifth model would mean
   accepting load latency on every cross-role call, which is
   exactly what I designed away from.
2. llama-swap's natural use case is "I want to host model A and
   model B in the same role slot, switch on demand." That is the
   right architecture for an editor that wants to choose between
   3B-fast and 7B-good for edit prediction; it is not the right
   architecture for the four-role system here, which has no
   role-vs-role swap need.

If the editor's quality bar grows (a future "use 7B for code-review
turns, 3B for typing turns"), llama-swap moves into the coder slot
specifically. The `WS_CODER_MODELS_AVAILABLE` list documents the
candidates for that future. The other three slots stay
single-resident.

## What you can change

Reasonable per-deployment edits:

- **Swap any model for another model of similar size.** Edit the
  unit's `ExecStart -m` line, restart the unit. Keep the model under
  the slot's VRAM budget (see "Why the VRAM math works" above).
- **Drop a service entirely.** If you do not use edit prediction,
  `systemctl mask llama-coder.service` and the launcher's wait loop
  ignores it (after editing `LLAMA_UNITS` in `scripts/2gpu-launch.sh`).
- **Move a service between cards.** Change `WS_GPU_*_DEVICE` in
  `system.env` and the unit's `--device` flag picks it up. Verify
  you have the VRAM headroom on the new card.
- **Change context windows.** Edit `WS_<ROLE>_CONTEXT` in
  `system.env`, restart the unit. Larger context costs proportional
  KV-cache VRAM (~q8_0 means ~2 bytes per token per layer per role).

Reasonable cross-stack changes:

- **Replace GLM-4.7-Flash with a different chat model.** The README
  promises that the slot is interchangeable. Anything in the
  16-22 GB Q4 range fits with 64K context.
- **Migrate to a 7B coder.** Documented as Shape B; requires
  evicting llama-secondary and llama-embed when the coder is loaded.
  Real architectural change, not a config swap.

What you should not change without thinking:

- **The Vulkan device-index assignments.** llama.cpp's enumeration
  is not always the same as `rocm-smi`'s; verify with
  `vulkaninfo --summary` before swapping `WS_GPU_PRIMARY_DEVICE`
  and `WS_GPU_SECONDARY_DEVICE`. The wrong assignment loads the
  primary model onto the small card and OOMs immediately.
- **The flash-attention and KV-quant flags.** `--flash-attn on
  -ctk q8_0 -ctv q8_0` is on the chat-shaped services for a reason:
  flash attention halves prompt-processing time, q8_0 KV halves the
  KV cache. Removing them costs VRAM headroom that is already tight.

## Where to look when something breaks

- A service starts but `curl http://127.0.0.1:PORT/v1/models` fails:
  `journalctl -u llama-<role>.service -n 100`. The most common cause
  is a wrong path in `ExecStart -m` (the `system.env` file is
  literal text in the unit; env-var substitution is shown
  unsubstituted in `systemctl show`). Confirm the GGUF actually
  exists at the path the unit wants.
- A service starts on the wrong card: `vulkaninfo --summary` to
  confirm the device-index mapping; check the unit's `--device`
  flag matches.
- Sustained 100% GPU but slow generation: a known ROCm issue on
  gfx1100, fixed by Vulkan. If you switched a unit back to ROCm
  for some reason, switch it back to Vulkan.
- All four services start but the launcher's splash hangs past
  60 seconds: usually one of the GGUF files is on cold disk and
  the page cache hasn't warmed yet. Wait it out, or pre-warm with
  `dd if=<gguf> of=/dev/null bs=1M`.

The full launcher and shutdown flow is in
`docs/lifecycle-management.md`.
