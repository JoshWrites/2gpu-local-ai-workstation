# GPT-OSS-120B MoE expert offload — experiment notes

**Final result (2026-05-02):** GPT-OSS-120B running at **native 128K
context** on the 7900 XTX (24 GB VRAM + 64 GB DRAM), with:
- 19-20 tok/s generation
- 476 tok/s cold prompt eval (43K-token prompts in ~95s)
- 99% cache hit on continued conversations (~13s follow-up on 43K context)
- Verified retrieval at depth (needle-in-haystack at 80% depth)
- ~21 GB peak VRAM, 3 GB headroom retained

The investigation walked through three failed paths before landing on
the working one. See sections below for the full log.

Reference: <https://www.theregister.com/2025/08/24/llama_cpp_hands_on/>
got ~20 tok/s on a 20GB GPU + 64GB DDR4 with `--n-cpu-moe 26`.

Model: `ggml-org/gpt-oss-120b-GGUF`, MXFP4 quant (~63GB total, 3 shards).
Stored at `/var/lib/llama-models/gpt-oss-120b/`.

## What worked

- **Mainline llama.cpp built with HIP** (ROCm 7.2.1, gfx1100), installed
  to `/usr/local/lib/llama.cpp-hip/` (separate from stock Vulkan at
  `/usr/local/lib/llama.cpp/`).
- `--n-cpu-moe 28`, `-c 8192`, `--flash-attn off`, `-b 2048 -ub 512`,
  `--no-mmap`, `HIP_VISIBLE_DEVICES=1` (which is the 7900 XTX in HIP's
  enumeration — note this is OPPOSITE of `rocminfo`'s ordering).
- VRAM: 17 GB resident on the 7900 XTX (14.5 GB weights + ~2.5 GB
  KV/compute). 24 GB ceiling has 7 GB headroom.
- DRAM: 47 GB RSS, ~46 GB host buffer for CPU-resident expert weights.
- Coexists fine with stock Vulkan llama-primary on the same physical
  card (different backends, different VRAM regions).

## What did NOT work and why

### Stock Vulkan llama.cpp + `--n-cpu-moe`
Stock llama.cpp Vulkan backend allocates a single host-visible Vulkan
buffer to hold all CPU-resident expert weights — for GPT-OSS-120B at
`--n-cpu-moe 28` that's 45.9 GB. RADV (Mesa Vulkan driver for AMD)
refuses the allocation:
```
radv/amdgpu: Not enough memory for command submission.
llama_model_load: error loading model: vk::Queue::submit: ErrorDeviceLost
```
This is a per-allocation/per-context limit in RADV, not a sizing/free-VRAM
issue. Failed identically across `--n-cpu-moe` values (26, 28), context
sizes (8K, 32K), and `--flash-attn` on/off.

### ik_llama.cpp HIP build
Bit-rotted under modern ROCm (7.2.1) — both tip-of-tree (`a8aecbf`) and
the GPT-OSS-introducing PR #689 (`633e0617`) fail to build:
- Missing `add_compile_definitions(GGML_CUDA_FUSION=...)` and
  `GGML_CUDA_MIN_BATCH_OFFLOAD=...` in the HIP CMake block (in tip)
- Undeclared `nv_bfloat16` — no HIP shim typedef in
  `ggml/src/ggml-cuda/vendors/hip.h` (both tip and #689)

Fixable but more engineering than the experiment warranted. Mainline
llama.cpp's HIP path is well-maintained and has the same `--n-cpu-moe`
flag we needed.

## Performance on first run (no tuning yet)

| Round | Prompt tok | Cached | Gen tok | Prompt tok/s | Gen tok/s |
|------:|-----------:|-------:|--------:|-------------:|----------:|
| 1 cold|         79 |      0 |     200 |        31.5  |     19.9  |
| 2 warm|         79 |     74 |     200 |        14.3  |     20.1  |
| 3 hot |         79 |     70 |     134 |        13.4  |     20.1  |

(Generation tok/s is the meaningful metric — prompt eval on rounds 2–3
only had 5–9 new tokens, so its per-token rate is misleading.)

## Tuning to 128K

We pushed straight to native 128K context with three changes from the
8K baseline:

- `-c 8192` → `-c 131072` (full `n_ctx_train`)
- `--flash-attn off` → `on`
- Added `-ctk q8_0 -ctv q8_0` (symmetric KV quantization)

The key insight is that **on AMD HIP, `-fa on` only enables the fast
fused FA kernel when KV is symmetrically quantized** (Discussion #22411).
The fused path eliminates intermediate scratch buffers, which is what
made 128K fit at all — the compute buffer dropped 6× (4474 MiB at 70K
FP16 → 741 MiB at 128K Q8 + FA).

The official guide warns Q8_0 KV "halves performance" on MXFP4-native
models. **That warning did not bite in our test.** The fused-FA speedup
appears to more than offset the Q8_0 KV cost on this hardware.

## --n-cpu-moe sweep at 128K

Tried `N=26` (one step down from N=28):
- Predicted +2.3 GB on GPU; actual +3.2 GB
- VRAM 19→22 GB, headroom 5→2 GB
- Gen tok/s: ~19.6 (vs 19.1 at N=28) — **within noise**

Conclusion: with top-4-of-128 expert routing, only ~3% of any layer's
experts activate per token. Pulling 2 layers' worth of experts to GPU
only eliminates PCIe round-trips for ~7% of expert computations. The
PCIe traffic per token is dominated by *which* experts get hit, not
aggregate weight counts. **`--n-cpu-moe` is too coarse to extract
meaningful speedup at this margin.** Rolled back to N=28 for headroom.

## The big speedup: -ub 2048 + cache-reuse + LLAMA_SET_ROWS

Three changes from the conservative starting config:
- `-ub 256` → `-ub 2048` (matched to `-b 2048`)
- Added `--cache-reuse 256` (KV-shifting prefix reuse)
- Added `LLAMA_SET_ROWS=1` env var (split-KV mode for MoE)

`-ub 256` was a holdover from when we ran without flash-attention and
needed a small ubatch to fit the compute buffer. Once FA-on shrunk the
compute buffer 6×, we had ~5 GB of headroom that was unused. Bumping
to `-ub 2048` filled it and lit up the GPU's actual throughput.

### Long-prompt results (43,194-token needle-in-haystack)

| Config | Wall time | Prompt eval | Gen tok/s | Needle? |
|---|---:|---:|---:|:---:|
| `-ub 256` (initial 128K config) | 437 s | 99.6 tok/s | 17.3 | yes |
| `-ub 2048` + cache-reuse + LLAMA_SET_ROWS | **95 s** | **476.2 tok/s** | 16.7 | yes |

**4.8× speedup on prompt evaluation** at 43K tokens. Needle retrieval
worked in both configs (the model correctly identified `QZX-7283-MAGENTA`
buried at 80% depth in 43K tokens of filler narrative).

### Continued-conversation results (compaction test)

Same 43K-token document + assistant's first reply + new follow-up
question:

| Metric | Value |
|---|---:|
| Total prompt | 43,304 tokens |
| Cache hit | 43,259 / 43,304 = **99.9%** |
| Newly evaluated | 45 tokens |
| Wall time | **12.6 s** |
| vs cold long-prompt | **7.5× faster** |

This is the agentic-tool-loop pattern: keep context stable, add to it,
and only pay for the new tokens. For Zed/opencode use where you keep
editing files and re-running, **the second turn is essentially free.**

### Final config

```
ExecStart=/usr/local/lib/llama.cpp-hip/llama-server \
  -m gpt-oss-120b/gpt-oss-120b-mxfp4-00001-of-00003.gguf \
  -ngl 999 --n-cpu-moe 28 \
  -c 131072 --flash-attn on \
  -ctk q8_0 -ctv q8_0 \
  --jinja \
  -b 2048 -ub 2048 \
  --cache-reuse 256 \
  --no-mmap \
  --temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.0 \
  --host 127.0.0.1 --port 11444

Environment="HIP_VISIBLE_DEVICES=1"
Environment="LLAMA_SET_ROWS=1"
```

**VRAM at peak:** 21 GB / 24 GB (3 GB headroom retained for safety).
**Steady-state generation:** 16-20 tok/s depending on context depth.
**Cold long-prompt prompt eval:** 476 tok/s.
**Compaction follow-up:** 99% cache hit, ~13s for 43K-token continuation.

## Setup

Service unit at `systemd/llama-primary-experiment.service`. Cannot coexist
with `llama-primary.service` — both want Vulkan0.

```
# Stop stock primary
sudo systemctl stop llama-primary

# Install + start experiment
sudo cp systemd/llama-primary-experiment.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start llama-primary-experiment

# Watch load
journalctl -u llama-primary-experiment -f
```

Reverse:
```
sudo systemctl stop llama-primary-experiment
sudo systemctl start llama-primary
# (optionally) sudo rm /etc/systemd/system/llama-primary-experiment.service
```

## --n-cpu-moe sweep procedure

Start at the article's value (26) since the 7900 XTX has more VRAM than
the article's reference 20GB card. From there, decrease N (more layers
on GPU) until OOM, then back off by 1.

For each value N:

1. Stop service if running.
2. Edit `/etc/systemd/system/llama-primary-experiment.service`, change
   `--n-cpu-moe N`.
3. `sudo systemctl daemon-reload && sudo systemctl start llama-primary-experiment`
4. `journalctl -u llama-primary-experiment -f` — watch for OOM, watch
   "model loaded" line, note VRAM use from `radeontop` or
   `cat /sys/class/drm/card*/device/mem_info_vram_used` in another shell.
5. Once loaded, hit it:
   ```
   curl -s http://127.0.0.1:11444/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{
       "model": "gpt-oss-120b",
       "messages": [{"role":"user","content":"Write a short story about a fox."}],
       "max_tokens": 256,
       "stream": false
     }' | jq '.usage, .choices[0].message.content[:200]'
   ```
6. Note tokens/sec from server log (look for `prompt eval` and `eval time`
   lines), VRAM peak, RAM peak, KV cache size.
7. Record in table below.

## Results

| N (--n-cpu-moe) | Load OK | VRAM peak | RAM expert footprint | tok/s prompt | tok/s gen | Notes |
|----------------:|:-------:|----------:|---------------------:|-------------:|----------:|:------|
| 26              |         |           |                      |              |           | The Register baseline |
| 24              |         |           |                      |              |           | |
| 22              |         |           |                      |              |           | |
| 20              |         |           |                      |              |           | |
| 18              |         |           |                      |              |           | |
| 16              |         |           |                      |              |           | |

Stop sweeping once loading OOMs — record the lowest N that loaded.

## Pre-flight checks before each run

- `nvidia-smi` equivalent for AMD: `radeontop -d -` or
  `rocm-smi --showmeminfo vram` (if ROCm tools installed).
- Free RAM: `free -h` — want at least 45GB available for expert
  offload + KV cache + headroom.
- Confirm no other heavy GPU users on Vulkan0:
  `fuser -v /dev/dri/renderD128 /dev/dri/card0`

## Failure modes to watch for

- **Load OOM in VRAM:** Decrease N is wrong direction; increase N (more
  experts to CPU).
- **Load OOM in DRAM:** N too high (too many experts in DRAM) or other
  RAM pressure. Stop other heavy processes.
- **Slow generation despite load OK:** This is the case where
  ik_llama.cpp becomes interesting — its CPU MoE path is supposedly
  faster than stock for this workload.
- **Vulkan device crash:** AMD MoE regression noted earlier (15-20%
  drop on ROCm/HIP for 30B MoE, system freezes on 120B). Vulkan path
  may also have issues; if so, capture the journal lines and note here.

## Decision matrix

After Phase 1:

- **Stock gets >15 tok/s gen, no crashes:** Done. Phase 2 (ik_llama.cpp
  build) not needed. Document the working config and possibly promote
  the experiment service to permanent (separate port, swap-in workflow,
  or replace primary).
- **Stock gets 5-15 tok/s, no crashes:** Worth trying ik_llama.cpp. CPU
  MoE is the bottleneck and that's exactly what the fork optimizes.
  Proceed to Phase 2.
- **Stock crashes / unstable / <5 tok/s:** Either the model is too big
  for our hardware (give up on 120B), or the AMD-specific regressions
  are biting. Capture detailed logs before deciding whether ik_llama.cpp
  has a workaround or this whole avenue is closed.
