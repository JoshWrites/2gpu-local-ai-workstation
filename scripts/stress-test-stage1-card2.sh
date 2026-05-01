#!/usr/bin/env bash
# Stage 1: Stress-test card 2 (5700 XT) -- llama-secondary + llama-embed concurrent.
#
# Includes a BULK INGEST phase (200 chunks, simulating real persistent-ingest load)
# because the architectural question is: "can card 2 host both the distiller's
# summarizer AND the embedder during realistic ingest workloads?"
#
# Pass -> Stage 2 (add primary card alongside)
# Fail -> embedder moves to CPU; revise stack before Stage 2
#
# Does NOT require opencode.
#
# Usage: ./stress-test-stage1-card2.sh [concurrent-duration-sec]
#        default: 60s

set -euo pipefail

DURATION_SEC="${1:-60}"
SECONDARY_URL="http://127.0.0.1:11435/v1/chat/completions"
EMBED_URL="http://127.0.0.1:11437/v1/embeddings"
OUT_DIR="/tmp/embed-stress-stage1-$$"
mkdir -p "$OUT_DIR"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║ Stage 1: Card 2 (5700 XT) concurrent stress              ║"
echo "║ llama-secondary (Qwen3-4B) + llama-embed (mxbai)          ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── Preflight ────────────────────────────────────────────────────────────────

echo ""
echo "=== Preflight ==="
check_endpoint() {
  local name="$1" url="$2"
  if curl -fs --max-time 3 "$url" >/dev/null 2>&1; then
    echo "  $name -- OK"
  else
    echo "  $name -- UNREACHABLE ($url)" >&2
    return 1
  fi
}
check_endpoint "llama-secondary (:11435)" "http://127.0.0.1:11435/v1/models" || exit 1
check_endpoint "llama-embed     (:11437)" "http://127.0.0.1:11437/v1/models" || exit 1

# ── VRAM sampler ─────────────────────────────────────────────────────────────

# Card 2 = GPU[0] per rocm-smi on this box; verify with rocm-smi --showproductname
vram_used_mb() {
  rocm-smi --showmeminfo vram 2>/dev/null \
    | awk '/GPU\[0\].*Used Memory/ { print int($NF/1024/1024) }'
}

baseline_mb=$(vram_used_mb)
echo ""
echo "=== Baseline ==="
echo "  Card 2 VRAM used: ${baseline_mb} MB"

# ── Workload generators ──────────────────────────────────────────────────────

secondary_load() {
  local log="$1" duration="$2"
  : > "$log"
  local end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    local t0=$(date +%s.%N)
    curl -fs -X POST "$SECONDARY_URL" \
      -H "Content-Type: application/json" \
      -d '{
        "model":"Qwen3-4B",
        "messages":[
          {"role":"system","content":"You are a concise summarizer. Output JSON only."},
          {"role":"user","content":"Summarize: The RX 7900 XTX is AMDs flagship RDNA3 GPU with 24GB of GDDR6. It competes with NVIDIA RTX 4080-class cards. It launched late 2022."}
        ],
        "max_tokens":120, "temperature":0.2
      }' -o /dev/null 2>/dev/null || echo "err" >> "${log}.errors"
    local t1=$(date +%s.%N)
    awk -v t0="$t0" -v t1="$t1" 'BEGIN { printf "%.3f\n", t1-t0 }' >> "$log"
    sleep 0.5
  done
}

# Lightweight ongoing embed load -- 16 chunks per burst.
embed_load_light() {
  local log="$1" duration="$2"
  : > "$log"
  local payload
  payload=$(jq -nc '{model:"mxbai-embed-large",input:[
    "The 7900 XTX has 24GB of VRAM.",
    "RDNA3 architecture supports wave32 and wave64.",
    "llama.cpp Vulkan backend supports AMD GPUs.",
    "Embedding models map text to vectors.",
    "Cosine similarity is a common vector metric.",
    "Qwen3 models support function calling.",
    "Proxmox LXC containers share the host kernel.",
    "Immich is a self-hosted photo management system.",
    "GPU passthrough for LXC uses cgroup device allow.",
    "Docker nvidia runtime exposes GPUs to containers.",
    "Python can parse JSON with the built-in module.",
    "systemd services run under Linux.",
    "The user has 62GB of DDR4 memory.",
    "SearxNG is a privacy-respecting metasearch.",
    "Watcher processes monitor agent drift.",
    "Distillers summarize web research."
  ]}')
  local end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    local t0=$(date +%s.%N)
    curl -fs -X POST "$EMBED_URL" \
      -H "Content-Type: application/json" \
      -d "$payload" -o /dev/null 2>/dev/null || echo "err" >> "${log}.errors"
    local t1=$(date +%s.%N)
    awk -v t0="$t0" -v t1="$t1" 'BEGIN { printf "%.3f\n", t1-t0 }' >> "$log"
    sleep 0.1
  done
}

# Bulk-ingest workload -- models realistic persistent-topic ingest.
# Embeds 200 unique chunks across ~13 batches of 16. Each chunk is a
# synthesized sentence (not realistic prose, but tokenization-realistic).
embed_load_bulk() {
  local log="$1" total_chunks="${2:-200}"
  : > "$log"
  local batch=16
  local ingested=0
  while (( ingested < total_chunks )); do
    # Build a batch of $batch synthetic chunks numbered from $ingested.
    local input_arr
    input_arr=$(python3 -c "
import json, sys
start = int(sys.argv[1]); n = int(sys.argv[2])
chunks = [
  f'Section {i}: Proxmox LXC container {i%200} supports resource limits. '
  f'Memory is enforced via cgroups, CPU via shares and quota. '
  f'Network namespaces provide isolation. '
  f'Storage uses ZFS subvols or LVM thin pools. '
  f'This is chunk number {i} in a synthetic ingestion test document.'
  for i in range(start, start+n)
]
print(json.dumps(chunks))
" "$ingested" "$batch")
    local payload
    payload=$(jq -nc --argjson arr "$input_arr" '{model:"mxbai-embed-large",input:$arr}')
    local t0=$(date +%s.%N)
    curl -fs -X POST "$EMBED_URL" \
      -H "Content-Type: application/json" \
      -d "$payload" -o /dev/null 2>/dev/null || echo "err" >> "${log}.errors"
    local t1=$(date +%s.%N)
    awk -v t0="$t0" -v t1="$t1" -v n="$batch" \
      'BEGIN { printf "%.3f %d\n", t1-t0, n }' >> "$log"
    ingested=$((ingested + batch))
  done
  echo "$ingested" > "${log}.total"
}

vram_watch() {
  local log="$1" duration="$2"
  : > "$log"
  local end=$((SECONDS + duration))
  while (( SECONDS < end )); do
    echo "$(date +%s) $(vram_used_mb)" >> "$log"
    sleep 2
  done
}

# ── Phase 1: Secondary-only baseline ─────────────────────────────────────────

echo ""
echo "=== Phase 1: Secondary-only baseline (15s) ==="
(secondary_load "$OUT_DIR/sec-baseline.txt" 15)
echo "  complete"

# ── Phase 2: Embed-only baseline ─────────────────────────────────────────────

echo ""
echo "=== Phase 2: Embed-only baseline (15s, 16-chunk bursts) ==="
(embed_load_light "$OUT_DIR/emb-baseline.txt" 15)
echo "  complete"

# ── Phase 3: Bulk-ingest baseline (embed only, 200 chunks) ───────────────────

echo ""
echo "=== Phase 3: Bulk-ingest baseline (200 chunks, embed-only) ==="
echo "  modeling a real persistent-topic ingest load..."
bulk_t0=$(date +%s.%N)
(embed_load_bulk "$OUT_DIR/emb-bulk-solo.txt" 200)
bulk_t1=$(date +%s.%N)
bulk_solo_elapsed=$(awk -v t0="$bulk_t0" -v t1="$bulk_t1" 'BEGIN { printf "%.2f", t1-t0 }')
echo "  complete -- 200 chunks in ${bulk_solo_elapsed}s solo"

# ── Phase 4: Concurrent light load (secondary + 16-chunk embed) ──────────────

echo ""
echo "=== Phase 4: Concurrent LIGHT load (${DURATION_SEC}s) ==="
echo "  secondary + 16-chunk embed bursts, VRAM sampled every 2s"
(vram_watch "$OUT_DIR/vram-light.txt" "$DURATION_SEC") &
vram_pid=$!
(secondary_load "$OUT_DIR/sec-concurrent-light.txt" "$DURATION_SEC") &
sec_pid=$!
(embed_load_light "$OUT_DIR/emb-concurrent-light.txt" "$DURATION_SEC") &
emb_pid=$!
wait $vram_pid $sec_pid $emb_pid

# ── Phase 5: Concurrent BULK load (secondary + bulk-ingest) ──────────────────

echo ""
echo "=== Phase 5: Concurrent BULK load (secondary + 200-chunk ingest) ==="
echo "  this is the hard test -- models real persistent-ingest under load"
(vram_watch "$OUT_DIR/vram-bulk.txt" 120) &
vram_bulk_pid=$!
(secondary_load "$OUT_DIR/sec-concurrent-bulk.txt" 120) &
sec_bulk_pid=$!
bulk_t0=$(date +%s.%N)
(embed_load_bulk "$OUT_DIR/emb-bulk-concurrent.txt" 200) &
emb_bulk_pid=$!
wait $emb_bulk_pid
bulk_t1=$(date +%s.%N)
bulk_concurrent_elapsed=$(awk -v t0="$bulk_t0" -v t1="$bulk_t1" 'BEGIN { printf "%.2f", t1-t0 }')

# Terminate secondary + vram watchers after ingest finishes (they're time-based)
wait $sec_bulk_pid $vram_bulk_pid 2>/dev/null || true

# ── Report ───────────────────────────────────────────────────────────────────

stats() {
  local label="$1" file="$2"
  if [[ ! -s "$file" ]]; then
    printf "  %-38s  NO DATA\n" "$label"
    return
  fi
  awk -v label="$label" '
    { s+=$1; if($1>max)max=$1; if(min==""||$1<min)min=$1; n++ }
    END {
      if (n==0) { printf "  %-38s  NO DATA\n", label; exit }
      printf "  %-38s  n=%d  min=%.3fs  mean=%.3fs  max=%.3fs\n",
        label, n, min, s/n, max
    }
  ' "$file"
}

vram_peak() { awk '{if($2>m)m=$2} END{print m+0}' "$1"; }
vram_final() { awk 'END{print $2+0}' "$1"; }

error_count() {
  local f="$1.errors"
  [[ -f "$f" ]] && wc -l < "$f" || echo 0
}

peak_vram_light=$(vram_peak "$OUT_DIR/vram-light.txt")
peak_vram_bulk=$(vram_peak "$OUT_DIR/vram-bulk.txt")

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║ RESULTS -- Stage 1                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "--- Secondary (Qwen3-4B) latency ---"
stats "Baseline (solo)"                       "$OUT_DIR/sec-baseline.txt"
stats "Concurrent (with 16-chunk embed)"      "$OUT_DIR/sec-concurrent-light.txt"
stats "Concurrent (with bulk ingest)"         "$OUT_DIR/sec-concurrent-bulk.txt"
echo ""
echo "--- Embed (mxbai) latency per batch ---"
stats "Baseline (16-chunk, solo)"             "$OUT_DIR/emb-baseline.txt"
stats "Bulk solo (200 chunks)"                "$OUT_DIR/emb-bulk-solo.txt"
stats "Concurrent light (16-chunk)"           "$OUT_DIR/emb-concurrent-light.txt"
stats "Concurrent bulk (200 chunks)"          "$OUT_DIR/emb-bulk-concurrent.txt"
echo ""
echo "--- Bulk ingest total time (200 chunks) ---"
echo "  Solo:        ${bulk_solo_elapsed}s"
echo "  Concurrent:  ${bulk_concurrent_elapsed}s"
echo ""
echo "--- VRAM on card 2 ---"
echo "  Baseline:              ${baseline_mb} MB"
echo "  Peak during light:     ${peak_vram_light} MB"
echo "  Peak during bulk:      ${peak_vram_bulk} MB"
echo "  Headroom vs 8192 MB:   $((8192 - peak_vram_bulk)) MB"
echo ""
echo "--- Errors ---"
echo "  secondary (baseline):           $(error_count "$OUT_DIR/sec-baseline.txt")"
echo "  secondary (concurrent light):   $(error_count "$OUT_DIR/sec-concurrent-light.txt")"
echo "  secondary (concurrent bulk):    $(error_count "$OUT_DIR/sec-concurrent-bulk.txt")"
echo "  embed (baseline):               $(error_count "$OUT_DIR/emb-baseline.txt")"
echo "  embed (bulk solo):              $(error_count "$OUT_DIR/emb-bulk-solo.txt")"
echo "  embed (concurrent light):       $(error_count "$OUT_DIR/emb-concurrent-light.txt")"
echo "  embed (concurrent bulk):        $(error_count "$OUT_DIR/emb-bulk-concurrent.txt")"

# ── Pass/fail call ───────────────────────────────────────────────────────────

echo ""
echo "--- Pass/fail (Stage 1) ---"
fail=0

check_ratio() {
  local label="$1" base="$2" concurrent="$3" max_ratio="$4"
  if [[ -z "$base" || -z "$concurrent" ]]; then return; fi
  local ratio
  ratio=$(awk -v b="$base" -v c="$concurrent" 'BEGIN{if (b==0) print 99; else printf "%.2f", c/b}')
  if awk -v r="$ratio" -v m="$max_ratio" 'BEGIN{exit !(r > m)}'; then
    echo "  FAIL: $label ${ratio}x baseline (>${max_ratio}x allowed)"
    fail=1
  else
    echo "  PASS: $label ${ratio}x baseline (<=${max_ratio}x)"
  fi
}

mean() { awk '{s+=$1;n++} END{if(n>0)printf "%.3f", s/n}' "$1"; }

sec_base=$(mean "$OUT_DIR/sec-baseline.txt")
sec_light=$(mean "$OUT_DIR/sec-concurrent-light.txt")
sec_bulk=$(mean "$OUT_DIR/sec-concurrent-bulk.txt")
emb_base=$(mean "$OUT_DIR/emb-baseline.txt")
emb_light=$(mean "$OUT_DIR/emb-concurrent-light.txt")

check_ratio "Secondary w/ light embed"   "$sec_base" "$sec_light" 1.25
check_ratio "Secondary w/ bulk ingest"   "$sec_base" "$sec_bulk"  1.50
check_ratio "Embed light concurrent"     "$emb_base" "$emb_light" 1.50

# Bulk-ingest concurrent shouldn't be more than 2x solo -- if it is, contention
# is severe enough that persistent-ingest during active sessions is impractical.
bulk_ratio=$(awk -v s="$bulk_solo_elapsed" -v c="$bulk_concurrent_elapsed" \
  'BEGIN{if(s==0)print 99; else printf "%.2f", c/s}')
if awk -v r="$bulk_ratio" 'BEGIN{exit !(r > 2.00)}'; then
  echo "  FAIL: Bulk ingest ${bulk_ratio}x slower under load (>2.0x allowed)"
  fail=1
else
  echo "  PASS: Bulk ingest ${bulk_ratio}x slower under load (<=2.0x)"
fi

if (( peak_vram_bulk >= 7800 )); then
  echo "  FAIL: VRAM peak ${peak_vram_bulk} MB during bulk (>=7800 MB ceiling)"
  fail=1
else
  echo "  PASS: VRAM peak ${peak_vram_bulk} MB during bulk (<7800 MB)"
fi

echo ""
if (( fail == 0 )); then
  echo "[x] STAGE 1 PASSED -- proceed to stage 2 (add primary card)."
  echo ""
  echo "Next: ./stress-test-stage2-both-cards.sh"
else
  echo "[ ] STAGE 1 FAILED -- move embed to CPU before stage 2."
fi

echo ""
echo "Raw data: $OUT_DIR"
exit $fail
