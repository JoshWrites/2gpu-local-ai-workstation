# Did the iterative per-model prompts beat baseline? (2026-06-04)

Compares the refined per-model prompts (commits `0409e15`, `afa37aa`,
`1890eff`, `8510fc3`, `fa9ede8`) against the round-1 baseline in
`findings.md`. Evaluated on the same real-`opencode` + real-Library path.

## Short answer

Yes — but unevenly, and the wins are concentrated. The baseline already
passed the reasoning/math/logic/knowledge/format core uniformly, so there
was no headroom there and nothing changed (correctly — we did not touch
what worked). The improvements landed exactly where the baseline found
weakness: **tool discipline, research honesty, latency on routine tool
tasks, and self-positioning.** One target (coder agentic editing) turned
out to be a build-level bug a prompt cannot fix.

## Per-model: before -> after

### qwen3-coder-30b — tool discipline (partial win + bug found)
- BEFORE: over-acted (called `write` when asked to "write a function" ->
  rejected -> empty output); under-acted (narrated "I need to read this
  file" without emitting the call).
- AFTER: inline-by-default verified (code returns in the reply, no file
  write); call-don't-narrate verified (now emits `library_read_file` and
  answers). 
- CAVEAT: full agentic file-editing is still blocked by a llama.cpp
  build bug (Qwen3-Coder XML tool format not parsed -> `tool_calls` empty;
  see repo-issues.md). The prompt fix is real but the headline strength
  remains gated on a rebuild. Verdict: **improved where a prompt can
  reach; core strength still blocked downstream.**

### gemma-4-12b — research honesty (win, smaller need than feared)
- BEFORE: one observed case of confident synthesis on a thin research
  result.
- AFTER: on a genuinely nonexistent flag it escalates (3 reworded
  searches) then honestly reports the sources lack it — no invented
  value. On a real question it correctly reports the SOURCED value.
- NUANCE: re-testing showed the baseline's single "fabrication" was
  partly a flawed test (the value was actually in the sources). gemma
  needed less correction than the baseline implied — but the rule is now
  explicit and, crucially, **applies to all models** via
  shared-environment.md, which is the larger win.
- Core strengths (modulation, multilingual, self-route judgment) intact.
  Verdict: **improved + generalized to the whole pool.**

### glm-4.7-flash — repositioning (clear win, no metric regression)
- BEFORE: framed as generic "fast default", told to defer ALL coding to
  the coder.
- AFTER: identifies its strength as "fast coding and multi-step agentic
  tool use"; does not refuse multilingual; routes deep reasoning away.
- This is the highest-leverage *conceptual* change: GLM's tool calls
  PARSE on this build (the coder's do not), its code is good
  (thread-safe), and it benchmarks higher on coding than the prompt
  previously admitted. Verdict: **the prompt now matches reality instead
  of fighting it.**

### qwen3-next-80b-thinking — tool-result discipline (BIGGEST measured win)
- BEFORE: routine file-read-and-report took **138s** and embellished the
  answer with wrong memory-sourced details (claimed n-gpu-layers=100 /
  cache-type=fp16; actual 99 / q8_0).
- AFTER: same task **79s** (-43% wall time) and terse/accurate — just the
  value, no invented detail. Hard reasoning fully preserved (pirates
  98-0-1-0-1 and 12-balls/3-weighings both correct).
- Verdict: **the only large, cleanly-quantified improvement** — a 43%
  latency cut on routine tool work plus a correctness fix (no fabricated
  specifics), with zero loss on the reasoning that justifies the model.

### qwen3-next-80b-instruct — positioning + terseness (win)
- BEFORE: defined by negation ("the non-thinking sibling"); mild answer
  padding.
- AFTER: leads with its real edge (best tool/RAG/orchestration over stable
  long context); tool result now terse ("65536", no padding). Confirmed
  fastest tool user (~47s vs thinking's 79s).
  Verdict: **sharper identity + cleaner output.**

## What made the biggest difference

1. **The single highest-impact change: thinking-model tool-result
   discipline (-43% latency + correctness).** It is the only change with a
   hard before/after number, and it fixed two things at once (speed AND
   fabricated detail). Telling a thinking model "don't deliberate on
   routine tool results" is a high-leverage instruction.

2. **Runner-up by reach, not magnitude: the shared research-honesty
   rule.** It is qualitative, but it applies to all five models at once
   and addresses the failure mode Josh called load-bearing ("why research
   if you can't trust results"). One edit, pool-wide effect.

3. **Most strategically important: GLM repositioning.** No metric moved,
   but the prompt stopped misdescribing the model — it had been telling
   the best functional coding agent in the pool to defer all coding away.

## Honest limits of this evaluation
- Most "after" results are single-run spot-checks, not the full 12-task
  battery re-run per model (model-load cost). The thinking-model latency
  number is the most rigorous; the rest are behavioral confirmations.
- "Quality" is rubric/eyeball judged, not scored by an independent judge.
- The coder's headline capability and gemma vision are both blocked on a
  llama.cpp rebuild — prompts could not move them. The prompt layer did
  what a prompt layer can; the remaining gains are in the toolchain.

## Net
The iterative prompts improved the pool where prompts can improve it:
behavior, honesty, latency-on-routine-work, and self-positioning. They did
NOT (and could not) fix the two build-level blockers. Biggest single
difference: the thinking model's tool-result discipline. Biggest reach:
the shared honesty rule.
