#!/usr/bin/env bash
#
# oss-tuning.sh - A/B benchmark for gpt-oss-120b config presets in
# llama-router.ini. Iterates over a list of preset ids, swaps the
# router-mode primary to each, runs three fixed prompts N times, and
# emits CSV with prompt-eval and gen tok/s plus VRAM/DRAM peaks.
#
# Goal: settle whether the auto-fit preset (--fit on, no -ngl, no
# --n-cpu-moe) matches or beats the hand-tuned baseline preset
# (--n-cpu-moe 28). Tear down when done; do not leave a permanent
# bench harness behind.
#
# Usage:
#   bench/oss-tuning.sh                    run all presets, all prompts
#   bench/oss-tuning.sh --presets gpt-oss-120b   run one preset only
#   bench/oss-tuning.sh --runs 5           N iterations per (preset, prompt)
#
# Output:
#   bench/results/oss-tuning-YYYYMMDD-HHMMSS.csv
#
# Requires: jq, curl, sed, awk. The router unit must already be running
# (--no-models-autoload). The script issues /models/load via HTTP, polls
# /models for status=loaded, then runs the prompts. It does NOT touch
# systemd or sudo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

# ── Settings ────────────────────────────────────────────────────────────

ROUTER_URL="http://127.0.0.1:11434"
LOAD_TIMEOUT_SEC=600
GEN_TIMEOUT_SEC=300
PRESETS_DEFAULT="gpt-oss-120b gpt-oss-120b-autofit"
RUNS_DEFAULT=3

# 7900 XTX is /sys/class/drm/card2 on this host (HIP card). Falls back
# to scanning /sys/class/drm/card*/device/mem_info_vram_used if missing.
VRAM_SYSFS="/sys/class/drm/card2/device/mem_info_vram_used"

# ── CLI ─────────────────────────────────────────────────────────────────

PRESETS="$PRESETS_DEFAULT"
RUNS="$RUNS_DEFAULT"
while (( $# )); do
  case "$1" in
    --presets) PRESETS="$2"; shift 2 ;;
    --runs)    RUNS="$2"; shift 2 ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$RESULTS_DIR" "$PROMPTS_DIR"

# ── Prompt fixtures ─────────────────────────────────────────────────────

# short.txt: ~80-token user message. Enough for a meaningful gen-tok/s
# read without paying for prompt-eval. The model will reply with code,
# we only care about throughput.
SHORT_PROMPT_FILE="$PROMPTS_DIR/short.txt"
if [[ ! -f "$SHORT_PROMPT_FILE" ]]; then
  cat > "$SHORT_PROMPT_FILE" <<'EOF'
Write a Python function called `parse_log_line` that takes a single
string in the format "TIMESTAMP LEVEL MESSAGE" and returns a tuple of
(timestamp_string, level_string, message_string). Handle the case
where MESSAGE may itself contain spaces. Include one short docstring
and one example call. Output only the function body and the example.
EOF
fi

# long-needle.txt: 43K-token prompt with a single magic string buried at
# 80% depth. We generate it deterministically from a small filler corpus
# rather than committing 250 KB to the repo. Re-runs produce the exact
# same bytes, so prompt-cache hits across runs work.
LONG_PROMPT_FILE="$PROMPTS_DIR/long-needle.txt"
if [[ ! -f "$LONG_PROMPT_FILE" ]]; then
  python3 - <<'PY' > "$LONG_PROMPT_FILE"
filler = (
    "The quick brown fox jumps over the lazy dog. "
    "Pack my box with five dozen liquor jugs. "
    "Sphinx of black quartz, judge my vow. "
    "How vexingly quick daft zebras jump. "
)
needle = "QZX-7283-MAGENTA"
# 43K tokens at ~3 chars/token = ~130KB. We pad with the filler block
# (40 chars) repeated ~3300 times, place the needle at 80% depth.
total_blocks = 3300
needle_at = int(total_blocks * 0.80)
parts = []
for i in range(total_blocks):
    if i == needle_at:
        parts.append(f"The secret code phrase for this document is {needle}. ")
    parts.append(filler)
parts.append("\n\nWhat is the secret code phrase mentioned in the document above? Reply with only the code phrase, nothing else.\n")
print("".join(parts))
PY
fi

# ── Helpers ─────────────────────────────────────────────────────────────

err() { echo "ERROR: $*" >&2; }
log() { echo "[$(date +%H:%M:%S)] $*"; }

vram_used_mb() {
  if [[ -r "$VRAM_SYSFS" ]]; then
    awk '{printf "%d", $1 / 1048576}' "$VRAM_SYSFS"
  else
    echo "0"
  fi
}

llama_server_pid() {
  systemctl show -p MainPID --value llama-primary-router.service 2>/dev/null
}

dram_used_mb() {
  local pid; pid="$(llama_server_pid)"
  if [[ -n "$pid" && "$pid" != "0" && -r "/proc/$pid/status" ]]; then
    awk '/^VmRSS:/ {printf "%d", $2 / 1024}' "/proc/$pid/status"
  else
    echo "0"
  fi
}

# Wait for /models to report status=loaded for the given alias.
wait_for_loaded() {
  local alias="$1"
  local start=$SECONDS
  while (( SECONDS - start < LOAD_TIMEOUT_SEC )); do
    local status
    status="$(curl -sf "$ROUTER_URL/v1/models" 2>/dev/null \
      | jq -r --arg id "$alias" '.data[] | select(.id == $id) | .status.value' 2>/dev/null)"
    if [[ "$status" == "loaded" ]]; then return 0; fi
    if [[ "$status" == "loading-error" ]]; then return 2; fi
    sleep 5
  done
  return 1
}

# Unload everything currently loaded. Router state stays up.
unload_all() {
  local ids
  ids="$(curl -sf "$ROUTER_URL/v1/models" 2>/dev/null \
    | jq -r '.data[] | select(.status.value == "loaded") | .id' 2>/dev/null)"
  for id in $ids; do
    log "  unloading $id"
    curl -sf -X POST "$ROUTER_URL/models/unload" \
      -H 'Content-Type: application/json' \
      -d "{\"model\": \"$id\"}" >/dev/null || true
  done
  # give the unload some time
  sleep 5
}

# Ask the router to load a preset by alias, wait for status=loaded.
load_preset() {
  local alias="$1"
  log "  loading $alias (timeout ${LOAD_TIMEOUT_SEC}s)"
  curl -sf -X POST "$ROUTER_URL/models/load" \
    -H 'Content-Type: application/json' \
    -d "{\"model\": \"$alias\"}" >/dev/null \
    || { err "load request failed"; return 1; }
  if ! wait_for_loaded "$alias"; then
    err "preset $alias did not reach status=loaded within ${LOAD_TIMEOUT_SEC}s"
    return 1
  fi
  log "  loaded ($(vram_used_mb) MB VRAM, $(dram_used_mb) MB DRAM)"
}

# Run one chat-completions call against the loaded model. Echo a CSV
# row to stdout. Args: preset, run_index, prompt_label, prompt_file,
# max_tokens.
run_one() {
  local preset="$1" run="$2" label="$3" prompt_file="$4" max_tokens="$5"
  local payload tmpfile
  tmpfile="$(mktemp)"
  # Build request via jq to handle prompt escaping safely.
  payload="$(jq -n \
    --arg model "$preset" \
    --arg content "$(cat "$prompt_file")" \
    --argjson max "$max_tokens" \
    '{model:$model, messages:[{role:"user",content:$content}], max_tokens:$max, stream:false}')"

  local vram_before dram_before
  vram_before="$(vram_used_mb)"
  dram_before="$(dram_used_mb)"

  local http_status t0 t1 wall_ms
  t0="$(date +%s%3N)"
  http_status="$(curl -s -o "$tmpfile" -w '%{http_code}' \
    --max-time "$GEN_TIMEOUT_SEC" \
    "$ROUTER_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$payload")"
  t1="$(date +%s%3N)"
  wall_ms=$(( t1 - t0 ))

  local vram_after dram_after
  vram_after="$(vram_used_mb)"
  dram_after="$(dram_used_mb)"

  if [[ "$http_status" != "200" ]]; then
    err "HTTP $http_status for $preset/$label run $run"
    cat "$tmpfile" >&2
    rm -f "$tmpfile"
    echo "$preset,$run,$label,$wall_ms,ERR,ERR,ERR,ERR,ERR,ERR,ERR,$vram_after,$dram_after"
    return 1
  fi

  # Pull timings out of the response.
  local prompt_n cached_n predicted_n prompt_per_sec gen_per_sec ttft_ms
  prompt_n="$(jq -r '.timings.prompt_n // 0' "$tmpfile")"
  cached_n="$(jq -r '.timings.cache_n // 0' "$tmpfile")"
  predicted_n="$(jq -r '.timings.predicted_n // 0' "$tmpfile")"
  prompt_per_sec="$(jq -r '.timings.prompt_per_second // 0' "$tmpfile")"
  gen_per_sec="$(jq -r '.timings.predicted_per_second // 0' "$tmpfile")"
  # llama-server doesn't return TTFT directly for non-stream; approximate
  # as prompt_ms.
  ttft_ms="$(jq -r '.timings.prompt_ms // 0' "$tmpfile")"

  rm -f "$tmpfile"
  echo "$preset,$run,$label,$wall_ms,$prompt_n,$cached_n,$predicted_n,$prompt_per_sec,$gen_per_sec,$ttft_ms,$vram_before,$vram_after,$dram_after"
}

# ── Main ────────────────────────────────────────────────────────────────

ts="$(date +%Y%m%d-%H%M%S)"
csv="$RESULTS_DIR/oss-tuning-$ts.csv"
echo "preset,run,prompt,wall_ms,prompt_tokens,cached_tokens,gen_tokens,prompt_tok_per_sec,gen_tok_per_sec,prompt_eval_ms,vram_before_mb,vram_after_mb,dram_after_mb" > "$csv"

log "results -> $csv"
log "presets: $PRESETS"
log "runs per prompt: $RUNS"

for preset in $PRESETS; do
  log "=== $preset ==="
  unload_all
  if ! load_preset "$preset"; then
    err "skipping $preset (failed to load)"
    continue
  fi

  # Warmup: short prompt to settle KV/compile.
  log "  warmup..."
  run_one "$preset" 0 "warmup" "$SHORT_PROMPT_FILE" 50 >/dev/null || true

  for ((i=1; i<=RUNS; i++)); do
    log "  run $i/$RUNS short"
    row="$(run_one "$preset" "$i" "short" "$SHORT_PROMPT_FILE" 256)"
    echo "$row" >> "$csv"

    log "  run $i/$RUNS long-cold"
    # Force cold path by sending a different filler message first to
    # invalidate cache. Cheaper than restarting the model.
    run_one "$preset" "$i" "cache-bust" "$SHORT_PROMPT_FILE" 50 >/dev/null || true
    row="$(run_one "$preset" "$i" "long-cold" "$LONG_PROMPT_FILE" 64)"
    echo "$row" >> "$csv"

    log "  run $i/$RUNS long-warm"
    # Same prompt again; should hit cache.
    row="$(run_one "$preset" "$i" "long-warm" "$LONG_PROMPT_FILE" 64)"
    echo "$row" >> "$csv"
  done
done

log "done"
log ""
log "summary:"
awk -F, 'NR>1 && $9 != "ERR" {
  key=$1 "/" $3
  count[key]++
  prompt_sum[key]+=$8
  gen_sum[key]+=$9
}
END {
  printf "  %-40s %12s %12s\n", "preset/prompt", "prompt_tok/s", "gen_tok/s"
  for (k in count) {
    printf "  %-40s %12.1f %12.2f\n", k, prompt_sum[k]/count[k], gen_sum[k]/count[k]
  }
}' "$csv" | sort
