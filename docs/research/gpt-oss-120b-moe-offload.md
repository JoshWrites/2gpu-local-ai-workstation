# GPT-OSS-120B MoE expert offload — experiment notes

Phase 1 of the ik_llama.cpp investigation. Tests whether stock llama.cpp's
`--n-cpu-moe` is enough to run a 60GB+ MoE model on 24GB VRAM + 64GB DRAM
at usable tok/s — before considering whether the ik_llama.cpp fork is
worth building.

Reference: <https://www.theregister.com/2025/08/24/llama_cpp_hands_on/>
got ~20 tok/s on a 20GB GPU + 64GB DDR4 with `--n-cpu-moe 26`.

Model: `ggml-org/gpt-oss-120b-GGUF`, MXFP4 quant (~63GB total, 3 shards).
Stored at `/var/lib/llama-models/gpt-oss-120b/`.

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
