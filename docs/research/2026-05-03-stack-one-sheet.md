# 2GPU Local AI Workstation -- One Sheet

**Date:** 2026-05-05
**Hardware:** Ryzen 9 5950X, 64 GB DDR4-3200, RX 7900 XTX (24 GB, gfx1100),
RX 5700 XT (8 GB, gfx1010), Ubuntu 24.04, kernel 6.17

A single-machine local agentic coding stack that runs a four-model
primary pool -- a frontier-class 80B reasoning pair (Thinking +
Instruct), a coding specialist, and a fast generalist -- with up to
96K context, alongside three supporting models, a Library MCP, and a
persistent-memory service, on consumer AMD hardware. No cloud
dependency, no datacenter GPU, no rental cost beyond electricity.

---

## What this is

**A complete agentic workstation, not just a model running locally.** The
stack treats inference as one of several workloads and structures the
hardware around the *system* a developer needs, not just around peak
benchmark throughput.

```
+--------------------------------------------------------------+
|  STATEFUL TIER -- 7900 XTX (24 GB VRAM) + System RAM         |
|                                                              |
|  Router-mode llama-server hosts a 4-model primary pool, one  |
|  loaded at a time, swapped via /models slash command:        |
|                                                              |
|    qwen3-next-80b-thinking  -- frontier reasoning + default  |
|                                compaction agent (96K ctx,    |
|                                highest in pool). 80B MoE/3B  |
|                                active, hybrid Gated DeltaNet |
|                                attention, MoE offload to     |
|                                DRAM (n-cpu-moe=28).          |
|                                reasoning-format=deepseek +   |
|                                reasoning-budget=4096 yield   |
|                                a foldable Thinking pill in   |
|                                Zed (Phase 13).               |
|    qwen3-next-80b-instruct  -- non-thinking sibling for      |
|                                agent loops where reasoning   |
|                                traces are noise. Same shape, |
|                                96K ctx.                      |
|    qwen3-coder-30b          -- coding specialist. 30B MoE/3B |
|                                active, fully GPU-resident,   |
|                                64K ctx.                      |
|    glm-4.7-flash            -- fast generalist. Fully GPU-   |
|                                resident, 64K ctx.            |
|                                                              |
|  Largest tenant (qwen3-next-80b-thinking @ 96K) sets the     |
|  envelope:                                                   |
|    weights on GPU:    19.1 GB (20 attention + 1 MoE layer)   |
|    weights on DRAM:   25.4 GB (27 of 47 MoE layers offload)  |
|    KV cache (Q8_0):    1.7 GB                                |
|    SSM recurrent st:   0.3 GB (Gated DeltaNet state)         |
|    compute buffer:     0.7 GB                                |
|                                                              |
|  Single accumulating conversation, tuned for amortized cost  |
|  across multi-hour sessions, not peak benchmark throughput.  |
+--------------------------------------------------------------+
              ^                     |
              | summaries           | tool calls (research,
              | (~325 tokens        |  read_file, convert,
              |  per research call) |  export, context_usage)
              |                     v
+--------------------------------------------------------------+
|  LIBRARY MCP -- the boundary between tiers                   |
|                                                              |
|  Owns the type conversion: stateless raw output IN,          |
|  compressed summary OUT. Fans tool calls out to the          |
|  stateless workers below; aggregates, chunks, ranks, and     |
|  summarizes their results before returning to the agent.     |
|                                                              |
|  Without it, raw research output overflows the 96K window    |
|  after 7-10 webfetches.                                      |
+--------------------------------------------------------------+
              ^                     |
              | raw worker          | worker calls (search,
              | output              |  fetch, embed, summarize,
              | (HTML, text,        |  convert)
              |  embeddings)        v
+--------------------------------------------------------------+
|  STATELESS SERVICES TIER -- 5700 XT (8 GB) + CPU sidecars    |
|                                                              |
|  5700 XT (Vulkan, gfx1010) hosts three concurrent models:    |
|    Qwen3-4B Instruct (32K) -- summarizer       :11435        |
|    multilingual-e5-large -- embeddings         :11437        |
|    Qwen2.5-Coder-3B -- edit predictions        :11438        |
|                                                              |
|  CPU sidecars (5950X, 16 cores):                             |
|    docling-serve -- DOCX/PDF/image -> text                   |
|    pandoc -- markdown -> DOCX/PDF/EPUB                       |
|    SearxNG (when running) -- web search                      |
|    HTML extraction, chunking, ranking (in Library workers)   |
|                                                              |
|  Each task pure: same input -> same output, no shared state. |
+--------------------------------------------------------------+

Edit-prediction (Qwen2.5-Coder on the 5700 XT) is the one
exception to the Library-as-boundary rule -- Zed talks to it
directly on a latency budget that can't tolerate an extra hop.
Everything else routes through Library.

+--------------------------------------------------------------+
|  PERSISTENT MEMORY -- mnemory                  :8050         |
|                                                              |
|  Cross-session fact extraction, dedup, semantic recall.      |
|  Fact extraction:    qwen3-4b (port 11435, shared sidecar)   |
|  Embeddings:         e5-large (port 11437, shared sidecar)   |
|  Vector store:       embedded Qdrant in ~/.mnemory/qdrant/   |
|  Multi-user:         per-user namespacing via API keys       |
|                                                              |
|  Loaded into opencode via @fpytloun/opencode-mnemory plugin  |
|  (auto-recall on session start, auto-capture on each turn).  |
|  Survives session reboot; the agent starts a new conversation|
|  knowing what it learned in prior ones.                      |
+--------------------------------------------------------------+

mnemory and Library serve different needs and coexist: Library
compresses external content (web, files) into the chat session;
mnemory persists conversational facts across sessions. Both feed
through the qwen3-4b sidecar for their LLM work, sharing the
secondary's queue.
```

## Effective parameter capacity served simultaneously

The primary slot is router-mode and hosts one of four models at a
time. Effective capacity is computed against the largest tenant
(Qwen3-Next-80B-A3B-Thinking at 96K context); the smaller models
leave headroom but the envelope is set by the worst case.

| Role | Model | Params | Lives on |
|---|---|---:|---|
| Primary -- frontier reasoning (default for hard) | Qwen3-Next-80B-A3B-Thinking | 80 B (3 B active) | 7900 XTX + DRAM |
| Primary -- non-thinking sibling | Qwen3-Next-80B-A3B-Instruct | 80 B (3 B active) | 7900 XTX + DRAM |
| Primary -- coding specialist | Qwen3-Coder-30B-A3B-Instruct | 30 B (3 B active) | 7900 XTX |
| Primary -- fast generalist | GLM-4.7-Flash | ~12 B | 7900 XTX |
| Summarizer | Qwen3-4B Instruct | 4.0 B | 5700 XT |
| Embeddings | multilingual-e5-large | 0.56 B | 5700 XT |
| Edit predictions | Qwen2.5-Coder-3B | 3.0 B | 5700 XT |
| **Total at envelope (qwen3-next-thinking loaded)** | | **~88 B** | |

GPT-OSS-120B was dropped from the pool on 2026-05-05 (Phase 12)
after benchmarks showed Qwen3-Next-80B-Thinking matched or beat
it on every measured axis at lower memory cost. Weights remain on
disk for restoration. See Phase 11-12 of the build history for
the bench data and reversal path.

Hardware total: ~$1,200 (7900 XTX, 5700 XT used, 64 GB DDR4-3200,
Ryzen 9 5950X used).

## Measured performance (live Zed coding session, 2026-05-02)

**Source:** `/home/levine/.local/share/opencode/log/2026-05-02T205054.log`
plus the systemd journal of `llama-primary-experiment.service`. 52
completed requests captured with timing data, context depths from 852 to
44,620 tokens.

### Throughput

| Metric | Value |
|---|---:|
| Generation tok/s | 16.88 ± 1.56 (CV 9.3%) |
| Prompt eval (cold, 43K-token prompt) | 476 tok/s |
| Prompt eval (avg across 52 requests) | 138.8 tok/s |

No degradation across context-depth buckets:
- 20K-30K: 17.37 tok/s avg (29 samples)
- 30K-40K: 16.93 tok/s avg (12 samples)
- 40K-50K: 16.34 tok/s avg (6 samples)

### Stability

| Metric | Value |
|---|---:|
| Service uptime, current run | 1h 20m+ (still running) |
| OOM events post-tuning | 0 |
| OOM events pre-tuning | 2 in one evening |
| Peak RSS, sustained | 50.05 GB |

### Tool-call density

In one session: 32 unique tool calls, 90.6% completion, 9.4% errors.

| Tool | Count | Source |
|---|---:|---|
| edit | 13 | built-in |
| bash | 9 | built-in |
| write | 5 | built-in |
| library_research | 3 | Library MCP |
| glob | 1 | built-in |
| skill | 1 | opencode skill loader |

## Library MCP context efficiency

**Anchor measurement, single research call (2026-05-02):** 5 source
URLs actually re-fetched and HTML-stripped to byte counts.

| | Library | Webfetch counterfactual |
|---|---:|---:|
| Tokens returned to model | 325 | 13,907 |
| Compaction ratio | -- | **42.8x** |

**Second measurement, two research calls (2026-05-05):** Two queries
sampled from a 15-call WhatsApp-Web automation funnel, same
methodology, fresh source URLs.

| | Q3 | Q13 | Average |
|---|---:|---:|---:|
| Library returned (tokens) | 445 | 395 | 420 |
| Webfetch counterfactual (tokens) | 9,856 | 8,478 | 9,167 |
| Compaction ratio | 22.1x | 21.5x | **~21.8x** |

The two measurements bracket the range. The 2026-05-05 numbers are
lower because the topic happened to surface lighter pages (one source
was a JS-rendered SPA where regex extraction caught almost nothing);
the 2026-05-02 anchor hit heavier ones. **A defensible point estimate
is 22-43x compaction, depending on source bloat.**

**Session totals (15 research calls, 2026-05-05, both
extrapolations shown):**

| | Library actual | Webfetch @ 21.8x (today's avg) | Webfetch @ 42.8x (anchor) |
|---|---:|---:|---:|
| Total tokens | 6,439 | 137,505 | 208,605 |
| Fraction of 96K window | 6.7% | OVERFLOWS | OVERFLOWS |

### Why the Library is load-bearing, not optional

Costs computed at the conservative 21.8x ratio (the 2026-05-05 average,
not the original 42.8x anchor) so the case is the strongest possible
against the most pessimistic compaction:

```
Research calls per session   Library cost     Webfetch cost (cons. 21.8x)
---------------------------- ---------------- ----------------------------
            3                    1,260 tokens     27,501 tokens (29% of 96K)
            5                    2,100 tokens     45,835 tokens (48% of 96K)
           10                    4,200 tokens     91,670 tokens (96% of 96K)
           15                    6,300 tokens    137,505 tokens (OVERFLOWS 96K)
```

At the original 42.8x anchor ratio the webfetch path overflows 96K
at ~7 calls instead of ~10. Either way, a typical agentic coding
session does 5-15 research lookups -- well into overflow territory
without Library. **The Library is what makes the long-context model
practically usable for agentic research.**

The 2026-05-05 session itself is a worked example: 15 research calls
through Library spent 6,439 tokens (6.7% of the 96K window). The
same calls via webfetch would have spent 137,505 tokens at the
conservative ratio or 208,605 at the anchor ratio -- either way,
impossible. **That's a 95.3-96.9% reduction in context cost on a
real session, not a synthetic benchmark.**

## What makes this stack different

Not a single new technique. The differentiator is the *combination* and
the discipline:

- **Public references describe how to run a single model fast.** This
  describes how to run a complete agentic system over a frontier model
  on consumer hardware.
- **Three-tier compute hierarchy** (stateful 24 GB GPU + stateless 8 GB
  GPU + CPU sidecars), enforced by routing work to the cheapest tier
  capable of doing it.
- **Stateful/stateless separation** at the architecture level: the
  primary GPU is reserved for the one workload only it can do
  (token-by-token generation through an 80B-param MoE), and never
  asked to do CPU-shaped work like reading raw HTML.
- **The Library MCP as a type-conversion boundary**: stateless work
  becomes compressed payloads before crossing into the agent's
  accumulating state.
- **Router-mode primary with `/models` slash-command swap UX.** A
  single llama-server (mainline router mode, PR #16653) hosts a
  four-model pool -- Qwen3-Next-80B-Thinking (frontier reasoning,
  default for hard tasks, 96K ctx), Qwen3-Next-80B-Instruct (non-
  thinking sibling for agent loops where reasoning traces are
  noise), Qwen3-Coder-30B (coding specialist), GLM-4.7-Flash (fast
  generalist) -- on the same port, loading on demand. The swap UX
  lives entirely in the chat panel: type `/models` to list
  available models, `/models <id>` to raise a confirmation card
  showing target description and resource check, click Allow to
  stream `[swap] still loading (Ns)` heartbeats into a foldable
  terminal block, and a final `✓ <id> loaded (Ns)` bookend. ~30 s
  for the GPU-resident models, ~3-4 min for the MoE-offload ones.
  Works identically for local users at the workstation and for
  remote users over SSH+ACP. See
  [`2026-05-03-router-mode-swap-implementation.md`](2026-05-03-router-mode-swap-implementation.md)
  and the v3 design at
  [`../superpowers/specs/2026-05-04-models-slash-command-design.md`](../superpowers/specs/2026-05-04-models-slash-command-design.md).
- **Launcher-time model discovery (fix-9).** opencode's session
  starts with the model that's actually loaded on the router, not
  a hardcoded default. The launcher queries `/models`, patches the
  rendered `opencode.json`'s top-level `"model"` field plus the
  follower `agent.compaction.model`, then exec's opencode. If
  nothing is loaded, GLM-4.7-Flash is loaded first (35 s cold
  start) and the patch points to it. Removes the "what model is
  this session using?" disagreement between the picker UI and the
  router. See Phase 12 of the build history.
- **Polished thinking-mode rendering (Phase 13).** The thinking
  variant runs `reasoning-format = deepseek` plus
  `reasoning-budget = 4096`, which makes llama.cpp split the
  response into `content` (the answer) and `reasoning_content`
  (the thinking trace) and forces a `</think>` close after 4096
  thinking tokens. opencode's openai-compatible adapter renders
  the result as a foldable Thinking pill in Zed -- same shape
  that GLM produces -- without leaking `<think>` tags into chat
  or stalling on unbounded deliberation.
- **Persistent memory across sessions.** mnemory (port 8050) runs as
  a fifth systemd-managed service and ingests every chat turn. The
  next session starts with relevant memories pre-fetched into
  context. Multi-user via per-user API keys. Both extraction and
  embeddings use the existing 5700 XT sidecars; no new GPU load. See
  [`../../opencode-zed-patches/fix-7-shipped.md`](../../opencode-zed-patches/fix-7-shipped.md)
  for context.

The architecture predates this measurement run by months -- see
[`2026-05-03-from-one-model-to-an-agentic-stack.md`](2026-05-03-from-one-model-to-an-agentic-stack.md)
for the build history.

## Counterfactuals -- what breaks without each piece

| Remove | What happens |
|---|---|
| System-RAM expert offload | The 80B Qwen3-Next variants can't fit on 24 GB VRAM (45 GB of weights at Q4). Forces dropping the thinking model and falling back to GLM/Coder only -- loses frontier reasoning. |
| GPU acceleration entirely | Pure-CPU inference at DDR4-3200 bandwidth: ~5-8 tok/s on the smaller models, far worse on the MoE-offload ones. **2-3x slower** than measured. |
| 5700 XT (secondary GPU) | Lose edit predictions, embeddings, fast summarizer. The latency-sensitive workloads can't share a card with chat-shaped generation without queueing badly. Primary GPU shrinks to make room. |
| Library MCP | Webfetch path overflows the 96K context window after 7-10 calls (depending on source bloat). Long-context model becomes unusable for agentic research. |
| mnemory | Each session starts blind: the agent re-asks for preferences, constraints, project facts the user has already taught it. Cosmetic on day 1; corrosive over weeks. |
| `reasoning-format = deepseek` + `reasoning-budget = 4096` on the thinking model | One of two failure modes: `none` leaks raw `<think>` tags into the chat panel; deepseek-without-budget can stall on unbounded deliberation and return empty content. The pair is what makes the Thinking pill render cleanly and reliably. |
| Launcher-time model discovery | Opening Zed when a different pool member is loaded sends prompts to the wrong model and gets HTTP 400 "model is not loaded". The picker UI silently disagrees with the router. |
| MoE-with-low-active-params shape (Qwen3-Next-80B / 3B active) | Out of options at this hardware tier. Dense 70B doesn't fit on 24 GB; full GLM-4.6/4.7 (357B) and Qwen3-Coder-480B don't fit in 88 GiB total even at IQ3. The MoE-offload-to-DRAM trick is what makes frontier-class fit on 24+64. |

## Methodology notes

- All performance numbers from one live Zed coding session, not synthetic
  bench. Session log preserved at the path above.
- Token counts use `chars / 4` heuristic; English text typically 3.5-4.5
  chars/token, so estimates are within ~10%.
- Webfetch counterfactual: source URLs from each Library call fetched
  directly via Python `urllib`, HTML stripped via regex (not a full
  readability extractor, so estimate is conservative -- a real
  readability tool would return slightly less text per source).
- The published compaction ratio is a range, not a single point: 22x
  (2026-05-05, two-query average across a WhatsApp-Web research funnel)
  to 43x (2026-05-02, original anchor). Ratio depends on per-source
  bloat for the topic at hand. Both measurements use identical
  methodology -- see
  [`scripts/library_counterfactual_fetch.py`](scripts/library_counterfactual_fetch.py)
  for a reproducible run.
- One source per query failed with HTTP 403 (zork.fandom.com bot
  detection) on the original anchor run; one source on the 2026-05-05
  run was a JS-rendered SPA where regex extraction caught almost
  nothing. Both failures pull the ratio *down*, so the published
  numbers are a lower bound.

## Repository

`https://github.com/JoshWrites/2gpu-local-ai-workstation`

The router-mode + UX work landed on `main` on 2026-05-03 via the
`oss-tuning` branch (which itself fast-forwarded `router-mode-swap`).

Detailed build/design history:
[`2026-05-03-from-one-model-to-an-agentic-stack.md`](2026-05-03-from-one-model-to-an-agentic-stack.md)
-- in particular Phase 8-9 for the router-mode UX days (2026-05-03/04),
Phase 10 for the mnemory tier (2026-05-04), Phase 11-12 for the pool
swap dropping GPT-OSS-120B and adding the Qwen3 family (2026-05-04/05),
and Phase 13 for the thinking-mode rendering fix (2026-05-05).

Implementation notes for the swap UX, separate research note:
[`2026-05-03-router-mode-swap-implementation.md`](2026-05-03-router-mode-swap-implementation.md).
