#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Vulkan-backed variant of primary-llama.sh. Same flags as the ROCm
# launcher so bench results are comparable. Vulkan enumerates the
# 7900 XTX as Vulkan0 (unlike ROCm, where it's device 1), so we pin
# with --device Vulkan0 instead of ROCR_VISIBLE_DEVICES.

# Defensive: stop any ollama unit that might be running this session.
for unit in ollama.service ollama-gpu0.service ollama-gpu1.service; do
  if systemctl is-active --quiet "$unit"; then
    sudo systemctl stop "$unit"
  fi
done

mkdir -p /tmp/aspects

VULKAN_BIN="${VULKAN_BIN:-$HOME/src/llama.cpp/llama-b8799-vulkan/llama-server}"

exec "$VULKAN_BIN" \
  -m "$MODEL_GGUF" \
  --device Vulkan0 \
  -ngl 99 \
  -c 65536 \
  --flash-attn on \
  -ctk q8_0 -ctv q8_0 \
  --jinja \
  --slot-save-path /tmp/aspects/ \
  --numa distribute \
  --host 127.0.0.1 --port 11434
