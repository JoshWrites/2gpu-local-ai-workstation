# P0.2 — Vulkan vs ROCm benchmark

**Date:** 2026-04-16
**Hardware:** RX 7900 XTX (gfx1100), single card
**Model:** Qwen3-Coder-30B-A3B-Instruct Q4_K_M, ctx 65536, fa on, ctk/ctv q8_0
**Build:** llama.cpp `b8799` (same upstream tag, both backends)
**Method:** 1 warmup + 3 recorded warm runs per backend. Each run spins
up `llama-server`, issues one 4-token warmup request, then one
2048-token generation request (`ignore_eos=true`, `temperature=0`,
short prompt) and records server-reported `timings`.

Bench script: `scripts/bench-rocm-vs-vulkan.sh`.
Raw CSV: `bench-rocm-vs-vulkan.csv`.

## Results

| Metric               | ROCm (mean) | Vulkan (mean) | Winner         |
| -------------------- | ----------- | ------------- | -------------- |
| Startup to ready     | 3.81 s      | 5.11 s        | ROCm +1.3 s    |
| Prompt processing    | 391 tok/s   | 282 tok/s     | ROCm +39%      |
| **Generation**       | **82 tok/s**| **151 tok/s** | **Vulkan +84%**|

Run-to-run variance was tight on both backends (<1% on generation,
<2% on prompt).

## Interpretation

Generation speed dominates real chat/agent latency — the model spends
far more time predicting tokens than ingesting the prompt. Vulkan's
~2x lead on generation vastly outweighs ROCm's lead on prompt
processing and startup.

The community-review hypothesis ("Vulkan matches or beats ROCm on
gfx1100 for llama.cpp MoE inference in early 2026") is confirmed, and
the gap is larger than expected. The open ROCm pipeline bug on 7900
XTX cited in the community review is the plausible cause.

## Feature parity

Verified the Vulkan `b8799` binary supports every server flag Phase 1
and 2 rely on:

- `--flash-attn on`
- `-ctk q8_0`, `-ctv q8_0`
- `-cram` / `--cache-ram` (default 8192 MiB)
- `--slot-save-path`
- `--jinja`
- `-md` (draft model — needed for Phase 3 speculative decoding)

No known loss of capability.

## Decision

**Switch the primary-model launcher from ROCm to Vulkan.**

- `scripts/primary-llama-vulkan.sh` becomes the canonical launcher.
- `scripts/primary-llama.sh` (ROCm) retained as a fallback for
  driver-regression bisects.
- Systemd unit `llama-second-opinion.service` flipped to the Vulkan
  script.
- Branch `rocm-phase-1` tagged at the pre-switch commit so the old
  path is easy to restore.

## Caveats and follow-ups

- Only 3 recorded runs per backend. Tight variance gives confidence
  for a switch decision but isn't a stability bed test.
- No long-session observation (>30 min continuous). A VRAM leak or
  driver regression under load isn't ruled out. If a session feels
  slow or stalls, compare against `primary-llama.sh` as a fallback.
- Prompt-processing deficit (~28% slower on Vulkan) could matter at
  long-context *first-token* latency. Re-measure if we start hitting
  ≥32K prompts regularly.
- rocWMMA tunings no longer relevant (community-review already said
  they hurt gfx1100 anyway — non-issue).
