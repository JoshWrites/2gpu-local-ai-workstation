# Model battery — baseline round 1 (2026-06-04)

Hardware: 7900 XTX 24GB (primary) + 5700 XT 8GB (secondary, Library
backing services). All models run with their current per-model prompts
via real `opencode run` (real Library MCP tool path).

## Speed (wall-clock seconds per task, via opencode incl. tool round-trips)

| task | gemma | glm | coder | 80b-inst | 80b-think |
|------|------:|----:|------:|---------:|----------:|
| 01 hebrew      |  2.2 | 28.9 | 14.2 | 41.2 | 174.5 |
| 02 multiling   |  3.3 |  4.9 |  2.4 |  4.9 |  41.0 |
| 03 code-gen    |  7.2 |  7.6 | (n/a*)| 8.8 |  45.9 |
| 04 code-debug  |  2.2 |  4.9 |  3.5 |  4.5 |  22.8 |
| 05 math        |  2.5 |  6.3 |  2.8 |  4.8 |  17.9 |
| 06 logic       |  3.8 |  6.5 | 65.3 |  6.7 |  52.3 |
| 07 knowledge   |  8.3 |  4.5 |  2.9 |  5.0 |  47.0 |
| 08 trivial     |  1.8 |  4.3 |  1.7 |  3.6 |  23.2 |
| 09 tool-rsrch  | 45.6 | 53.0 | 55.4 | 31.3 |  80.6 |
| 10 tool-file   |  8.9 | 15.6 |  8.4 | 13.3 |  66.4 |
| 11 format      |  2.1 |  4.3 |  1.9 |  4.3 |  42.7 |
| 12 summarize   |  2.8 |  6.1 |  2.6 |  5.9 |  15.0 |

*coder task 03 first run was rejected (tried to write a file); re-run
with tool-forbidding prompt produced the best code in the pool.

Speed tiers: gemma/coder fastest, glm mid, 80b-instruct slower,
80b-thinking slowest by far (thinking tax + DRAM offload).

## Quality / correctness (rubric: pass / partial / fail)

| task | gemma | glm | coder | 80b-inst | 80b-think |
|------|-------|-----|-------|----------|-----------|
| 01 hebrew (RTL) | PASS (cleanest) | PASS | PARTIAL (truncated word "גרפי") | PASS | PARTIAL (dropped connective) |
| 02 multiling | PASS | PASS | PASS | PASS | PASS |
| 03 code-gen | PASS | PASS | PASS* (best structure) | PASS | PASS |
| 04 code-debug | PASS | PASS | PASS | PASS | PASS |
| 05 math (=3min) | PASS | PASS | PASS | PASS | PASS |
| 06 logic (=son) | PASS | PASS | PASS | PASS (clearest) | PASS |
| 07 knowledge | PASS | PASS | PASS | PASS | PASS |
| 08 trivial (Canberra) | PASS | PASS | PASS | PASS | PASS + self-route |
| 09 tool-research | PASS | PASS (best synth) | PARTIAL (gave up) | PASS | PARTIAL (said flag absent) |
| 10 tool-file (=deepseek) | PASS | PASS | FAIL (narrated, no call) | PASS | PASS (richest) |
| 11 format JSON | PASS | PASS | PASS | PASS | PASS |
| 12 summarize | PASS | PASS | PASS | PASS | PASS |

## Headline findings

- **Reasoning/logic/math/format/knowledge: ALL FIVE pass.** The easy +
  medium baseline is uniformly strong; differentiation is at the edges.
- **Multilingual:** gemma cleanest (as designed); 80b-instruct also very
  good; coder + thinking show minor RTL degradation. GLM did Hebrew fine
  DESPITE its card claiming English/Chinese only (real > reported).
- **Coding:** coder produces the best code (deque sliding-window
  rate-limiter, @wraps) — BUT only once tools were forbidden. Its default
  agentic instinct is to WRITE A FILE, which the non-interactive harness
  rejected (test artifact, now understood).
- **Tool use — the real differentiator:**
  - gemma / glm / 80b-instruct: clean, correct tool calls + good result
    handling. 80b-instruct is the most efficient tool user (fastest tool
    tasks, confident synthesis) — matches its "RAG/agent orchestration"
    reputation.
  - 80b-thinking: correct calls, RICHEST result interpretation (task 10),
    but slowest.
  - **coder: weakest tool discipline** — over-acted on task 03 (wrote a
    file unprompted), UNDER-acted on task 10 (narrated "I need to read
    this file" but never emitted the call). This is the clearest
    prompt-improvement target.
- **Self-routing (layer 3) works:** 80b-thinking spontaneously suggested
  switching to gemma for a trivial lookup (task 08), unprompted.
