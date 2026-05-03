#!/usr/bin/env bash
# model-swap-remote.sh -- swap dispatcher that routes between local
# (yad popup) and remote (chat-message) UX based on session origin.
#
# Usage:
#   model-swap-remote.sh <target-model-id>
#
# The opencode router-swap patch shells this script out as
# `OPENCODE_MODEL_SWAP_SCRIPT`. Behavior:
#
#   - WS_REMOTE_SESSION=1 set (we are running on the workstation but
#     opencode was invoked over SSH from a laptop): emit progress to
#     stdout (which opencode forwards to chat as session events) and
#     do the load+poll WITHOUT yad. No popup, because the user can't
#     see the workstation's display.
#
#   - WS_REMOTE_SESSION unset (we are running for a local user with a
#     real X session): delegate to model-swap.sh as today (yad
#     confirm dialog + progress popup).
#
# This script is the entry point; model-swap.sh is the local-display
# implementation. Splitting the dispatcher from the implementation
# keeps the local UX identical to what was tested on 2026-05-03 and
# adds remote support without restructuring the existing script.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${WS_PRIMARY_POOL:-${REPO}/configs/workstation/primary-pool.json}"
ROUTER_BASE="${WS_ROUTER_BASE:-http://127.0.0.1:11434}"

LOAD_TIMEOUT=900
POLL_INTERVAL=5

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <target-model-id>" >&2
  exit 2
fi

TARGET="$1"

# ── Local path: delegate to the yad-driven implementation ────────────────────

if [[ -z "${WS_REMOTE_SESSION:-}" ]]; then
  exec "${REPO}/scripts/model-swap.sh" "$TARGET"
fi

# ── Remote path: chat-message progress, no yad ───────────────────────────────

# Progress goes to stdout. The opencode router-swap patch forwards
# the script's stdout into the session as a Session.Event message
# (per-line). Keep lines short and informative.

say() { printf '%s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    say "ERROR: missing required command on workstation: $1"
    exit 1
  }
}

require_cmd curl
require_cmd jq

[[ -r "$REGISTRY" ]] || {
  say "ERROR: model registry missing on workstation: $REGISTRY"
  exit 1
}

registry_field() {
  jq -r --arg m "$1" --arg f "$2" '.models[$m][$f] // empty' "$REGISTRY"
}

router_models_json() {
  curl -fsS -m 5 "$ROUTER_BASE/models"
}

model_status() {
  router_models_json | jq -r --arg m "$1" '.data[] | select(.id == $m) | .status.value'
}

# Sanity: target must be in the registry.
if ! jq -e --arg m "$TARGET" '.models[$m]' "$REGISTRY" >/dev/null 2>&1; then
  say "ERROR: '$TARGET' is not a known model in the primary pool."
  say "Known: $(jq -r '.models | keys | join(", ")' "$REGISTRY")"
  exit 1
fi

DISPLAY_NAME="$(registry_field "$TARGET" display_name)"
EXPECTED_LOAD_S="$(registry_field "$TARGET" expected_load_seconds)"
[[ -n "$EXPECTED_LOAD_S" ]] || EXPECTED_LOAD_S=240

# Sanity: target must already be in the router's known model list.
if ! router_models_json | jq -e --arg m "$TARGET" '.data[] | select(.id == $m)' >/dev/null 2>&1; then
  say "ERROR: router doesn't know about '$TARGET'."
  say "       Check /etc/workstation/llama-router.ini has a [$TARGET] section."
  exit 1
fi

CURRENT_STATUS="$(model_status "$TARGET")"

if [[ "$CURRENT_STATUS" == "loaded" ]]; then
  say "Model $TARGET is already loaded; continuing."
  exit 0
fi

# Print expected load time in human form.
if (( EXPECTED_LOAD_S < 60 )); then
  ETA="~${EXPECTED_LOAD_S}s"
else
  ETA="~$(( EXPECTED_LOAD_S / 60 )) min"
fi

say "Switching primary model to $DISPLAY_NAME ($TARGET)."
say "Estimated load time: $ETA. You'll see a confirmation when ready."

# Trigger load. Returns immediately; load runs async on the router.
if ! curl -fsS -m 10 -X POST "$ROUTER_BASE/models/load" \
       -H 'Content-Type: application/json' \
       -d "$(jq -nc --arg m "$TARGET" '{model:$m}')" >/dev/null; then
  say "ERROR: /models/load request failed."
  exit 1
fi

# Poll. Emit a heartbeat every ~30s so the user knows we're still
# working; opencode delivers each line as a chat event.
START_TS=$(date +%s)
LAST_HEARTBEAT=$START_TS

while :; do
  NOW_TS=$(date +%s)
  ELAPSED=$(( NOW_TS - START_TS ))

  if (( ELAPSED >= LOAD_TIMEOUT )); then
    say "ERROR: load timed out after ${LOAD_TIMEOUT}s. Check workstation logs:"
    say "       journalctl -u llama-primary-router.service -n 100"
    exit 1
  fi

  STATUS="$(model_status "$TARGET" 2>/dev/null || echo unknown)"
  case "$STATUS" in
    loaded)
      say "$DISPLAY_NAME loaded after ${ELAPSED}s. Retrying your message."
      exit 0
      ;;
    error|failed|loading-error)
      say "ERROR: load entered $STATUS state. Workstation log:"
      say "       journalctl -u llama-primary-router.service -n 100"
      exit 1
      ;;
    loading|unloaded|"")
      # still working
      ;;
    *)
      # unknown status; keep waiting but note it
      ;;
  esac

  # Heartbeat every ~30s
  if (( NOW_TS - LAST_HEARTBEAT >= 30 )); then
    say "Still loading $TARGET... ${ELAPSED}s elapsed (status: $STATUS)."
    LAST_HEARTBEAT=$NOW_TS
  fi

  sleep "$POLL_INTERVAL"
done
