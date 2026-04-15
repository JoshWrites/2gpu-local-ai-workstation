#!/usr/bin/env bash
# Benchmark llama-server startup across cold and warm page-cache states.
# 3 cold starts (GGUF evicted from page cache before launch), 7 warm starts.
# Writes per-run phase timings to bench-results.csv in the repo root.
#
# Phases captured (seconds from process start):
#   rocm_init        — "found N ROCm devices" line
#   tensor_load_done — first line after "load_tensors: loading" completes
#                      (we use the first llama_context line as the boundary)
#   kv_alloc_done    — "llama_kv_cache: size =" line
#   warmup_done      — "srv    load_model: initializing slots" line
#   ready            — "server is listening" line
#
# Each run leaves the server up for 3s post-ready, then kills it. Between
# runs we verify GPU 1 VRAM has dropped below 5 GB before proceeding.
#
# No sudo needed. Safe to walk away from.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="${REPO}/scripts/primary-llama.sh"
GGUF="${HOME}/models/qwen3-coder-30b-a3b/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
OUT="${REPO}/bench-results.csv"
LOG_DIR="$(mktemp -d)"

COLD_RUNS=3
WARM_RUNS=7
TOTAL=$((COLD_RUNS + WARM_RUNS))

echo "bench log dir: ${LOG_DIR}"
echo "writing csv to: ${OUT}"

# Safety: stop any running llama-server up front.
pkill -f llama-server 2>/dev/null || true
sleep 2

# CSV header
echo "run,state,rocm_init,tensor_load_done,kv_alloc_done,warmup_done,ready,total_wall,vram_peak_mb,error" > "${OUT}"

evict_cache() {
  python3 - <<'PY'
import os, ctypes
libc = ctypes.CDLL("libc.so.6")
path = "/home/levine/models/qwen3-coder-30b-a3b/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
fd = os.open(path, os.O_RDONLY)
libc.posix_fadvise(fd, ctypes.c_longlong(0), ctypes.c_longlong(0), 4)
os.close(fd)
PY
  sync
}

vram_mb_gpu1() {
  rocm-smi --showmeminfo vram 2>/dev/null \
    | awk '/GPU\[1\].*VRAM Total Used Memory/ { print int($NF / 1024 / 1024) }'
}

wait_for_vram_baseline() {
  for _ in $(seq 1 30); do
    local mb=$(vram_mb_gpu1)
    if [[ -n "$mb" && "$mb" -lt 5000 ]]; then return 0; fi
    sleep 1
  done
  echo "WARN: VRAM did not return to baseline" >&2
  return 1
}

run_once() {
  local n="$1" state="$2"
  local log="${LOG_DIR}/run-${n}-${state}.log"

  if [[ "$state" == "cold" ]]; then
    evict_cache
  fi

  local t0=$(date +%s.%N)
  "${LAUNCH}" 2>&1 | python3 -u -c "
import sys, time
t0 = time.time()
for line in sys.stdin:
    t = time.time() - t0
    sys.stdout.write(f'{t:10.4f}  {line}')
    sys.stdout.flush()
" > "${log}" 2>&1 &
  local launcher_pid=$!

  # Poll for readiness, hard cap at 180s.
  local ready=0 vram_peak=0
  for i in $(seq 1 180); do
    if curl -s --max-time 0.5 http://127.0.0.1:11434/health 2>/dev/null | grep -q '"ok"'; then
      ready=1; break
    fi
    local v=$(vram_mb_gpu1); [[ -n "$v" && "$v" -gt "$vram_peak" ]] && vram_peak="$v"
    sleep 1
  done
  local t_ready=$(date +%s.%N)
  local total_wall=$(awk -v a="$t_ready" -v b="$t0" 'BEGIN { printf "%.3f", a-b }')

  # Hold briefly so we can grab VRAM peak and let warmup settle.
  if [[ "$ready" == 1 ]]; then
    sleep 2
    local v=$(vram_mb_gpu1); [[ -n "$v" && "$v" -gt "$vram_peak" ]] && vram_peak="$v"
  fi

  # Kill the server and wait for VRAM to drain.
  pkill -f llama-server 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  wait_for_vram_baseline || true

  # Extract phase timestamps from the log.
  local rocm_init tensor_done kv_done warm_done server_ready err=""
  rocm_init=$(awk '/ggml_cuda_init: found/ { print $1; exit }' "${log}")
  # "tensor_load_done" — first llama_context line is the earliest reliable post-tensor marker
  tensor_done=$(awk '/llama_context: constructing llama_context|llama_context:  ROCm_Host output buffer/ { print $1; exit }' "${log}")
  kv_done=$(awk '/llama_kv_cache: size =/ { print $1; exit }' "${log}")
  warm_done=$(awk '/srv    load_model: initializing slots/ { print $1; exit }' "${log}")
  server_ready=$(awk '/server is listening/ { print $1; exit }' "${log}")

  if [[ "$ready" != 1 ]]; then err="timeout_180s"; fi
  if [[ -z "$server_ready" && -z "$err" ]]; then err="no_ready_line"; fi

  echo "${n},${state},${rocm_init:-},${tensor_done:-},${kv_done:-},${warm_done:-},${server_ready:-},${total_wall},${vram_peak},${err}" >> "${OUT}"
  printf "  run %2d %-4s  rocm=%-6s tensor=%-6s kv=%-6s warm=%-6s ready=%-7s total=%-7s vram=%sMB %s\n" \
    "$n" "$state" "${rocm_init:-?}" "${tensor_done:-?}" "${kv_done:-?}" "${warm_done:-?}" "${server_ready:-?}" "${total_wall}" "${vram_peak}" "${err}"
}

i=0
for _ in $(seq 1 $COLD_RUNS); do
  i=$((i+1))
  echo "[$i/$TOTAL] cold start"
  run_once "$i" "cold"
done
for _ in $(seq 1 $WARM_RUNS); do
  i=$((i+1))
  echo "[$i/$TOTAL] warm start"
  run_once "$i" "warm"
done

echo
echo "done. CSV: ${OUT}"
echo "raw logs: ${LOG_DIR}"
