# Model battery — baseline round 1 (2026-06-04)

Baseline evaluation of all five primary-pool models, each run through the
same 12-task battery via real `opencode run` (real Library MCP tool path),
with each model's current per-model system prompt active. Captured before
any iterative prompt tuning, so later tuning passes have a fixed baseline.

## Files
- `findings.md` — speed + quality (pass/partial/fail) per task per model,
  and the headline findings.
- `coverage.md` — strength-coverage map across the pool and whether any
  capability gap exists that a runnable/on-disk model could fill.
- `prompt-recommendations.md` — ranked per-model prompt improvement
  targets for the overnight tuning pass.
- `strength-map.md` — reported strengths/weaknesses from model cards +
  web research that the battery was designed to probe.
- `run_battery.sh` — the exact harness used.
- `raw/<model>/` — every task's raw stdout (`.out`) and terminal trace
  (`.err`, includes tool-call lines) for audit.

## TL;DR
- All five models pass the reasoning/math/logic/knowledge/format baseline;
  differentiation is at the edges (multilingual, coding, tool use).
- gemma cleanest multilingual; coder best code (once tools forbidden);
  80b-instruct best/fastest tool user; 80b-thinking richest but slowest.
- The coder has the only real tool-discipline problem (over-acts on
  "write code" -> creates a file; under-acts on "read a file" ->
  narrates without calling). Highest-value prompt target.
- Only zero-coverage capability is VISION — closable by wiring gemma's
  mmproj, not by adding a model.
- Self-routing (suggest a better model) works, including spontaneously on
  the thinking model.
