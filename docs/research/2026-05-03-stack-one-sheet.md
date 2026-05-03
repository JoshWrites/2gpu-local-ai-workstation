# 2GPU Local AI Workstation -- One Sheet

**Date:** 2026-05-03
**Hardware:** Ryzen 9 5950X, 64 GB DDR4-3200, RX 7900 XTX (24 GB, gfx1100),
RX 5700 XT (8 GB, gfx1010), Ubuntu 24.04, kernel 6.17

A single-machine local agentic coding stack that runs a frontier-class
116-billion-parameter model with full 128K context, alongside three
supporting models and a Library MCP, on consumer AMD hardware. No
cloud dependency, no datacenter GPU, no rental cost beyond electricity.

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
|  GPT-OSS-120B (116.83B params, MXFP4, 128K context)          |
|    weights on GPU:    14.5 GB (attention + output)           |
|    weights on DRAM:   45.9 GB (28 of 36 layers' MoE experts) |
|    KV cache (Q8_0):    2.5 GB                                |
|    compute buffer:     1.8 GB                                |
|    SWA checkpoints:    3.0 GB (DRAM, 64 slots)               |
|                                                              |
|  Single accumulating conversation, tuned for amortized cost  |
|  across multi-hour sessions, not peak benchmark throughput.  |
+--------------------------------------------------------------+
              ^                     |
              | tool calls          | summaries (~325 tokens
              |                     |  per research call)
              |                     v
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
|    HTML extraction, chunking, ranking (in Library)           |
|                                                              |
|  Each task pure: same input -> same output, no shared state. |
+--------------------------------------------------------------+
              ^                     |
              | calls               | summarized payloads
              |                     |
+--------------------------------------------------------------+
|  LIBRARY MCP -- the boundary between tiers                   |
|                                                              |
|  Receives stateless calls (research, read_file, convert,     |
|  export, context_usage), fans out to stateless workers,      |
|  compresses output before returning to the stateful agent.   |
|  Without it, raw research output overflows the 128K window   |
|  after ~10 webfetches.                                       |
+--------------------------------------------------------------+
```

## Effective parameter capacity served simultaneously

| Role | Model | Params | Lives on |
|---|---|---:|---|
| Primary chat / agent | GPT-OSS-120B | 116.83 B | 7900 XTX + DRAM |
| Summarizer | Qwen3-4B Instruct | 4.0 B | 5700 XT |
| Embeddings | multilingual-e5-large | 0.56 B | 5700 XT |
| Edit predictions | Qwen2.5-Coder-3B | 3.0 B | 5700 XT |
| **Total** | | **~124 B** | |

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

**Anchor measurement, single research call:** 5 source URLs actually
re-fetched and HTML-stripped to byte counts.

| | Library | Webfetch counterfactual |
|---|---:|---:|
| Tokens returned to model | 325 | 13,907 |
| Compaction ratio | -- | **42.8x** |

**Session totals (3 research calls, full counterfactual extrapolation):**

| | Library | Webfetch counterfactual |
|---|---:|---:|
| Total tokens | 1,126 | 41,721 |
| Fraction of 128K window | 0.9% | 31.8% |

### Why the Library is load-bearing, not optional

```
Research calls per session   Library cost     Webfetch cost
---------------------------- ---------------- -----------------
            3                    1,126 tokens     41,721 tokens (32% of 128K)
            5                    1,875 tokens     69,535 tokens (53% of 128K)
           10                    3,750 tokens    139,070 tokens (OVERFLOWS 128K)
           15                    5,625 tokens    208,605 tokens (OVERFLOWS 128K)
```

A typical agentic coding session does 5-15 research lookups. **At 10
lookups, the webfetch path overflows the rated 128K context window.**
The Library is what makes the long-context model practically usable for
agentic research.

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
  (token-by-token generation through a 116B-param model), and never
  asked to do CPU-shaped work like reading raw HTML.
- **The Library MCP as a type-conversion boundary**: stateless work
  becomes compressed payloads before crossing into the agent's
  accumulating state.
- **Router-mode primary with on-demand swap UX.** A single
  llama-server (mainline router mode, PR #16653) hosts both GLM-4.7
  -Flash (fast default) and GPT-OSS-120B (heavy reasoning) on the
  same port, loading on demand. Picking a not-loaded model in Zed's
  footer triggers a yad confirm dialog, a progress popup, and the
  swap completes in ~35 s for GLM or ~4 min for OSS before the
  message goes through. The mechanic is mainline llama.cpp; the UX
  layer is a 5th opencode patch plus `scripts/model-swap.sh`. See
  [`2026-05-03-router-mode-swap-implementation.md`](2026-05-03-router-mode-swap-implementation.md).

The architecture predates this measurement run by months -- see
[`2026-05-03-from-one-model-to-an-agentic-stack.md`](2026-05-03-from-one-model-to-an-agentic-stack.md)
for the build history.

## Counterfactuals -- what breaks without each piece

| Remove | What happens |
|---|---|
| System-RAM expert offload | 116B model can't fit on 24 GB VRAM. Forces Q2_K (quality cliff) or layer dropping (broken). |
| GPU acceleration entirely | Pure-CPU inference at DDR4-3200 bandwidth: ~5-8 tok/s. **2-3x slower** than measured. |
| 5700 XT (secondary GPU) | Lose edit predictions, embeddings, fast summarizer. The latency-sensitive workloads can't share a card with chat-shaped generation without queueing badly. Primary GPU shrinks to make room. |
| Library MCP | Webfetch path overflows 128K window after ~10 calls. Long-context model becomes unusable for agentic research. |
| `--alias gpt-oss-120b` flag | opencode pattern-matches model id to enable Harmony / tool attachment. Without it, model emits code in chat instead of tool calls. |

## Methodology notes

- All performance numbers from one live Zed coding session, not synthetic
  bench. Session log preserved at the path above.
- Token counts use `chars / 4` heuristic; English text typically 3.5-4.5
  chars/token, so estimates are within ~10%.
- Webfetch counterfactual: 5 source URLs from one Library call were
  fetched directly via Python `urllib`, HTML stripped via regex (not a
  full readability extractor, so estimate is conservative -- a real
  readability tool would return slightly less text per source).
- One source per query failed with HTTP 403 (zork.fandom.com bot
  detection); savings ratio is conservative because of those failures.

## Repository

`https://github.com/JoshWrites/2gpu-local-ai-workstation`

The router-mode + UX work landed on `main` on 2026-05-03 via the
`oss-tuning` branch (which itself fast-forwarded `router-mode-swap`).

Detailed build/design history:
[`2026-05-03-from-one-model-to-an-agentic-stack.md`](2026-05-03-from-one-model-to-an-agentic-stack.md)
-- in particular Phase 8 for the router-mode UX day (2026-05-03).

Implementation notes for the swap UX, separate research note:
[`2026-05-03-router-mode-swap-implementation.md`](2026-05-03-router-mode-swap-implementation.md).
