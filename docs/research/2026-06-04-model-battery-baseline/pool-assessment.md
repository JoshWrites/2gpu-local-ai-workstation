# Pool assessment: per-model strengths/weaknesses + systemic gaps (2026-06-04)

Grounded in this session's testing on the actual hardware (7900 XTX 24GB
primary + 5700 XT 8GB secondary), llama.cpp HIP build b9518/7c158fb, real
opencode + real Library MCP. Speeds are measured, not spec-sheet.

## Per-model, as they actually behave on this box

### gemma-4-12b — the multilingual generalist + the only eyes
- **Strengths:** fastest (~50 tok/s), cleanest multilingual incl. Hebrew/
  RTL, modulates thinking to task difficulty (instant on trivia, reasons
  on hard), honest about thin research results, and — as of today — the
  ONLY model that can see images (reads text, color, layout from
  screenshots/photos in ~10s).
- **Weaknesses:** 12B knowledge ceiling; vision is general-VLM quality,
  not dedicated OCR (misreads small/low-contrast digits — flagged in its
  prompt); not a coding specialist.
- **Verdict:** the daily-driver default. Vision makes it uniquely
  valuable — nothing else in the pool replaces it.

### glm-4.7-flash — the fast coder/agent (now the de-facto coding model)
- **Strengths:** strong, often thread-safe code; tool calls PARSE on this
  build (so it can actually drive agentic edits); good general knowledge
  and common-language translation; SWE-bench ~59% (research). Fast.
- **Weaknesses:** real context degradation — quality drops past ~30K
  tokens, loops past ~50K; the new build now surfaces a reasoning channel
  (fine in opencode, but it can over-deliberate if unguided).
- **Verdict:** carries the functional coding-agent role the coder can't.

### qwen3-coder-30b — best raw code, but agentically crippled here
- **Strengths:** best inline code in the pool (clean structure, idioms);
  fast (fully GPU-resident).
- **Weaknesses (decisive):** its native `<function=>` XML tool calls are
  NOT parsed by this llama.cpp (upstream #15012 open) — so it CANNOT do
  agentic file edits, its entire reason for being. Prompt fixes made it
  reply inline correctly, but the headline capability is blocked.
- **Verdict:** currently redundant with GLM for anything agentic; only
  adds value as a pure inline-code generator, where GLM is nearly as good
  and also does tools. **Strongest redundancy candidate in the pool.**

### qwen3-next-80b-thinking — the deep reasoner
- **Strengths:** frontier reasoning (solved 5-pirates, 12-balls,
  irrationality proofs correctly); richest tool-result interpretation;
  most context-stable; self-routes simple work away unprompted.
- **Weaknesses:** slow (~25-35 tok/s + 80-200s loads via DRAM offload);
  over-deliberates routine tool work unless disciplined (we cut a file
  read 138s->79s via prompt).
- **Verdict:** earns its slot for hard problems; not for quick work.

### qwen3-next-80b-instruct — the tool/RAG/orchestration workhorse
- **Strengths:** fastest tool user (~47s vs thinking's 79s on the same
  task), clean trace-free output, stable over long context — ideal for
  agent loops and RAG.
- **Weaknesses:** slow to load; no surfaced reasoning (by design).
- **Verdict:** NOT redundant with its thinking sibling — a real
  speed/transparency trade; both earn slots.

## Redundancy call-out
- **qwen3-coder-30b vs glm-4.7-flash:** heavy overlap, and right now GLM
  wins (it can actually tool-call). Until upstream #15012 lands, the coder
  is the one model whose primary purpose is unmet and duplicated. Keep it
  only if you value its slightly-better inline code, or for when the fix
  lands; otherwise it is the drop candidate.
- The two 80B siblings are NOT redundant (verified).

## Systemic weaknesses a NEW model could bolster
Ranked by how much they'd actually improve the pool on this hardware:

1. **A working agentic CODER (highest value).** The biggest hole isn't a
   missing capability — it's that our coding specialist is non-functional
   for agentic edits. Options: (a) wait for llama.cpp #15012 + retest the
   existing coder; (b) adopt a strong coder whose tool format llama.cpp
   ALREADY parses cleanly (GLM proves the OpenAI/JSON-style path works
   here). A coder that uses standard JSON tool calls (not Qwen's XML)
   would slot in immediately. **This is the gap to close first.**

2. **A small, always-warm fast model for sub-second turns.** Everything on
   the 24GB card is >=12B and shares one slot (one model at a time via the
   router). There's no instant, always-resident helper for trivial
   chat/classify/routing while a big model is busy or loading (80B loads
   take 80-200s — dead air). A ~3-4B instruct model pinned on the 5700 XT
   (which already hosts the sidecars) could answer instantly and cover the
   cold-load gap. Hardware allows it; the secondary card has room.

3. **Stronger/dedicated OCR or document vision (situational).** gemma
   vision is good for understanding but misreads precise digits. If
   document/number extraction becomes a real workflow (invoices, forms,
   the Hebrew PDFs in ~/Documents), a dedicated doc-vision model would
   help. Lower priority — gemma covers casual vision now.

4. **NOT a gap: hard reasoning, multilingual, general knowledge, long
   context.** All well covered. Adding here is redundancy, not coverage.

## One-line recommendation
The pool's real systemic weakness is a *functional* agentic coder, not a
missing capability. Either wait for upstream llama.cpp to fix the existing
coder, or add a coder that uses standard JSON tool calls (which this stack
parses today). Second, consider a small always-warm model on the 5700 XT
to kill the cold-load dead-air and serve instant trivial turns.
