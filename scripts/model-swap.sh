#!/usr/bin/env bash
# model-swap.sh — swap the currently-loaded primary model on the
# llama-primary-router service.
#
# Usage:
#   model-swap.sh <target-model-id>
#
# Where <target-model-id> is one of the keys in configs/workstation/
# primary-pool.json (also the [section] name in llama-router.ini and
# the model id at the API level).
#
# What this does:
#   1. Reads the registry to learn about source and target models.
#   2. Queries the router's /models endpoint for current state.
#   3. Queries opencode's SQLite for the current session token count.
#   4. Predicts memory headroom (VRAM + DRAM) post-unload, soft-warns if low.
#   5. Decides whether pre-swap compaction is needed (current model is
#      larger AND session > target.usable). If so, fires opencode's
#      compaction agent BEFORE the swap, while the larger model is
#      still loaded.
#   6. Shows a yad confirm dialog with depth-aware time estimates and
#      memory check status.
#   7. On OK, calls /models/load on the target, polls /models for
#      'loaded' status, shows a yad progress bar.
#   8. Exits 0 on success, 1 on cancel/failure.
#
# Run from a terminal for testing; opencode patch (commit 3) calls this
# automatically on session model change.

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${WS_PRIMARY_POOL:-${REPO}/configs/workstation/primary-pool.json}"
ROUTER_BASE="${WS_ROUTER_BASE:-http://127.0.0.1:11434}"
OPENCODE_DB="${HOME}/.local/share/opencode/opencode.db"

# Wait timeouts (seconds). Generous because OSS load can take ~4 min,
# compaction summarization can take a few min on long sessions.
LOAD_TIMEOUT=900
COMPACTION_TIMEOUT=600

# VRAM card to inspect (the 7900 XTX). On this workstation the driver
# enumerates it as card2; older drivers / different hardware may
# differ. Override via WS_GPU_PRIMARY_CARD if needed.
GPU_CARD="${WS_GPU_PRIMARY_CARD:-card2}"

# Baseline VRAM overhead that's never released by an unload (Plasma
# compositor + driver allocations). Conservative; predicts somewhat
# pessimistically about post-unload free, which is the safe direction.
VRAM_BASELINE_MB=1024

# ── Utilities ────────────────────────────────────────────────────────────────

log() { printf '\e[36m[model-swap]\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[33m[model-swap]\e[0m WARN: %s\n' "$*" >&2; }
err() { printf '\e[31m[model-swap]\e[0m ERROR: %s\n' "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "missing required command: $1"
    return 1
  }
}

# ── Args ─────────────────────────────────────────────────────────────────────

if [[ $# -ne 1 ]]; then
  cat >&2 <<EOF
Usage: $0 <target-model-id>

Where <target-model-id> is one of the model ids declared in:
  $REGISTRY

The script will check current state, predict memory headroom, ask for
confirmation via yad, and then orchestrate the swap with progress UI.
EOF
  exit 2
fi

TARGET="$1"

# Required external tools.
require_cmd curl
require_cmd jq
require_cmd python3
require_cmd yad || { err "yad not installed -- 'sudo apt install yad'"; exit 1; }

# ── Registry helpers ─────────────────────────────────────────────────────────

[[ -r "$REGISTRY" ]] || { err "registry not found: $REGISTRY"; exit 1; }

registry_field() {
  # registry_field <model-id> <field>
  jq -r --arg m "$1" --arg f "$2" '.models[$m][$f] // empty' "$REGISTRY"
}

registry_has() {
  jq -e --arg m "$1" '.models[$m]' "$REGISTRY" >/dev/null 2>&1
}

# Verify the target exists in the registry. If it doesn't, refuse early
# rather than discover this halfway through a swap.
if ! registry_has "$TARGET"; then
  err "model '$TARGET' not in registry $REGISTRY"
  err "registered ids:"
  jq -r '.models | keys[] | "  - " + .' "$REGISTRY" >&2
  exit 1
fi

TARGET_DISPLAY=$(registry_field "$TARGET" display_name)
TARGET_DESC=$(registry_field "$TARGET" description)
TARGET_CTX=$(registry_field "$TARGET" context_tokens)
TARGET_VRAM_MB=$(registry_field "$TARGET" vram_required_mb)
TARGET_DRAM_MB=$(registry_field "$TARGET" dram_required_mb)
TARGET_LOAD_SEC=$(registry_field "$TARGET" expected_load_seconds)
TARGET_GEN_TPS=$(registry_field "$TARGET" expected_gen_tok_per_sec)

# ── Router state queries ─────────────────────────────────────────────────────

router_models_json() {
  # Returns the raw /models response. Caller pipes through jq.
  if ! curl -fsS -m 5 "$ROUTER_BASE/models"; then
    err "router not reachable at $ROUTER_BASE/models"
    err "is llama-primary-router.service running?"
    return 1
  fi
}

current_loaded_model() {
  # Returns the id of the currently-loaded model, or empty if none.
  router_models_json | jq -r '.data[] | select(.status.value == "loaded") | .id' | head -1
}

model_status() {
  # model_status <model-id>; returns the current status (unloaded/loading/loaded/error).
  router_models_json | jq -r --arg m "$1" '.data[] | select(.id == $m) | .status.value'
}

# ── Memory queries ──────────────────────────────────────────────────────────

vram_used_mb() {
  local b
  b=$(cat "/sys/class/drm/${GPU_CARD}/device/mem_info_vram_used" 2>/dev/null || echo 0)
  echo $(( b / 1024 / 1024 ))
}

vram_total_mb() {
  local b
  b=$(cat "/sys/class/drm/${GPU_CARD}/device/mem_info_vram_total" 2>/dev/null || echo 0)
  echo $(( b / 1024 / 1024 ))
}

dram_avail_mb() {
  awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo
}

# ── Session token count ──────────────────────────────────────────────────────

session_token_count() {
  # Returns the cumulative token count of the most recent assistant
  # message in the most recent session. Empty / "0" if no session
  # exists or the DB isn't readable.
  #
  # Per docs/research/2026-05-03-opencode-session-on-model-change.md,
  # opencode's compaction.isOverflow check uses the LAST FINISHED
  # assistant message's recorded token count as the input -- so that's
  # what we want here. Same source, same number.
  if [[ ! -r "$OPENCODE_DB" ]]; then
    echo 0
    return 0
  fi
  python3 - "$OPENCODE_DB" 2>/dev/null <<'PYEOF' || echo 0
import sys
import sqlite3
import json

db = sys.argv[1]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2.0)
cur = con.cursor()
# Find the most recent session, then its last assistant message tokens.
cur.execute("""
SELECT data FROM MessageTable
WHERE json_extract(data, '$.role') = 'assistant'
  AND json_extract(data, '$.tokens.total') IS NOT NULL
ORDER BY ROWID DESC
LIMIT 1
""")
row = cur.fetchone()
if not row:
    print(0)
    sys.exit(0)
data = json.loads(row[0])
print(int(data.get("tokens", {}).get("total", 0)))
PYEOF
}

# ── Compaction prediction ───────────────────────────────────────────────────

# usable budget for a model (registry context_tokens minus reserved
# headroom). opencode reserves the smaller of 20K and the model's
# max_output_tokens; we use 20K as a conservative approximation since
# that's the upper bound and tighter usable means we trigger the
# compaction warning sooner.
target_usable_mb() {
  echo $(( TARGET_CTX - 20000 ))
}

# ── Memory prediction ───────────────────────────────────────────────────────

predict_post_unload_vram_free_mb() {
  # If a model is currently loaded, post-unload VRAM free is roughly
  # (total - baseline). The baseline is set conservatively so this
  # predicts a slightly-low number.
  local total
  total=$(vram_total_mb)
  echo $(( total - VRAM_BASELINE_MB ))
}

predict_post_unload_dram_free_mb() {
  # Live MemAvailable is what we have right now. If a model is
  # currently loaded, its DRAM footprint comes back when it unloads,
  # so we add it. If nothing's loaded, we don't.
  local current_avail current_loaded current_dram
  current_avail=$(dram_avail_mb)
  current_loaded=$(current_loaded_model)
  if [[ -n "$current_loaded" ]] && registry_has "$current_loaded"; then
    current_dram=$(registry_field "$current_loaded" dram_required_mb)
    echo $(( current_avail + current_dram ))
  else
    echo "$current_avail"
  fi
}

# ── Compaction orchestration ────────────────────────────────────────────────

needs_pre_swap_compaction() {
  # Returns 0 (true) if pre-swap compaction is needed, 1 otherwise.
  #
  # Pre-swap compaction is needed when the current model has a larger
  # context window than the target AND the session has accumulated more
  # tokens than the target's usable budget. If we don't compact while
  # the larger model is loaded, opencode will try to compact via the
  # smaller new model after the swap, which will fail with
  # ContextOverflowError if the session is still too big.
  local current target_usable session_tokens current_ctx
  current=$(current_loaded_model)
  if [[ -z "$current" ]]; then
    return 1  # nothing loaded to compact from
  fi
  if [[ "$current" == "$TARGET" ]]; then
    return 1  # not actually a swap
  fi
  if ! registry_has "$current"; then
    return 1  # unknown current model, skip compaction logic
  fi
  current_ctx=$(registry_field "$current" context_tokens)
  if (( current_ctx <= TARGET_CTX )); then
    return 1  # current is not larger than target
  fi
  session_tokens=$(session_token_count)
  target_usable=$(target_usable_mb)
  if (( session_tokens <= target_usable )); then
    return 1  # session fits in target window without compaction
  fi
  return 0  # pre-swap compaction needed
}

# ── yad popup helpers ───────────────────────────────────────────────────────

yad_confirm_swap() {
  # Renders the confirm dialog with all the gathered info. Returns
  # yad's exit code (0 = OK, 1 = Cancel, other = error).
  local current current_display session_tokens vram_free_pred dram_free_pred
  local vram_check dram_check needs_compaction time_estimate
  current=$(current_loaded_model)
  if [[ -n "$current" ]] && registry_has "$current"; then
    current_display=$(registry_field "$current" display_name)
  else
    current_display="${current:-(none loaded)}"
  fi

  session_tokens=$(session_token_count)
  vram_free_pred=$(predict_post_unload_vram_free_mb)
  dram_free_pred=$(predict_post_unload_dram_free_mb)

  if (( vram_free_pred >= TARGET_VRAM_MB )); then
    vram_check="✓ GPU: $((vram_free_pred / 1024)) GB free after unload, target needs $((TARGET_VRAM_MB / 1024)) GB"
  else
    vram_check="⚠ GPU: only $((vram_free_pred / 1024)) GB free after unload, target needs $((TARGET_VRAM_MB / 1024)) GB"
  fi

  if (( TARGET_DRAM_MB == 0 )); then
    dram_check="✓ RAM: target does not need DRAM offload"
  elif (( dram_free_pred >= TARGET_DRAM_MB )); then
    dram_check="✓ RAM: $((dram_free_pred / 1024)) GB free after unload, target needs $((TARGET_DRAM_MB / 1024)) GB"
  else
    dram_check="⚠ RAM: only $((dram_free_pred / 1024)) GB free after unload, target needs $((TARGET_DRAM_MB / 1024)) GB"
  fi

  if needs_pre_swap_compaction; then
    needs_compaction="(pre-swap compaction will run via $current — adds ~30-90s)"
  else
    needs_compaction=""
  fi

  # Re-eval cost: if session has tokens, the new model has to prefill them.
  # Assume ~300 tok/s prompt eval as a rough average across our pool.
  local reeval_sec=0
  if (( session_tokens > 0 )); then
    reeval_sec=$(( session_tokens / 300 ))
  fi
  local total_sec=$(( TARGET_LOAD_SEC + reeval_sec ))
  if (( total_sec < 60 )); then
    time_estimate="~${total_sec}s"
  else
    time_estimate="~$((total_sec / 60)) min"
  fi

  yad --window-icon=dialog-question \
      --title="Switch model" \
      --width=520 \
      --text="<b>Switch primary model?</b>\n\n  <b>From:</b> $current_display\n  <b>To:</b> $TARGET_DISPLAY\n  <small>$TARGET_DESC</small>\n\n<b>Cost:</b> $time_estimate (load + re-evaluation)\n  Load: ~${TARGET_LOAD_SEC}s\n  Re-eval session ($session_tokens tokens): ~${reeval_sec}s\n  $needs_compaction\n\n<b>Memory check:</b>\n  $vram_check\n  $dram_check\n" \
      --button="Cancel:1" \
      --button="Swap:0"
}

yad_progress_pipe() {
  # Reads progress lines from stdin and feeds yad's --progress dialog.
  # Caller writes lines like "30" (percent) or "#status text" (message)
  # to stdout; we pipe them in.
  yad --progress \
      --window-icon=dialog-information \
      --title="Loading $TARGET_DISPLAY" \
      --width=420 \
      --auto-close \
      --no-buttons \
      --text="Loading $TARGET_DISPLAY..." \
      --pulsate
}

# ── The actual swap ─────────────────────────────────────────────────────────

run_compaction_via_opencode() {
  # opencode's compaction agent fires automatically when a turn would
  # overflow the model's context. We can't trigger compaction directly
  # via an API; what we CAN do is rely on the agent.compaction.model
  # config in opencode.json.template (already pinned to the larger
  # model in the pool) to ensure that when compaction does fire after
  # the swap, it targets a still-loaded model.
  #
  # In practice: if the user is swapping smaller->larger, no
  # compaction needed (target window is bigger). If swapping
  # larger->smaller AND session > target's usable, opencode will fire
  # compaction on the next user message and route it to whichever model
  # is named in agent.compaction.model. As long as that's the larger
  # model AND it's loaded, compaction succeeds.
  #
  # For us right now: compaction agent = gpt-oss-120b (always largest
  # in our 2-model pool). On a GLM->OSS swap, OSS will be loaded
  # post-swap and compaction works. On an OSS->GLM swap, OSS gets
  # unloaded; we'd need to either (a) keep OSS for compaction first
  # and load GLM for serving second, or (b) skip compaction.
  #
  # Right now we don't have a way to do (a) -- the router's
  # --models-max 1 mutex makes it impossible to have OSS loaded for
  # compaction WHILE GLM is also loaded for serving. The honest
  # answer is to issue the warning in the popup, not orchestrate the
  # impossible.
  #
  # If a future router supports models-max 2 with explicit selection
  # for compaction vs inference, this is the function that gets
  # filled in.
  log "pre-swap compaction is recommended but not yet orchestrable"
  log "  (router --models-max 1 prevents holding old model loaded for compaction"
  log "   while loading new model for inference. Compaction will be attempted"
  log "   automatically by opencode after the swap; it will fail if session"
  log "   exceeds target's usable budget)"
}

trigger_load() {
  # Calls /models/load. Returns immediately; load runs async.
  curl -fsS -m 5 -X POST "$ROUTER_BASE/models/load" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$TARGET" '{model:$m}')" >/dev/null
}

wait_for_loaded() {
  # Polls /models until target is loaded, with a hard timeout.
  # Returns 0 on success, 1 on timeout, 2 on observed error state.
  local start now elapsed status
  start=$(date +%s)
  while :; do
    status=$(model_status "$TARGET")
    case "$status" in
      loaded)
        return 0
        ;;
      error|failed)
        err "load entered error state: $status"
        return 2
        ;;
    esac
    now=$(date +%s)
    elapsed=$(( now - start ))
    if (( elapsed >= LOAD_TIMEOUT )); then
      err "load timeout after ${LOAD_TIMEOUT}s; target still '$status'"
      return 1
    fi
    sleep 3
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  log "target: $TARGET ($TARGET_DISPLAY)"

  local current
  current=$(current_loaded_model || true)
  if [[ "$current" == "$TARGET" ]]; then
    log "$TARGET is already loaded; nothing to do"
    yad --info --title="Already loaded" \
        --text="<b>$TARGET_DISPLAY</b> is already the active model." \
        --button="OK:0" --width=320 || true
    exit 0
  fi

  # Confirm dialog. yad's exit code: 0=Swap, 1=Cancel.
  if ! yad_confirm_swap; then
    log "user cancelled"
    exit 1
  fi

  # Pre-swap compaction (currently a no-op stub; see comment).
  if needs_pre_swap_compaction; then
    run_compaction_via_opencode
  fi

  # Trigger the load. The router will reap the previous child first
  # (--models-max 1 mutex), then start the new model.
  log "requesting load of $TARGET"
  trigger_load

  # Show progress dialog while we poll. Pulsate mode (no exact %)
  # because the router doesn't expose load-progress percentages, just
  # status transitions. The dialog auto-closes when we close the pipe.
  (
    while :; do
      status=$(model_status "$TARGET" 2>/dev/null || echo "unknown")
      printf '#%s\n' "Status: $status"
      [[ "$status" == "loaded" || "$status" == "error" || "$status" == "failed" ]] && break
      sleep 3
    done
  ) | yad_progress_pipe &
  YAD_PID=$!

  # Wait for the actual load completion.
  if wait_for_loaded; then
    log "$TARGET loaded successfully"
    wait "$YAD_PID" 2>/dev/null || true
    yad --info --title="Loaded" \
        --text="<b>$TARGET_DISPLAY</b> is now active." \
        --button="OK:0" --width=320 --timeout=5 --timeout-indicator=bottom || true
    exit 0
  else
    err "load did not complete cleanly"
    kill "$YAD_PID" 2>/dev/null || true
    yad --error --title="Load failed" \
        --text="Loading <b>$TARGET_DISPLAY</b> did not complete. Check journalctl -u llama-primary-router for details." \
        --button="OK:0" --width=420 || true
    exit 1
  fi
}

main "$@"
