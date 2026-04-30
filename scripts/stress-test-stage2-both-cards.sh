#!/usr/bin/env bash
# Stage 2: Both cards under concurrent realistic load.
#
# Adds primary card (GLM on 7900 XTX) reading long documents while card 2
# is doing distiller summarization + bulk embedding concurrently.
#
# Models the full future stack: primary reasons on long context, secondary
# summarizes research, embedder ingests a topic — all at once.
#
# Pre-reqs:
#   - Stage 1 passed
#   - llama-primary.service running on :11434 (GLM-4.7-Flash)
#   - llama-secondary.service running on :11435 (Qwen3-4B)
#   - llama-embed.service running on :11437 (mxbai)
#   - ~/Documents/Repos/LevineLabsServer1/docs/security-plan.md accessible
#     (real long-doc example; configurable below)
#
# Usage: ./stress-test-stage2-both-cards.sh [long-doc-path]

set -euo pipefail

LONG_DOC="${1:-/home/levine/Documents/Repos/LevineLabsServer1/docs/security-plan.md}"
PRIMARY_URL="http://127.0.0.1:11434/v1/chat/completions"
SECONDARY_URL="http://127.0.0.1:11435/v1/chat/completions"
EMBED_URL="http://127.0.0.1:11437/v1/embeddings"
OUT_DIR="/tmp/embed-stress-stage2-$$"
mkdir -p "$OUT_DIR"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║ Stage 2: Both cards under concurrent realistic load      ║"
echo "║ Primary (GLM) + Secondary (Qwen3-4B) + Embed (mxbai)     ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── Preflight ────────────────────────────────────────────────────────────────

echo ""
echo "=== Preflight ==="
check_endpoint() {
  local name="$1" url="$2"
  if curl -fs --max-time 3 "$url" >/dev/null 2>&1; then
    echo "  $name — OK"
  else
    echo "  $name — UNREACHABLE ($url)" >&2
    return 1
  fi
}
check_endpoint "llama-primary   (:11434)" "http://127.0.0.1:11434/v1/models" || exit 1
check_endpoint "llama-secondary (:11435)" "http://127.0.0.1:11435/v1/models" || exit 1
check_endpoint "llama-embed     (:11437)" "http://127.0.0.1:11437/v1/models" || exit 1

if [[ ! -s "$LONG_DOC" ]]; then
  echo "  Long-doc path not found: $LONG_DOC" >&2
  exit 1
fi

doc_chars=$(wc -c < "$LONG_DOC")
doc_lines=$(wc -l < "$LONG_DOC")
# Rough token estimate: chars/4
doc_tokens_est=$(( doc_chars / 4 ))
echo "  Long-doc: $LONG_DOC"
echo "    lines: $doc_lines, chars: $doc_chars, ~tokens: $doc_tokens_est"

if (( doc_tokens_est > 55000 )); then
  echo "  WARN: doc is ~${doc_tokens_est} tokens; GLM primary ctx is 64K." >&2
  echo "  WARN: leaving <10K for the question prompt may truncate. Continuing." >&2
fi

# ── VRAM samplers (both cards) ───────────────────────────────────────────────

vram_card1_mb() { # 7900 XTX = GPU[1] in rocm-smi on this box
  rocm-smi --showmeminfo vram 2>/dev/null \
    | awk '/GPU\[1\].*Used Memory/ { print int($NF/1024/1024) }'
}
vram_card2_mb() { # 5700 XT = GPU[0]
  rocm-smi --showmeminfo vram 2>/dev/null \
    | awk '/GPU\[0\].*Used Memory/ { print int($NF/1024/1024) }'
}

baseline_c1=$(vram_card1_mb)
baseline_c2=$(vram_card2_mb)
echo ""
echo "=== Baseline ==="
echo "  Card 1 (7900 XTX): ${baseline_c1} MB"
echo "  Card 2 (5700 XT):  ${baseline_c2} MB"

# ── Workload: primary reads long doc ─────────────────────────────────────────

# Embed the full doc into the prompt and ask GLM a question about it.
# This exercises primary's long-context reasoning on the full doc, which is
# the workload the distiller-to-embedder chain is meant to alleviate.
primary_long_doc_load() {
  local log="$1" iterations="${2:-3}"
  : > "$log"
  local doc_body
  doc_body=$(cat "$LONG_DOC")
  for (( i=0; i<iterations; i++ )); do
    local payload
    payload=$(jq -nc --arg sys "You answer questions about documents. Be concise." \
                    --arg doc "$doc_body" \
                    --arg q "What are the three most important security principles in this document? Answer in 3 short bullet points." \
      '{model:"GLM-4.7-Flash", temperature:0.2, max_tokens:200,
        messages:[{role:"system",content:$sys},
                  {role:"user",content:("DOCUMENT:\n" + $doc + "\n\nQUESTION: " + $q)}]}')
    local t0=$(date +%s.%N)
    curl -fs -X POST "$PRIMARY_URL" \
      -H "Content-Type: application/json" \
      -d "$payload" -o /dev/null 2>/dev/null || echo "err" >> "${log}.errors"
    local t1=$(date +%s.%N)
    awk -v t0="$t0" -v t1="$t1" 'BEGIN { printf "%.3f\n", t1-t0 }' >> "$log"
  done
}

# Reuse the secondary + embed workload generators (inlined minimally)

secondary_load() {
  local log="$1" duration="$2"
  : > "$log"
  local end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    local t0=$(date +%s.%N)
    curl -fs -X POST "$SECONDARY_URL" -H "Content-Type: application/json" \
      -d '{"model":"Qwen3-4B","messages":[{"role":"system","content":"Summarize."},{"role":"user","content":"RDNA3 notes: 24GB VRAM, flagship, late 2022."}],"max_tokens":120,"temperature":0.2}' \
      -o /dev/null 2>/dev/null || echo "err" >> "${log}.errors"
    local t1=$(date +%s.%N)
    awk -v t0="$t0" -v t1="$t1" 'BEGIN { printf "%.3f\n", t1-t0 }' >> "$log"
    sleep 0.5
  done
}

embed_load_bulk() {
  local log="$1" total_chunks="${2:-200}"
  : > "$log"
  local batch=16
  local ingested=0
  while (( ingested < total_chunks )); do
    local input_arr
    input_arr=$(python3 -c "
import json, sys
start = int(sys.argv[1]); n = int(sys.argv[2])
chunks = [
  f'Section {i}: Proxmox LXC container {i%200} supports resource limits. '
  f'Memory via cgroups, CPU via shares and quota. '
  f'Network namespaces provide isolation. '
  f'Storage uses ZFS subvols or LVM thin pools. '
  f'Chunk {i} in synthetic ingestion test.'
  for i in range(start, start+n)
]
print(json.dumps(chunks))
" "$ingested" "$batch")
    local payload
    payload=$(jq -nc --argjson arr "$input_arr" '{model:"mxbai-embed-large",input:$arr}')
    local t0=$(date +%s.%N)
    curl -fs -X POST "$EMBED_URL" -H "Content-Type: application/json" \
      -d "$payload" -o /dev/null 2>/dev/null || echo "err" >> "${log}.errors"
    local t1=$(date +%s.%N)
    awk -v t0="$t0" -v t1="$t1" 'BEGIN { printf "%.3f %d\n", t1-t0, n }' >> "$log"
    ingested=$((ingested + batch))
  done
}

vram_watch() {
  local log="$1" duration="$2"
  : > "$log"
  local end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    echo "$(date +%s) c1=$(vram_card1_mb) c2=$(vram_card2_mb)" >> "$log"
    sleep 2
  done
}

# ── Phase 1: Primary-only baseline (long-doc read, solo) ─────────────────────

echo ""
echo "=== Phase 1: Primary-only long-doc baseline (3 iterations solo) ==="
(primary_long_doc_load "$OUT_DIR/pri-baseline.txt" 3)
echo "  complete"

# ── Phase 2: Full concurrent load (all three services under realistic load) ──

echo ""
echo "=== Phase 2: Full concurrent load (all three services) ==="
echo "  primary: 3x long-doc read (sequential)"
echo "  secondary: continuous distiller-sized calls"
echo "  embed: bulk ingest 200 chunks"
echo ""

(vram_watch "$OUT_DIR/vram-full.txt" 180) &
vram_pid=$!
(secondary_load "$OUT_DIR/sec-concurrent.txt" 180) &
sec_pid=$!
(embed_load_bulk "$OUT_DIR/emb-concurrent.txt" 200) &
emb_pid=$!

primary_t0=$(date +%s.%N)
(primary_long_doc_load "$OUT_DIR/pri-concurrent.txt" 3)
primary_t1=$(date +%s.%N)
primary_concurrent_elapsed=$(awk -v t0="$primary_t0" -v t1="$primary_t1" 'BEGIN { printf "%.2f", t1-t0 }')

# Let ingest finish if it's still running, then clean up long-running workers
wait $emb_pid 2>/dev/null || true
wait $sec_pid $vram_pid 2>/dev/null || true

# ── Report ───────────────────────────────────────────────────────────────────

stats() {
  local label="$1" file="$2"
  if [[ ! -s "$file" ]]; then printf "  %-36s  NO DATA\n" "$label"; return; fi
  awk -v label="$label" '
    { s+=$1; if($1>max)max=$1; if(min==""||$1<min)min=$1; n++ }
    END { if (n==0) { printf "  %-36s  NO DATA\n", label; exit }
          printf "  %-36s  n=%d  min=%.3fs  mean=%.3fs  max=%.3fs\n",
                 label, n, min, s/n, max }
  ' "$file"
}

peak_c1=$(awk '/c1=/ { split($2, a, "="); if (a[2]+0 > m) m=a[2]+0 } END { print m+0 }' "$OUT_DIR/vram-full.txt")
peak_c2=$(awk '/c2=/ { split($3, a, "="); if (a[2]+0 > m) m=a[2]+0 } END { print m+0 }' "$OUT_DIR/vram-full.txt")

error_count() {
  local f="$1.errors"
  [[ -f "$f" ]] && wc -l < "$f" || echo 0
}

mean() { awk '{s+=$1;n++} END{if(n>0)printf "%.3f", s/n}' "$1"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║ RESULTS — Stage 2                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "--- Primary (GLM, long-doc reasoning) ---"
stats "Baseline (solo, 3 iters)"       "$OUT_DIR/pri-baseline.txt"
stats "Concurrent (with sec+embed)"    "$OUT_DIR/pri-concurrent.txt"
echo ""
echo "--- Secondary (Qwen3-4B, continuous) ---"
stats "Concurrent"                     "$OUT_DIR/sec-concurrent.txt"
echo ""
echo "--- Embed (bulk ingest, 200 chunks concurrent) ---"
stats "Concurrent"                     "$OUT_DIR/emb-concurrent.txt"
echo ""
echo "--- VRAM peaks during full concurrent load ---"
echo "  Card 1 (7900 XTX): baseline=${baseline_c1} MB  peak=${peak_c1} MB  headroom=$((24576 - peak_c1)) MB"
echo "  Card 2 (5700 XT):  baseline=${baseline_c2} MB  peak=${peak_c2} MB  headroom=$((8192 - peak_c2)) MB"
echo ""
echo "--- Errors ---"
echo "  primary (baseline):       $(error_count "$OUT_DIR/pri-baseline.txt")"
echo "  primary (concurrent):     $(error_count "$OUT_DIR/pri-concurrent.txt")"
echo "  secondary (concurrent):   $(error_count "$OUT_DIR/sec-concurrent.txt")"
echo "  embed (concurrent):       $(error_count "$OUT_DIR/emb-concurrent.txt")"

# ── Pass/fail ────────────────────────────────────────────────────────────────

echo ""
echo "--- Pass/fail (Stage 2) ---"
fail=0

pri_base=$(mean "$OUT_DIR/pri-baseline.txt")
pri_con=$(mean "$OUT_DIR/pri-concurrent.txt")
if [[ -n "$pri_base" && -n "$pri_con" ]]; then
  ratio=$(awk -v b="$pri_base" -v c="$pri_con" 'BEGIN{if(b==0)print 99; else printf "%.2f", c/b}')
  if awk -v r="$ratio" 'BEGIN{exit !(r > 1.30)}'; then
    echo "  FAIL: Primary long-doc latency ${ratio}x baseline (>1.30x allowed)"
    fail=1
  else
    echo "  PASS: Primary long-doc latency ${ratio}x baseline (≤1.30x)"
  fi
fi

if (( peak_c1 >= 23500 )); then
  echo "  FAIL: Card 1 VRAM peak ${peak_c1} MB (≥23500 MB ceiling)"
  fail=1
else
  echo "  PASS: Card 1 VRAM peak ${peak_c1} MB (<23500 MB)"
fi

if (( peak_c2 >= 7800 )); then
  echo "  FAIL: Card 2 VRAM peak ${peak_c2} MB (≥7800 MB ceiling)"
  fail=1
else
  echo "  PASS: Card 2 VRAM peak ${peak_c2} MB (<7800 MB)"
fi

# Count any error exits from the workload generators
total_errs=$(( $(error_count "$OUT_DIR/pri-concurrent.txt") \
             + $(error_count "$OUT_DIR/sec-concurrent.txt") \
             + $(error_count "$OUT_DIR/emb-concurrent.txt") ))
if (( total_errs > 0 )); then
  echo "  FAIL: $total_errs API errors during concurrent load"
  fail=1
else
  echo "  PASS: zero API errors under concurrent load"
fi

echo ""
if (( fail == 0 )); then
  echo "✓ STAGE 2 PASSED — full stack viable under concurrent load."
  echo ""
  echo "The two-track research architecture (distiller + ingest_topic) is"
  echo "viable with embedder on card 2. Proceed with ingest_topic design."
else
  echo "✗ STAGE 2 FAILED — review specific failure(s) above."
  echo ""
  echo "Most likely mitigations:"
  echo "  - If card 2 VRAM peaked: embedder to CPU."
  echo "  - If primary latency blew up: likely DRAM/PCIe contention — try"
  echo "    running bulk ingest OFF-HOURS rather than during active sessions."
fi

echo ""
echo "Raw data: $OUT_DIR"
exit $fail
