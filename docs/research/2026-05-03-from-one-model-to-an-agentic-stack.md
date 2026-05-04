# From one local model to an agentic stack -- the build history

**Date:** 2026-05-03
**Audience:** future-us (or anyone trying to build something similar)
**Scope:** how the 2GPU workstation went from "running a single
quantized coder model" in March 2026 to "running a 116B-param frontier
model with full 128K context inside a complete agentic stack" in May
2026. Includes dead ends.

This doc is the chronological story. The current snapshot lives in
[`2026-05-03-stack-one-sheet.md`](2026-05-03-stack-one-sheet.md). The
hardware-tuning specifics for the GPT-OSS-120B work specifically live in
[`gpt-oss-120b-moe-offload.md`](gpt-oss-120b-moe-offload.md).

---

## The starting point: one model, one card, one tool

Mid-March 2026, the workstation was running a fairly standard
single-model configuration:

- **Hardware:** Ryzen 9 5950X, 64 GB DDR4, RX 7900 XTX (24 GB), RX 5700
  XT (8 GB), Ubuntu 24.04. The 5700 XT was largely idle.
- **Model:** Qwen3-Coder-30B-A3B at Q4_K_M, 32K context, served by
  llama.cpp-on-ROCm.
- **Editor:** VSCodium with Roo Code (a Cline fork) as the agent.
- **Workflow:** start the model manually, work in VSCodium, stop the
  model when done. Roo's built-in indexing handled embeddings against
  Qdrant when codebase indexing was wanted.

This was the early-2026 mainstream path -- llama.cpp + Qwen3-Coder +
Roo + Qdrant -- and it worked, with the usual local-AI complaints:

- Context filled up fast at 32K
- Switching focus destroyed accumulated understanding
- The 5700 XT, the 16-core CPU, and the 30+ GB of free RAM were idle
  while the 7900 XTX did all the work

The April 2026 reference guide -- written before any of the
re-architecting -- listed those problems explicitly as the motivating
constraints. The phrase from that doc is worth preserving verbatim:

> Most of your hardware sits idle. A typical setup uses the primary
> GPU and ignores everything else. The secondary GPU runs autocomplete
> for a user who doesn't type code. The 16-core CPU idles during
> generation. 30+ GB of free RAM holds nothing. Four resources doing
> almost nothing while one resource does everything.

Solving that was the project.

## Phase 1 (mid-April 2026) -- two-card hardware envelope

The first structural decision was that the 7900 XTX should host **one
weights-heavy chat model at a time**, and the 5700 XT should host
**smaller bursty workloads that the agent loop calls during a session**.
This was decided during the Roo era, validated under a different agent
than the one we run today.

### The original Phase-1 design

Reference guide intent: one primary chat model on the 7900 XTX, plus
some "support intelligence" on the 5700 XT -- envisioned as a Phi-4
Mini observer, an aspect classifier, and possibly voice. The framing
was already moving past single-model use; it just hadn't decided what
the secondary card was *for*.

### What actually shipped

The Phi-4 Mini observer / aspect classifier / voice pipeline never
materialized. By April 29 the 5700 XT was hosting three different
co-resident services on Vulkan, validated under a 2-hour load soak:

| Service | Port | Role |
|---|---:|---|
| Qwen3-4B Instruct (32K) | 11435 | summarizer, secondary-opinion |
| multilingual-e5-large | 11437 | embeddings |
| Qwen2.5-Coder-3B (4K) | 11438 | edit predictions for the editor |

Three concurrent llama-server processes sharing 8 GB of VRAM, no
swap-in machinery, sustained under simulated agentic load. Edit
predictions p95 = 814 ms. Embeddings p95 = 583 ms. Zero failures.

(The full bench is at
[`docs/tries-and-takeaways.md`](../tries-and-takeaways.md), 2026-04-29
entry.)

This is where the "stateful primary, stateless services tier" pattern
quietly became the architecture. The summarizer + embedding +
edit-prediction split is *exactly* a stateless services tier -- each
call is fully specified by its arguments, no shared state across calls.
But the framing wasn't explicit yet.

### Lessons that carried forward

From `docs/lessons-learned.md` and `docs/lessons-from-the-roo-era.md`:

- **GPU device indices were inverted** vs. what the original guide
  assumed. GPU 0 = 5700 XT (gfx1010, 8 GB), GPU 1 = 7900 XTX (gfx1100,
  24 GB). Burned several hours before catching it. **Always re-derive
  hardware addressing from `rocminfo`/`lspci`, never trust a guide.**
- **HSA_OVERRIDE_GFX_VERSION is a compatibility hack, not a scope.**
  Without `ROCR_VISIBLE_DEVICES` it cheerfully loads an 18 GB model
  onto an 8 GB card.
- **Reference guides assume conservative fallbacks.** The first
  launcher draft had a `trap` that re-enabled Ollama on exit -- which
  would have silently undone an intentional boot cleanup. Cross-check
  every auto-action against your environment's documented constraints.

## Phase 2 (April 2026, mid-month) -- separating active and passive context

Around April 24 the project got a name for what was already happening.
A long brainstorming session (preserved at
[`docs/research/2026-04-24-conversation-notes-architecture-thinking.md`](2026-04-24-conversation-notes-architecture-thinking.md))
introduced the framing that became the architectural backbone:

- **Active context:** what the primary model must see to think clearly.
  The conversation, the working hypothesis, the recent tool calls.
- **Passive context:** noisy input that should be compressed off-card
  before any distilled result reaches the primary. Web searches, raw
  document content, embedding-based ranking work, file-mining queries.

The brainstorm doc says it directly: *"Current examples already built:
embedder on card 2, watcher on card 2, research distiller on card 2."*

This is the same distinction I (the agent helping with tonight's
session) later re-articulated as "stateful vs stateless." Same
substance, different vocabulary. Crediting the original: **the
passive/active framing predates the GPT-OSS-120B work by weeks and is
recorded in the project's research notes.**

## Phase 3 (April 22 onward) -- moving to opencode + Zed

The Roo era closed and the agent stack moved to **opencode** running
inside **Zed** as an ACP (Agent Client Protocol) child process.
Reasons captured in `docs/lessons-from-the-roo-era.md`:

- Roo's per-mode model routing was useful but Zed's UX with native
  agents was better
- opencode's plugin / MCP architecture was cleaner for layering Library
  on top
- The IDE-side feedback loop (file watching, diagnostics, edit
  predictions) was tighter

What carried forward from Roo:

- The two-card hardware envelope (kept verbatim)
- Rules-as-files (Roo's `.roo/rules/` -> opencode's `AGENTS.md`)
- The need for a polite-shutdown coordinator (became `llama-shutdown`
  + the launcher chain)

What changed:

- Editor / agent stack: VSCodium + Roo -> Zed + opencode
- The "support intelligence" framing on the secondary card was dropped
  in favor of the three-sidecar arrangement above
- A user-extensible MCP layer became the integration point for non-chat
  capabilities

## Phase 4 (late April) -- the Library MCP

The Library MCP is the bridge between the active and passive context
tiers. As of early May it provides five tools:

| Tool | Purpose |
|---|---|
| `library_research(question)` | Web search -> fetch -> chunk -> embed -> rank -> summarize, returns a compact summary |
| `library_read_file(path, query)` | Same pipeline applied to a local file: returns an answer, not file contents |
| `library_convert(src, dest, format)` | Binary docs (PDF, DOCX, image) -> markdown, on disk; metadata returned |
| `library_export(src, dest, format)` | Markdown -> DOCX / PDF / EPUB on disk via pandoc |
| `library_context_usage()` | Programmatic check on context-window usage |

Architecturally the Library does **type conversion** at the MCP
boundary: a stateful agent calls a stateless tool, the Library fans out
to stateless workers (search, fetch, chunk, embed, rank, summarize),
and returns a small payload that becomes part of the agent's
accumulating context.

The compression at the boundary is what makes long-context agentic
work practical. Without it, a 128K-token window doesn't actually buy
unbounded research -- it overflows after about 10 raw web fetches (see
the measurement in the one-sheet).

## Phase 5 (April 30 - May 1) -- baseline production state

By the start of May the workstation was running a production-shape
stack on the `main` branch:

```
main (cc9678c)
+-- llama-primary       :11434  GLM-4.7-Flash 64K (Vulkan, 7900 XTX)
+-- llama-secondary     :11435  Qwen3-4B-Instruct-2507 (Vulkan, 5700 XT)
+-- llama-embed         :11437  multilingual-e5-large (Vulkan, 5700 XT)
+-- llama-coder         :11438  Qwen2.5-Coder-3B (Vulkan, 5700 XT)
+-- Library MCP         (CPU + 5700 XT for embed/summarize)
+-- opencode + Zed      (ACP integration, AGENTS.md ruleset)
```

GLM-4.7-Flash was the daily-driver primary: fast (~30 tok/s gen, ~30
tok/s prompt eval at modest depths), 64K context, well-supported by
opencode's tool routing.

This is the state the May 2 evening session opened with.

## Phase 6 (2026-05-02 evening) -- the GPT-OSS-120B addition

The motivating prompt: "the 5 GB of free VRAM and 30+ GB of free DRAM
are still not doing anything for the chat path. Could a frontier-class
MoE model fit, with the experts offloaded to system RAM?"

The reference for "yes" was The Register's August 2025 hands-on with
llama.cpp's `--n-cpu-moe` flag, hitting ~20 tok/s on a 20 GB GPU + 64
GB DDR4 config running GPT-OSS-120B. Our hardware was a strict
superset.

The build path turned out to need three failed attempts before
landing:

### Attempt 1: stock llama.cpp Vulkan + `--n-cpu-moe`

**Failed.** RADV (Mesa's Vulkan driver for AMD) refused the 45 GB
host-visible Vulkan buffer that `--n-cpu-moe` allocates for the
CPU-resident expert weights:

```
radv/amdgpu: Not enough memory for command submission.
llama_model_load: error loading model: vk::Queue::submit: ErrorDeviceLost
```

This is a per-allocation/per-context limit in RADV, not a free-VRAM
issue. Failed identically across N values, context sizes, and
flash-attn on/off.

### Attempt 2: ik_llama.cpp HIP build

**Failed.** Both tip-of-tree and the GPT-OSS-introducing PR #689 had
build errors under modern ROCm 7.2.1: missing CMake defines
(`GGML_CUDA_FUSION`, `GGML_CUDA_MIN_BATCH_OFFLOAD`) in the HIP block,
and undeclared `nv_bfloat16` (no HIP shim typedef). Fixable, but more
engineering than the experiment warranted given that an alternative
was available.

### Attempt 3: mainline llama.cpp HIP build

**Worked.** Mainline's HIP backend is well-maintained, supports the
same `--n-cpu-moe` flag, uses `hipHostMalloc` for the CPU-resident
expert tensors (which has different allocation semantics than RADV's
host-visible Vulkan buffers and survives the 45 GB ask).

Build details:

```bash
cmake -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100 \
      -DCMAKE_C_COMPILER=/opt/rocm/bin/amdclang \
      -DCMAKE_CXX_COMPILER=/opt/rocm/bin/amdclang++ \
      -DLLAMA_CURL=OFF -G Ninja
cmake --build build --target llama-server -j 16
```

Installed to `/usr/local/lib/llama.cpp-hip/` (separate from the stock
Vulkan build at `/usr/local/lib/llama.cpp/`), wrapped in a new
`llama-primary-experiment.service` on port 11444.

### Tuning the live config

After the model loaded, four rounds of tuning landed the production
config. The full investigation log is in
[`gpt-oss-120b-moe-offload.md`](gpt-oss-120b-moe-offload.md); summary
of the choices that mattered:

| Knob | Value | Why |
|---|---|---|
| `--n-cpu-moe 28` | conservative | N=26 didn't help (top-4-of-128 routing makes this lever too coarse to extract speedup at the margin) |
| `-c 131072` | full native | Q8_0 KV at this depth = 2.45 GB, fits |
| `--flash-attn on` + `-ctk q8_0 -ctv q8_0` | symmetric | enables HIP fast-fused-FA path; cuts compute buffer 6x |
| `-b 2048 -ub 2048` | matched | 4.8x prompt-eval speedup vs `-ub 256` |
| `--cache-reuse 256` | enabled | KV-shifting prefix reuse for tool-loop patterns |
| `--swa-checkpoints 128` | quadrupled from default | long Zed sessions accumulate context past 38K tokens; default 32 fills up and starts evicting |
| `--no-mmap` | **removed** | originally on; pinned 60 GB in RSS and OOM-killed under desktop pressure. With mmap, kernel evicts cold expert pages on demand |
| `--alias gpt-oss-120b` | required for tools | opencode pattern-matches the model id to enable Harmony parsing and tool attachment |

The non-obvious findings:

- The official llama.cpp guide warns that Q8_0 KV "halves performance"
  on MXFP4-native models. **On AMD HIP this does not bite**, because
  the fused FA path -- which requires symmetric KV quantization -- more
  than offsets the Q8_0 KV cost. (Discussion #22411 in ggml-org/llama.cpp.)
- `-ub 256` was a holdover from the Vulkan compute-buffer constraints.
  Once we were on HIP and FA-on shrunk the compute buffer 6x, `-ub
  2048` could safely fill the recovered headroom and gave a 4.8x
  prompt-eval speedup.
- The opencode model-id alias was a *silent* bug. Without it, the
  model loaded and accepted requests, but opencode's openai-compatible
  adapter didn't attach tool definitions to the request -- the model
  generated working code in chat instead of writing files. The fix
  (one CLI flag) was found by grepping opencode's bundled binary for
  recognized model-id strings.

## Phase 7 (2026-05-02 night) -- Zed integration and the OOM cascade

Connecting the experimental primary to opencode/Zed surfaced one more
class of failure: **multi-process integration bugs** that hadn't
existed when the experiment ran in isolation.

### The OOM cascade

Symptom: the experiment was OOM-killed twice in one evening, both
times after long Zed sessions, both times with peak RSS around
54 GB on a 62 GB machine.

Diagnosis: `opencode-session.sh` (the launcher Zed invokes) starts
**all four** standard llama services unconditionally on every Zed
session. With the experiment already loaded on the 7900 XTX, starting
`llama-primary` forced GLM-4.7-Flash to attempt loading on a card with
~3 GB free; the failed-load cascade put host-memory pressure on a
system already at 50 GB+ RSS in the experiment, and the kernel
OOM-killed the largest process: the experiment.

This is the kind of bug that **only exists at the systemd-services-and-
launcher layer**, not at the llama.cpp layer. It wouldn't show up in
any benchmark; it shows up after a 4-hour real coding session.

### Fix: experiment-aware launcher

`compute_active_units()` in `opencode-session.sh` (and the equivalent
block in `2gpu-launch.sh`) checks `systemctl is-active --quiet
llama-primary-experiment` at session start. If active, it substitutes
the experiment for `llama-primary` in the unit list and the endpoint
list. Standard four-unit behavior remains the default when the
experiment is inactive.

### Stability after the fix + remaining tuning

Removing `--no-mmap` (so the kernel can evict cold expert pages under
pressure) and bumping `--swa-checkpoints` from 32 to 128 (so long
sessions don't thrash the cache) eliminated the OOMs and the
generation-tok/s dip that had appeared at ~38K context depth.

Post-tuning measurement: 1h 20m+ uptime, 50 GB stable RSS, generation
held at 16.88 tok/s ± 1.56 across 52 measured requests with context
depths from 852 to 44,620 tokens. No degradation by depth, no OOM, no
slowdown.

## Phase 8 (2026-05-03) -- the UX day

The May 2 evening produced a working but rough integration. May 3 was
spent turning it into something a user can sit down at and trust. The
day's output was almost entirely **operator UX** -- not new
performance, not new architecture, but the layer of polish that makes
the difference between "this works if you know how to drive it" and
"this works."

### From experiment-aware launcher to router mode

The Phase-7 substitution dance (`compute_active_units` in two
launchers, two mutually-exclusive systemd units fighting over the
primary GPU) was a workaround for a deeper limitation: llama-server
historically hosted one model per process. **Mainline llama.cpp PR
[#16653](https://github.com/ggml-org/llama.cpp/pull/16653) (2025-12-15)
added router mode** -- a single llama-server can declare multiple
models in an INI preset and load them on demand from
`POST /models/load`. Hugging Face wrote the
[explainer](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp)
and Glukhov posted a
[walkthrough](https://medium.com/@rosgluk/llama-server-router-mode-dynamic-model-switching-without-restarts-4e7d6fb19906)
during April 2026; both came across the desk after the May 2 build was
already running.

Replacing the two-unit Vulkan-GLM-and-HIP-OSS design with one router
unit collapsed the architecture by about 50 lines. The router lives at
[`systemd/llama-primary-router.service`](../../systemd/llama-primary-router.service);
all per-model tuning is in
[`configs/workstation/llama-router.ini`](../../configs/workstation/llama-router.ini).
GLM also picked up a 2.4x speedup running on the HIP build instead of
its prior Vulkan path -- ~30 → ~72 tok/s -- because we no longer had
to keep Vulkan around for any reason. Verification numbers in
[`docs/research/2026-05-03-router-mode-validation.md`](2026-05-03-router-mode-validation.md).

### Building the swap UX

Router mode mechanically supports swapping; making it a usable
experience was its own project. The shape that emerged:

```
User picks model in Zed footer dropdown
  -> User types and sends a message
  -> opencode-acp's prompt loop checks if target is loaded
  -> Not loaded: forks scripts/model-swap.sh
  -> yad confirm dialog (--center --on-top --sticky) +
     notify-send banner
  -> User clicks Swap
  -> yad pulsate progress, polling /models for status=loaded
  -> ~35 s for GLM, ~4 min for OSS
  -> Message goes through on the now-loaded model
```

Five separate operational issues had to be solved before this worked
end-to-end:

1. **`OPENCODE_MODEL_SWAP_SCRIPT` env var must be set** in Zed's
   isolated profile. Without it, picking a not-loaded model 400s
   silently with no user feedback. Wired in
   `~/.local/share/zed-second-opinion/config/settings.json`.
2. **Compaction agent must be the largest-context model in the pool.**
   Today that's gpt-oss-120b (`agent.compaction.model` in the
   opencode template). Without the pin, opencode's compaction routes
   to whichever model the user picked, which fails with
   `ContextOverflowError` if the pick was the smaller model and the
   session is large.
3. **Title agent must be pinned to the always-loaded secondary
   sidecar** (Qwen3-4B on the 5700 XT). Title generation forks via
   `Effect.forkIn(scope)` parallel to the main loop and races with
   the swap popup; pinning it to a model that isn't part of the swap
   takes it out of the race.
4. **Picker change in Zed sends no RPC to opencode.** The dropdown is
   a client-side widget; the model selection is bundled into the next
   `POST /session/.../message`. Discovered by enumerating every RPC
   opencode-acp received during a picker-change session. Documented
   honestly in code comments and in the
   [research note](2026-05-03-router-mode-swap-implementation.md).
   Consequence: the swap popup fires at message-send time, not at
   pick time. There is one extra step where the user has typed but
   the popup hasn't appeared. The dead-code
   `unstable_setSessionModel` hook stays in
   `our-patch-router-swap.diff` for forward-compat if Zed ever adds
   the setter RPC.
5. **Popup must be foreground.** Default yad behaviour put the dialog
   behind Zed; users typed messages thinking nothing happened. Fixed
   with `--center --on-top --sticky` plus `notify-send -u critical`
   for a tray banner that's hard to miss.

### Auto-fit A/B: settled, autofit lost

`--fit on` (PR #16653, same release as router mode) auto-probes free
VRAM and computes per-tensor placement, including expert offload to
CPU for MoE models. The hand-tuned `--n-cpu-moe 28` baseline predates
auto-fit by months. Worth a one-off A/B.

The
[bench harness](../../bench/oss-tuning.sh) ran 3 iterations × short
prompt against each preset:

| | gen tok/s (mean) | gen tok/s (stddev) | load time | VRAM peak |
|---|---:|---:|---:|---:|
| baseline (`--n-cpu-moe 28`) | 19.75 | 0.40 | 2:42 | 20.3 GB |
| auto-fit (`--fit on`) | **5.57** | **3.51** | 7:35 | **24.3 GB** |

Auto-fit is 3.5x slower on average and erratic (one run dropped to
1.80 tok/s). It also pushed VRAM essentially to the 24 GB ceiling --
the "more weights on GPU is faster" intuition lost to "leave room for
the KV cache." Reverted, with
[the bench note](2026-05-03-oss-autofit-bench.md) capturing the
numbers so this experiment doesn't have to be rediscovered.

### Operator polish

Six smaller fixes that each fixed a real broken thing:

- **AGENTS.md symlink at repo root.** opencode's `findUp("AGENTS.md")`
  walks from cwd upward. The agent rules at
  `configs/opencode/AGENTS.md` sit *below* the repo root, so when Zed
  opens the repo (cwd = repo root), `findUp` never descended into
  `configs/`. Symlinking the file at the repo root fixes the
  resolution for all models, not just OSS. Caught when OSS appeared
  to "regress" -- it hadn't; *no* model had been reading the rules.
- **polkit allowlist updated and templated.** The repo template
  shipped with `["your-username-here"]` as a placeholder, which would
  have locked out both real users on `cp`. Reworked
  `systemd/polkit/10-llama-services.rules` to ship with a
  `__WS_LLAMA_USERS__` token; `scripts/install-systemd-units.sh`
  reads `WS_LLAMA_USERS` from `/etc/workstation/system.env`, validates
  each name (alphanumerics + underscore + hyphen), emits a JSON
  array, and substitutes only the code-line occurrence so comments
  stay readable. Real usernames never enter the repo. Also added the
  new router unit to the allowlist and kept the old names for
  rollback safety.
- **Picker tightened to validated chat models only.** Dropped
  `llama-embed` and `llama-coder` from the opencode template (Library
  MCP and Zed's edit-predictions reach those services directly, not
  through the opencode provider registry). Renamed the
  `llama-secondary` provider's display from "summarize" to "internal"
  and the model name to "Qwen3-4B (title agent -- do not select for
  chat)" so users see why a 4B model is in the picker. Added
  `"disabled_providers": ["opencode"]` to suppress OpenCode Zen's
  free-tier models -- opencode bypasses the env-key check
  specifically for the `opencode` provider id at
  `provider.ts:152-174`, registering Big Pickle and GPT-5 Nano with
  a hardcoded `apiKey: "public"`. Per
  [opencode.ai/docs/zen](https://opencode.ai/docs/zen), Big Pickle is
  a "stealth model... your prompts may be used to improve the
  model" -- a real privacy consequence for casual selection.
- **Title agent and compaction agent pins.** Both surfaced as
  silent-400 failures in live testing before the pins landed. The
  pins are now load-bearing -- if either is wrong, swaps break.
- **swa-checkpoints from 128 (May 2 night) back down to 64.** The
  May 2 bump to 128 hung after an 8-hour session; midpoint 64
  resolved both the thrashing of the original 32 and the runaway
  scan of 128.
- **Bench harness for future model A/Bs.** `bench/oss-tuning.sh`
  swaps presets via `/models/load`, runs fixed prompts N times,
  outputs CSV. Throwaway-grade but the right shape for the next
  preset comparison.

### What this day proved

End-to-end UX works. Pick a model in the picker → send a message →
popup appears front-and-center → confirm → progress dialog → answer
arrives. That is the flow a daily user gets, and it survives the
edge cases that surfaced during testing. The architecture from
Phase 1-5 is unchanged; this day's work was making the user's
fingertips meet the architecture without friction.

The honest scope-claim: nothing on this day was a research result.
Router mode is upstream. The swap UX is yad + bash + a 5th opencode
patch. The auto-fit revert is a negative result. The picker cleanup
is config. None of it would be a publishable contribution. All of it
is the difference between a stack that runs and a stack that's
*pleasant to use.*

## What this evening proved (and what it didn't)

### What was demonstrated

- A 116B-param frontier MoE model can run comfortably on consumer
  AMD hardware (24 GB GPU + 64 GB RAM) at 17 tok/s sustained, with
  full 128K context, integrated into Zed/opencode with full tool
  use, alongside three supporting models on the secondary GPU.
- The Library MCP delivers >40x context compaction on real research
  calls (anchored measurement, not estimate), making long-context
  agentic work practical.
- The hardware-tier separation (stateful big GPU + stateless small
  GPU + CPU sidecars) holds up under live agentic load.

### What this did not demonstrate

- **None of the tonight's measurements are novel results.** The
  ~20 tok/s GPT-OSS-120B-on-consumer-AMD number was already in The
  Register's August 2025 article. Mainline llama.cpp's HIP +
  `--n-cpu-moe` path is documented. The HIP fast-fused-FA + symmetric
  KV trick is in Discussion #22411. We replicated and measured.
- **The architecture was not built tonight.** The two-card hardware
  envelope, the active/passive context split, the Library MCP, the
  service lifecycle -- all of those existed before May 2 and are
  recorded in earlier docs and memories. Tonight added one
  experimental fourth tenant (GPT-OSS-120B as an alternate primary)
  to the existing three-tenant architecture, plus the integration
  patches needed to support it.

### What's actually new

Three things specifically:

1. **The launcher's experiment-aware service-substitution logic**
   (`compute_active_units` in `opencode-session.sh`,
   equivalent in `2gpu-launch.sh`). Required because the experiment
   is mutually exclusive with `llama-primary` on the 7900 XTX.
2. **The `--alias gpt-oss-120b` discovery** -- not an invention so
   much as an undocumented gotcha exposed by using a local-file
   model id instead of `-hf <repo>`. Documented in the opencode
   integration commit.
3. **First measurements** of the existing architecture under
   frontier-model load (the 42.8x compaction number, the 124B
   effective-capacity number, the 17 tok/s sustained at depth, the
   stability over a long session). Tonight gave the architecture
   its first hard performance data.

## Phase 9 (2026-05-04) -- the swap UX moves into the chat panel

Phase 8 ended with router-mode swaps gated by a yad popup on the
workstation's local display. That worked for Josh sitting at the
desk; it didn't work for Anny on her laptop (no display reachable),
and it didn't compose with future "agent at coffee shop"
configurations. The popup also sat outside Zed -- the user's
attention had to leave the agent panel to confirm a swap.

Phase 9's goal: a single confirm-card UX that lives inside the chat
panel, works identically for local and remote users, and is reachable
both via the model-picker dropdown and via a typed slash command.

### v2 was the wrong shape

The first attempt (commits `a20f592` through `51af14b`) put the swap
flow in the picker handler (`unstable_setSessionModel`). The handler
ran a JSON preflight and stashed the result in a module-level Map
(`acp/pending-swap.ts`). The on-message check in `session/prompt.ts`
read the Map, raised an ACP `permission.ask`, and ran the load.

The split was forced by ACP scoping: `permission.ask` only works
inside session-scoped Effect generators, which the picker RPC handler
isn't. So state had to cross the picker → prompt-loop boundary.

Live test of v2 produced a yad popup -- the legacy fallback path. The
on-message check wasn't finding the stashed entry. We never diagnosed
the precise cause; the architecture was the underlying issue.

### v3: collapse to a slash command

The redesign moved everything into the slash-command dispatch
(`switch (cmd.name)` in `acp/agent.ts`), which already runs in
session scope with `this.connection`, `this.sessionManager`, and
`this.sdk` all reachable. One handler:

- `/models` -- list all router-known models with status and registry
  presence.
- `/models <id>` -- preflight, raise the confirm card, on Allow run
  `--execute`, on Deny revert.
- Picker pick -- emit a synthetic `/models <id>` chat message via
  `this.prompt({...})` with `annotations.audience: ["assistant"]`
  (the `synthetic: true` translation that compaction summaries and
  system reminders already use). Same handler runs.

No shared module. No on-message branching. The whole feature is one
case branch plus a renderer.

The bash data layer split cleanly into modes: `model-swap.sh
--preflight <id>` emits JSON for the card, `--execute <id>` does the
quiet load with `[swap]` heartbeats, `--list` enumerates router state
+ registry. The yad popup path stays for terminal use during
incidents (Stage 3 will remove it).

### What measured up live

Build `0.0.0--202605041505`, levine's isolated profile. All five
typed `/models` paths verified end-to-end:

- `/models` (bare) -- listing renders correctly with descriptions
  and a "⚠ not in registry" annotation when applicable.
- `/models <currently-loaded>` -- short-circuits with `<id> is
  already loaded.`
- `/models <not-in-registry>` -- emits `<id> is not in the model
  registry. Edit primary-pool.json to register it.` (free path,
  not in the original spec).
- `/models <unloaded>` + Reject -- card renders with title `current →
  target`, ✓/⚠/✗ resource lines, trailer; click reject; chat shows
  `Cancelled — staying on <previous>.`
- `/models <unloaded>` + Allow -- card; click Allow; foldable
  terminal block streams `[swap] Loading...`, heartbeats every ~30s,
  bookend `✓ <id> loaded (Ns)`. Verified gpt-oss-120b load at ~186s
  and glm-4.7-flash at ~30s.

Stage 2 (anny's `model-swap-remote.sh` cutover) shipped together
with Stage 1 because v3's design forced it: the slash-command
handler unconditionally calls `--preflight` on whatever script
`OPENCODE_MODEL_SWAP_SCRIPT` points at. A one-line passthrough
(`exec model-swap.sh "$@"` for flag-mode invocations) made anny's
flow uniform with levine's.

### What didn't work

Three known limitations documented in `opencode-zed-patches/fix-7-shipped.md`:

1. **Picker label stays stale after a typed swap.** ACP exposes
   `configOptions.currentModelId` only in RPC responses, never via
   push notification. After `/models gpt-oss-120b` succeeds, Zed's
   footer still shows GLM. Chat actually routes to gpt-oss; the
   context-window tooltip updates correctly (the `usage_update`
   notification carries `size`); only the picker label is wrong.
   Workaround: re-pick from the dropdown to force Zed's UI to
   refresh. Real fix needs an ACP message type for current-model
   updates -- upstream Zed work.

2. **Picker pick is silent.** Selecting a different model from Zed's
   dropdown produces nothing -- no chat message, no card, no swap.
   The `this.prompt({...})` synthetic-prompt dispatch isn't reaching
   the slash-command handler. Possible causes (not diagnosed):
   `this.prompt()` may bypass the slash-command parser the way
   `this.sdk.session.prompt()` does; the `audience: ["assistant"]`
   → `synthetic: true` translation may not be firing; the async
   lifecycle may be dropping the promise. Workaround: type
   `/models <id>` in chat. Investigation deferred to fix-8.

3. **Cancel-mid-load doesn't kill the spawn.** Same shape as the
   bash tool's existing limitation. Fix path is clear (wrap in
   `Effect.acquireRelease` with `child.kill('SIGTERM')`); both
   should be fixed together when bash gets the same treatment.

### Two slash-command-mechanics learnings worth keeping

**Adding a built-in slash command requires TWO edits.** The
`switch (cmd.name)` case branch alone isn't enough -- opencode's
slash-command parser rejects unknown commands BEFORE the switch
runs. The fix is to also push `{name: "models", description: "..."}`
into `availableCommands` (around line 1615 of `acp/agent.ts`,
alongside the existing `compact` registration). The `if
(!names.has(...))` guard lets a user-defined MCP-prompt of the same
name take precedence. Saved as a memory note for future patches
(`reference_opencode_slash_commands.md`).

**The `synthetic: true` flag is delivered via `annotations.audience:
["assistant"]`** in the part. Any other route appears to bypass the
translation. The synthetic flag matters because it keeps the
synthetic-prompt text out of LLM context entirely -- Zed sees the
message bubble, the model never does.

### AGENTS.md gets a first-message banner

Cosmetic gap in #1 (picker label stale) made it useful to give the
model the truth about its identity. AGENTS.md now instructs:

> If this is the first user message AND it's a greeting / capability
> question / unclear, your response MUST start with: "Running
> <your-model-id>. Use `/models` to change models. The GUI model
> selector is broken; ignore it."

Solves the "I just opened a panel, what am I talking to?" moment
without an opencode patch. The model's own self-identification is
canonical; the picker label is documented as cosmetic.

### What Phase 9 proved

- The `/models` slash-command shape is the right one. Single handler,
  in session scope, no cross-package state, works identically for
  local and remote users.
- Splitting the bash data layer into `--preflight` / `--execute` /
  `--list` modes was reusable across the v2 dead end and the v3
  redesign. Worth doing first before the TS work because the JSON
  schema is the contract.
- The v2 picker-handler approach is recoverable in repo history
  (`opencode-zed-patches/our-patch-router-swap-v2.diff` is kept as
  reference). Useful for future "what if we tried..." moments.
- ACP has gaps. Picker-label staleness and picker-pick silence are
  both ACP-protocol-shaped problems, not opencode bugs. The right
  fixes are upstream Zed PRs; the right local response is to live
  with the gap and route the user via `/models`.

Restore point: git tag `swap-card-v3-deployed`, commit `123740b`
(plus `3d3a498` for the AGENTS.md banner).

## Open work

The build is functional and pleasant. Open items remaining:

- **Promotion path for GPT-OSS-120B.** Same question as before --
  daily driver, or deep-reasoning fallback? The router-mode swap UX
  changes the trade-off: switching costs ~4 minutes once per workday
  rather than a service restart, which makes "use OSS deliberately
  for the hard problem" practical in a way it wasn't on May 2.
- **Pre-swap compaction orchestration.** With `--models-max 1` the
  router can't hold OSS loaded for compaction *while* loading GLM
  for inference. A future router with `--models-max 2` and explicit
  compaction-vs-inference selection would let us orchestrate this;
  today, opencode's `agent.compaction.model = gpt-oss-120b` pin
  handles the post-swap case where compaction would otherwise route
  to the wrong model.
- ~~**Remote-user popup forwarding.**~~ **Resolved in Phase 9.** The
  v3 `/models` slash command runs in-chat for both local and remote
  users; no display-bound popup. yad path retained for terminal
  incident use only.
- ~~**Second-user / remote-laptop integration.**~~ **Resolved in
  Phase 9.** `model-swap-remote.sh` now forwards flag-mode args
  (`exec model-swap.sh "$@"`) so anny's launcher works uniformly
  with v3.
- **Picker-pick silent dispatch (fix-8).** Selecting a different
  model in Zed's picker should emit a synthetic `/models <id>` chat
  message but currently produces nothing. Typed `/models` works.
  Investigation TBD.
- **Picker-label staleness.** ACP gap; needs upstream Zed work for a
  proper fix. AGENTS.md first-message banner mitigates by giving
  the model itself the truth.
- **Cancel-mid-load.** Spawned `--execute` survives session abort.
  Same pattern as bash tool's existing limitation; fix together.
- **Library MCP measurements at scale.** The 42.8x number is anchored
  on three calls. Worth a longer-run study.
- **Skill loader exercise.** Still largely untested under real load.

## Citations

Primary references that informed the build, in order of relevance:

- The Register, "Llama.cpp hands-on" (2025-08-24) -- showed
  GPT-OSS-120B at ~20 tok/s on a 20 GB GPU + 64 GB DDR4 with
  `--n-cpu-moe 26`. This was the seed.
  https://www.theregister.com/2025/08/24/llama_cpp_hands_on/
- ggml-org/llama.cpp Discussion #15396 -- official gpt-oss running
  guide. Source for the `--ctx-size 0`, `-b 2048 -ub 2048`, KV-quant
  warning.
- ggml-org/llama.cpp Discussion #22411 -- AMD HIP fast-fused FA path
  requires symmetric KV quantization. Source for the FA-on +
  Q8_0 KV combination that made 128K fit.
- ggml-org/llama.cpp Issue #15120 -- Vulkan KV alloc failures on AMD.
  Corroborated our Phase-1 RADV failure.
- ggml-org/llama.cpp PR #15293 -- SWA checkpoint feature; basis for
  the `--swa-checkpoints 128` tuning.
- ggml-org/llama.cpp Issue #17527 -- KV cache restore failures with
  parallel + SWA. Why we keep `--parallel 1`.
- HuggingFace Doctor-Shotgun, "Performant MoE CPU+GPU offload guide" --
  source for `LLAMA_SET_ROWS=1` env var and ubatch tuning advice for
  MoE hybrid inference.
- AMD ROCm blog, "Accelerating llama.cpp on MI300X" (Oct 2025) --
  context for hipBLASLt grouped GEMM availability and recent
  performance work on AMD.

Project-internal docs that established the architecture this build
extends:

- `docs/reference-guide.md` -- the original April 2026 design intent,
  including the "four resources doing almost nothing" framing.
- `docs/research/2026-04-24-conversation-notes-architecture-thinking.md`
  -- the active/passive context split, in your own words.
- `docs/lessons-from-the-roo-era.md` -- what carried forward from the
  Roo Code stack.
- `docs/tries-and-takeaways.md` (2026-04-29 entry) -- the
  three-sidecar 5700 XT bench that validated the secondary-tier
  design.
- `docs/lessons-learned.md` -- Phase-1 mistakes worth remembering
  (GPU index inversion, HSA override, etc).

## Honest credit

For my own future-me records, since I do collaborate with humans on
this stuff: the architecture (two-card envelope, active/passive split,
Library MCP, stateless services tier, polite shutdown coordinator) was
designed by Josh over the months preceding May 2026. Tonight's session
extended that architecture with one experimental fourth tenant
(GPT-OSS-120B) and produced the first measurement run of the system
under frontier-model load. The agent helping with the session
(Claude, Opus 4.7) contributed diagnostics, code mechanics, and
ecosystem lookups, mostly within a frame Josh had already established.

Where credit lines matter: see [the one-sheet](2026-05-03-stack-one-sheet.md)
for the architecture's claims and measurements as testable results;
see this doc for the build history and what was novel vs. what was
replicated.
