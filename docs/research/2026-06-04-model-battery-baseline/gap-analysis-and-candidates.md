# Gap analysis + candidate models (researched 2026-06-05)

Builds on `pool-assessment.md` and `cross-pool-guide.md`. Goal: identify
models that fill the pool's real gaps AND fit the hardware, favoring
**GPU-only** fits (no DRAM offload) where that won't hurt quality.

Hardware envelope: 7900 XTX **24 GB** (primary, one chat model at a time
via the router) + 5700 XT **8 GB** (secondary, currently the summarizer/
embed/coder sidecars). llama.cpp HIP, ROCm 7.2.1, build b9518.

> **Source-confidence caveat.** The candidate models below are very recent
> (Apr-May 2026) and the data is from secondary sources (vendor docs,
> aggregator blogs), not first-party benchmarks run here. Treat the
> rankings as directional; **verify by loading + running our battery
> before adopting.** VRAM figures are weights-only at Q4_K_M; add KV cache
> + compute buffer (roughly +2-5 GB at long context).

## The gaps (from pool-assessment)

1. **A functional agentic coder** — GLM-4.7-Flash currently carries this,
   but it degrades past ~30K context and the dedicated coder we had
   (Qwen3-Coder-30B) was removed because its XML tool calls don't parse.
2. **A small always-warm model** on the 5700 XT for instant trivial turns
   + to cover the 80B cold-load dead-air.
3. **Dedicated document/OCR vision** — only if number/form extraction
   becomes a real workflow (gemma covers casual vision but misreads digits).

---

## Gap 1: agentic coder (highest value)

### Candidate A — Qwen3.6-27B (dense) [RECOMMENDED to trial]
- **Fit:** ~18 GB weights at Q4_K_M on 24 GB. GPU-only, but headroom is
  tight — at 64K context + KV it's close to the ceiling; may need a
  smaller quant (Q4_K_S) or reduced context for comfort. **Fits GPU-only
  at modest context; verify KV headroom.**
- **Why it fits the gap:** current-generation (Apr 2026), **standard JSON
  tool calling** (not the XML that broke our old coder), unsloth docs note
  active llama.cpp tool-parse improvements + "Developer Role Support for
  Codex/OpenCode". SWE-bench Pro ~53.5%. 262K native context. Dense =
  no MoE-offload, predictable.
- **Risk:** tight VRAM at long context; recency means tool-parsing
  reliability on OUR build must be verified (this is exactly the failure
  we hit before — do NOT assume).

### Candidate B — Qwen3-Coder-Next [trial as the "retest the coder" path]
- Newer Qwen coder; community + unsloth report **recent llama.cpp fixes
  to its tool-call parsing** ("update llama.cpp for better outputs"). Our
  build is current, so the exact bug that killed Qwen3-Coder-30B may now
  be fixed in this variant.
- **Action:** cheapest high-value experiment — download, load, run the
  raw `/v1/chat/completions` tool-call test. If `tool_calls` parses, this
  is the natural coder slot and we keep a Qwen coder after all.

### Candidate C — stay on GLM-4.7-Flash (no new model)
- It already works (tools parse, SWE-bench ~59% per earlier research) and
  fits comfortably (~10 GB). The only real weakness is context
  degradation past ~30K. **If you don't do long-context coding sessions,
  there is arguably no coder gap to fill** — GLM is enough.
- The full **GLM-4.7** (non-Flash) scores higher (SWE-bench 73.8%, tau2
  84.7) but is far larger; would need MoE offload like the 80Bs — against
  the GPU-only preference.

**Recommendation for gap 1:** trial **Qwen3-Coder-Next first** (it's the
direct "is the coder fixed now" test and costs only a download), then
**Qwen3.6-27B dense** as the generalist-coder fallback. If neither parses
tools cleanly on our build, **GLM-4.7-Flash remains the answer** and the
gap is effectively closed already.

---

## Gap 2: small always-warm model (5700 XT, 8 GB)

**Honest finding that changes the framing:** current research is
consistent that **3-4B models emit malformed tool calls past trivial
single-step tasks** (Llama 3.2 3B explicitly; the reliable floor for
agentic tool use is ~8B+). So a small always-warm model should be scoped
to **triage / classification / quick factual chat / routing**, NOT
agentic tool work. Within that scope:

- **Qwen3 4B (Instruct)** — fits ~3-4 GB on the 8 GB card, good
  instruction-following, same family as our stack. Best general small pick.
- **Phi-4-mini (3.8B)** — ~3.5 GB at Q4_K_M, strong instruction-following
  (MMLU ~68.5), good for structured/triage.
- **We already have qwen2.5-coder-3b** on the 5700 XT (the Zed edit-
  prediction sidecar). A general 4B would be a *second* small model and
  the 8 GB card already hosts summarizer + embed + coder sidecars —
  **check the VRAM budget on the 5700 XT before adding anything.**

**Recommendation for gap 2:** lower priority than it first seemed. Only
worth it if the 80B cold-load dead-air is a real daily annoyance. If so,
**Qwen3 4B Instruct** pinned on the 5700 XT for instant trivial turns —
but first confirm the 8 GB card has room alongside the existing sidecars,
and scope it to non-agentic quick tasks.

---

## Gap 3: document/OCR vision (situational)

Only pursue if invoice/form/number extraction becomes a workflow (e.g.
the Hebrew PDFs in ~/Documents). gemma's vision is fine for casual
"what's in this image" but misreads precise digits.

- **PaddleOCR-VL (0.9B)** — purpose-built doc OCR (text, tables,
  formulas, charts), OmniDocBench 92.6, runs even on CPU. Tiny. Best if
  the need is structured document extraction specifically.
- **DeepSeek-VL2** (4.5B active MoE) — strong OCR + table/document
  understanding, more general than PaddleOCR-VL.
- Both are separate tools/models, not a drop-in router member (PaddleOCR-
  VL especially is an OCR engine, not a chat model). Would run as a
  sidecar or via Library's docling path.

**Recommendation for gap 3:** defer. gemma covers casual vision. If doc
extraction becomes real, **PaddleOCR-VL** as a CPU/secondary-card sidecar
is the lightweight, accurate choice — and it complements (doesn't replace)
gemma.

---

## Bottom line (ranked actions)

1. **Trial Qwen3-Coder-Next** — one download + a raw tool-call test tells
   us whether the coder gap is already solved by recent llama.cpp fixes.
   Highest value, lowest cost.
2. **If that fails, trial Qwen3.6-27B dense** as a GPU-only generalist
   coder (mind the tight VRAM at long context).
3. **Otherwise, accept GLM-4.7-Flash** as the coder — the gap may already
   be closed for non-long-context work.
4. **Optional: Qwen3 4B on the 5700 XT** for instant trivial turns — only
   if cold-load dead-air bothers you and the 8 GB card has room.
5. **Defer doc-OCR** (PaddleOCR-VL) until a real extraction workflow
   appears.

Everything else (hard reasoning, multilingual, general knowledge, long
context, casual vision) is already covered — adding there is redundancy.
GPU-only preference is honored: Qwen3-Coder-Next and Qwen3.6-27B target
the 24 GB card without offload; the small model targets the 8 GB card;
only the full GLM-4.7 / our existing 80Bs use DRAM offload (and those are
the deliberate exceptions for frontier scale).
