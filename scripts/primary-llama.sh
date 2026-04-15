#!/usr/bin/env bash
set -euo pipefail

# Defensive: stop any ollama unit that might be running this session.
# All three are disabled at boot per 2026-04-15 cleanup; this only matters
# if one was manually started earlier. NEVER `systemctl enable` these.
for unit in ollama.service ollama-gpu0.service ollama-gpu1.service; do
  if systemctl is-active --quiet "$unit"; then
    sudo systemctl stop "$unit"
  fi
done

mkdir -p /tmp/aspects

# GPU 1 = RX 7900 XTX (gfx1100) on this box. Pin ROCm to that device only —
# without ROCR_VISIBLE_DEVICES, llama.cpp enumerates both cards and -ngl 99
# loads onto device 0 (5700 XT), which OOMs on an 18 GB model.
# HSA_OVERRIDE_GFX_VERSION targets gfx1100 explicitly.
# exec replaces the shell so Ctrl+C goes straight to llama-server. No trap —
# we deliberately do not resurrect Ollama on exit.
ROCR_VISIBLE_DEVICES=1 \
HSA_OVERRIDE_GFX_VERSION=11.0.0 \
GPU_MAX_HEAP_SIZE=100 \
GPU_MAX_ALLOC_PERCENT=100 \
exec ~/src/llama.cpp/llama-b8799/llama-server \
  -m ~/models/qwen3-coder-30b-a3b/*Q4_K_M*.gguf \
  -ngl 99 \
  -c 65536 \
  --flash-attn on \
  -ctk q8_0 -ctv q8_0 \
  --jinja \
  --slot-save-path /tmp/aspects/ \
  --numa distribute \
  --host 127.0.0.1 --port 11434
