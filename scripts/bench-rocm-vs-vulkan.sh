#!/usr/bin/env bash
# Quick apples-to-apples bench: ROCm vs Vulkan on the primary model.
# 3 warm runs per backend. Measures: startup-to-ready, and tokens/sec
# on a fixed 2048-token generation.
#
# Assumes llama-server is NOT running on port 11434.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./common.sh
source "${REPO}/scripts/common.sh"

ROCM_LAUNCH="${REPO}/scripts/primary-llama.sh"
VULKAN_LAUNCH="${REPO}/scripts/primary-llama-vulkan.sh"
RUNS=3
OUT="${REPO}/bench-rocm-vs-vulkan.csv"

echo "backend,run,ready_s,prompt_tokens,completion_tokens,prompt_ms,completion_ms,prompt_tok_per_s,gen_tok_per_s" > "$OUT"

wait_ready() {
  local i
  for i in $(seq 1 180); do
    if curl -fs --max-time 0.5 http://127.0.0.1:11434/health >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_vram_drain() {
  for _ in $(seq 1 30); do
    local mb
    mb=$(rocm-smi --showmeminfo vram 2>/dev/null \
      | awk '/GPU\[1\].*VRAM Total Used Memory/ { print int($NF / 1024 / 1024) }')
    if [[ -n "$mb" && "$mb" -lt 5000 ]]; then return 0; fi
    sleep 1
  done
}

bench_one() {
  local backend="$1" launch="$2" n="$3"

  local t0 t_ready ready_s
  t0=$(date +%s.%N)
  "$launch" >/dev/null 2>&1 &
  local pid=$!

  if ! wait_ready; then
    echo "  $backend run $n: TIMEOUT"
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pkill -f llama-server 2>/dev/null || true
    wait_vram_drain
    echo "$backend,$n,TIMEOUT,,,,,," >> "$OUT"
    return
  fi

  t_ready=$(date +%s.%N)
  ready_s=$(awk -v a="$t_ready" -v b="$t0" 'BEGIN { printf "%.2f", a-b }')

  # Warm up one small request so first-token overhead isn't in the measured run.
  curl -s -X POST http://127.0.0.1:11434/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":4,"stream":false}' \
    >/dev/null 2>&1 || true

  # Main timing request: force ~2048 tokens of generation on a small prompt
  # so we isolate generation speed. ignore_eos=true keeps the model generating.
  local resp
  resp=$(curl -s -X POST http://127.0.0.1:11434/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
      "messages":[{"role":"user","content":"Write an essay about the history of computing."}],
      "max_tokens":2048,
      "stream":false,
      "ignore_eos":true,
      "temperature":0
    }')

  # llama.cpp OpenAI-compat returns "timings" alongside "usage".
  local pt ct pm cm pps gps
  pt=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("usage",{}).get("prompt_tokens",""))')
  ct=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("usage",{}).get("completion_tokens",""))')
  pm=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("timings",{}).get("prompt_ms",""))')
  cm=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("timings",{}).get("predicted_ms",""))')
  pps=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); t=d.get("timings",{}); pt=t.get("prompt_n",0); pm=t.get("prompt_ms",0); print(f"{1000*pt/pm:.2f}" if pm else "")')
  gps=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); t=d.get("timings",{}); ct=t.get("predicted_n",0); cm=t.get("predicted_ms",0); print(f"{1000*ct/cm:.2f}" if cm else "")')

  printf "  %-6s run %d: ready=%ss  prompt=%s@%stok/s  gen=%s@%stok/s\n" \
    "$backend" "$n" "$ready_s" "$pt" "$pps" "$ct" "$gps"
  echo "$backend,$n,$ready_s,$pt,$ct,$pm,$cm,$pps,$gps" >> "$OUT"

  # Shut down cleanly.
  pkill -f llama-server 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait_vram_drain
}

echo "=== ROCm (warmup, not recorded) ==="
bench_one rocm-warmup "$ROCM_LAUNCH" 0
# Strip the warmup line out of the CSV so only the 3 real runs are in it.
grep -v '^rocm-warmup,' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo
echo "=== ROCm ==="
for n in $(seq 1 $RUNS); do bench_one rocm "$ROCM_LAUNCH" "$n"; done

echo
echo "=== Vulkan (warmup, not recorded) ==="
bench_one vulkan-warmup "$VULKAN_LAUNCH" 0
grep -v '^vulkan-warmup,' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo
echo "=== Vulkan ==="
for n in $(seq 1 $RUNS); do bench_one vulkan "$VULKAN_LAUNCH" "$n"; done

echo
echo "done. CSV: $OUT"
