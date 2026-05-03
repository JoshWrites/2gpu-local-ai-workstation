# GPT-OSS-120B autofit A/B — autofit lost decisively

**Date:** 2026-05-03
**Branch:** `oss-tuning`
**Outcome:** keep the hand-tuned `--n-cpu-moe 28` baseline. Do not promote `--fit on`. Don't rerun this experiment without new evidence.

## Why we tested

The current production preset for gpt-oss-120b in
`configs/workstation/llama-router.ini` was hand-tuned in early May 2026
on the 7900 XTX (24 GB VRAM + 64 GB DRAM): `--n-cpu-moe 28`,
`--n-gpu-layers 999`, `-c 131072`, `-fa on`, `-ctk q8_0 -ctv q8_0`,
`-b 2048 -ub 2048`. It runs at ~19-20 tok/s gen, ~476 tok/s cold
prompt-eval at 43K tokens, 99% cache hit on continuation.

llama.cpp's auto-fit landed in
[PR #16653 (2025-12-15)](https://github.com/ggml-org/llama.cpp/pull/16653)
**after** the original tuning was done. Auto-fit probes free VRAM at
load time and computes per-tensor placement (including expert offload
to CPU for MoE models). The hypothesis was that auto-fit might find a
smarter split now that per-tensor placement is allowed. Cited
authority: the
[Doctor-Shotgun MoE offload guide](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide)
shows what auto-fit produces for 120B-class MoE models.

## Setup

Added a parallel preset `[gpt-oss-120b-autofit]` to
`llama-router.ini` -- same weights, same KV/FA/sampler -- but with
`fit = on`, `fit-ctx = 131072`, `fit-target = 1024` and *no*
`n-gpu-layers` or `n-cpu-moe`. (Auto-fit silently disables itself if
either of those is set.)

Bench harness `bench/oss-tuning.sh` swapped between the two presets
via `/models/load` on the router, ran a fixed 80-token short prompt
3× per preset with a 50-token warmup first. Long-prompt rows in the
CSV failed with "exceeds context" (prompt was 132K, ctx 131K) -- a
harness bug -- so this writeup uses short-prompt data only. The
short-prompt result was lopsided enough to settle the question.

Raw CSV: `bench/results/oss-tuning-20260503-193249.csv`.

## Results

### Generation throughput (short prompt, 256 tokens)

| Run | gpt-oss-120b (baseline) | gpt-oss-120b-autofit |
|---:|---:|---:|
| 1 | 19.29 tok/s | 8.73 tok/s |
| 2 | 20.03 tok/s | **1.80 tok/s** |
| 3 | 19.93 tok/s | 6.19 tok/s |
| **mean** | **19.75 tok/s** | **5.57 tok/s** |
| **stddev** | 0.40 | 3.51 |

Baseline is **3.5× faster on average and stable run-to-run.** Autofit
is not just slower; it is *erratic*. Run 2 dropped to 1.80 tok/s --
generation effectively unusable.

### Load behaviour

| | Cold load time | VRAM peak | Headroom |
|---|---:|---:|---:|
| baseline | 2:42 (162 s) | 20.3 GB | 3.7 GB |
| autofit  | 7:35 (455 s) | **24.3 GB** | ~0 GB |

Autofit took 2.8× longer to load and pushed VRAM essentially to the
24 GB ceiling. The "more layers on GPU is faster" intuition is wrong
on this hardware: leaving room for the KV cache and compute scratch
matters more than maximising weight residency.

### Why we think autofit lost

- **No headroom for KV growth.** Auto-fit packed weights aggressively;
  nothing left for the runtime KV/compute buffers. Steady-state work
  contended for VRAM and probably spilled to host.
- **Suboptimal expert placement.** `--n-cpu-moe N` cuts at the layer
  boundary -- consistent, predictable. Auto-fit may have placed
  individual expert tensors in ways that hurt the HIP backend's batch
  fusion. Variance run-to-run (1.80 → 8.73 tok/s) supports this:
  different cache states, different tensor-route fast-paths.
- **HIP-specific.** Auto-fit was designed and validated primarily on
  CUDA. ROCm 7.2.1 on gfx1100 has known recent perf regressions
  ([llama.cpp #17917](https://github.com/ggml-org/llama.cpp/issues/17917))
  and the symmetric-KV-quant requirement for fused FA
  ([#22411](https://github.com/ggml-org/llama.cpp/discussions/22411))
  is the kind of detail auto-fit's planner may not weight correctly.

## Decision

Reverted: `[gpt-oss-120b-autofit]` deleted from
`configs/workstation/llama-router.ini`, registry entry deleted from
`configs/workstation/primary-pool.json`. Production preset for
gpt-oss-120b stays as it was at the start of branch `oss-tuning`.

The bench harness `bench/oss-tuning.sh` and prompt fixtures are kept
in tree -- they're the right shape to A/B any future preset change
on this model. The CSV is committed under `bench/results/` so this
result doesn't have to be rediscovered.

## When to revisit

- New llama.cpp release with documented MoE-on-HIP auto-fit improvements
- New hardware (more VRAM than 24 GB → auto-fit's "fit more on GPU"
  heuristic might actually win)
- Changing the model (auto-fit's per-tensor routing might handle
  different MoE shapes better)
- Updating ROCm past the gfx1100 regression in #17917

Without one of those, this is a settled question. The 19-20 tok/s gen
+ 99% cache-hit follow-ups already meet our use case; the one published
24 GB consumer-card reference number for this model
([The Register, Aug 2025](https://www.theregister.com/2025/08/24/llama_cpp_hands_on/))
was ~20 tok/s on a 20 GB card -- we're at parity or above.

## Harness bug noted for future runs

`bench/oss-tuning.sh` generates a "long-needle" prompt that came out
to 132,107 tokens versus a 131,072 ctx-size. All long-cold and
long-warm rows in the CSV are HTTP 400. Fix on next reuse: drop
`total_blocks` from 3300 to ~3000 in the python generator block.
Not fixed in this commit because the short-prompt result settled the
question without needing the long-prompt data.
