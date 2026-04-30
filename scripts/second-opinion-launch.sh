#!/usr/bin/env bash
# Second Opinion launcher: starts the system-scoped llama services and
# Zed in an isolated profile, with a yad progress splash. Politely
# shuts llama down when Zed exits.
#
# Lifecycle:
#   1. If llama is already up (terminal opencode, anny, an earlier launch),
#      skip the splash and go straight to Zed.
#   2. Otherwise: start llama-primary/secondary/embed/coder (system units;
#      polkit grants levine and anny passwordless), show a yad splash that
#      tails the journal, poll /v1/models on each port until ready.
#   3. Run zed --wait in the foreground with the second-opinion isolated
#      profile.
#   4. On Zed exit: call llama-shutdown. It refuses if anyone (the other
#      user, or a still-alive opencode/zed process under the holder check)
#      is still using llama, leaving services up.
#
# yad thresholds are tuned for ~60s expected ready (universal; terminal
# opencode launches have always cleared this). Warn at 75s, 180s ceiling.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Config ──────────────────────────────────────────────────────────────────

LLAMA_UNITS=(llama-primary llama-secondary llama-embed llama-coder)
ENDPOINTS=(11434 11435 11437 11438)
PRIMARY_UNIT="llama-primary.service"   # the one whose journal we tail in the splash
EXPECTED_READY=60
WARN_READY=75
HARD_TIMEOUT=180

ZED_DATA_DIR="${HOME}/.local/share/zed-second-opinion"

# ── Args ────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<EOF
Usage: second-opinion-launch.sh [-- zed args...]

Starts llama-primary/secondary/embed/coder, shows a yad splash until
ready, then opens Zed in the second-opinion isolated profile. Polite
llama shutdown on Zed exit.
EOF
      exit 0
      ;;
    --) shift; break ;;
    *)  break ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────

notify() {
  notify-send --app-name="Second Opinion" "$1" "${2:-}" || true
}

have_yad() { command -v yad >/dev/null 2>&1; }

llama_all_up() {
  local p
  for p in "${ENDPOINTS[@]}"; do
    curl -fs --max-time 1 "http://127.0.0.1:${p}/v1/models" >/dev/null 2>&1 || return 1
  done
  return 0
}

start_llama() {
  # System-scoped units; polkit rule grants levine+anny passwordless start.
  systemctl start "${LLAMA_UNITS[@]/%/.service}"
}

poll_until_ready() {
  local start_ts deadline
  start_ts=$(date +%s)
  deadline=$(( start_ts + HARD_TIMEOUT ))
  while :; do
    if llama_all_up; then
      echo $(( $(date +%s) - start_ts ))
      return 0
    fi
    # Caller may pass a yad PID via $1; abort if the user clicked Cancel.
    if [[ -n "${1:-}" ]] && ! kill -0 "$1" 2>/dev/null; then
      return 2  # cancelled
    fi
    if (( $(date +%s) >= deadline )); then
      return 1  # timed out
    fi
    sleep 1
  done
}

launch_editor() {
  mkdir -p "$ZED_DATA_DIR"
  # --wait keeps zed foregrounded until the window closes, so the script
  # blocks here and we can shut llama down on return.
  /home/levine/.local/bin/zed \
    --user-data-dir "$ZED_DATA_DIR" \
    --wait \
    "$@"
}

# ── Fast path: llama already up ─────────────────────────────────────────────

if llama_all_up; then
  notify "Second Opinion" "llama already running. Opening Zed."
  launch_editor "$@"
  llama-shutdown || notify "Second Opinion" "llama-shutdown declined to stop (someone still using it)."
  exit 0
fi

# ── Cold path: bring llama up with splash ───────────────────────────────────

start_llama
START_EPOCH=$(date +%s)

YAD_PID=""
TAIL_PID=""
WATCHDOG_PID=""
SPLASH_FIFO=""

if have_yad; then
  SPLASH_FIFO=$(mktemp -u)
  mkfifo "$SPLASH_FIFO"

  # Tail the primary unit's journal. It is the heaviest load and the most
  # informative for "what phase are we in." Secondary, embed, and coder come
  # up much faster.
  journalctl -u "$PRIMARY_UNIT" -f --since=now -o cat 2>/dev/null \
    | stdbuf -oL grep -E "ROCm devices|load_tensors|llama_context:|llama_kv_cache: size|warming up|server is listening|error|failed|Aborted|Killed" \
    > "$SPLASH_FIFO" &
  TAIL_PID=$!

  yad --title="Second Opinion - starting" \
      --text="<b>Loading models onto 7900 XTX + 5700 XT</b>\nExpected ready: ~${EXPECTED_READY}s. Warning if &gt; ${WARN_READY}s.\n\nLive log (llama-primary):" \
      --text-info \
      --tail \
      --width=820 --height=420 \
      --button="Cancel launch:1" \
      --no-escape \
      --on-top \
      --fontname="monospace 9" \
      < "$SPLASH_FIFO" &
  YAD_PID=$!

  (
    sleep "$WARN_READY"
    if ! llama_all_up; then
      notify "Second Opinion - slow start" "Past ${WARN_READY}s. Check the splash log for the hung phase."
    fi
  ) &
  WATCHDOG_PID=$!
else
  notify "Second Opinion" "Starting llama (yad not installed; no splash)."
fi

set +e
ELAPSED=$(poll_until_ready "${YAD_PID:-}")
RC=$?
set -e

# Tear down splash artifacts regardless of outcome.
[[ -n "$YAD_PID"      ]] && kill "$YAD_PID"      2>/dev/null || true
[[ -n "$TAIL_PID"     ]] && kill "$TAIL_PID"     2>/dev/null || true
[[ -n "$WATCHDOG_PID" ]] && kill "$WATCHDOG_PID" 2>/dev/null || true
[[ -n "$SPLASH_FIFO"  ]] && rm -f "$SPLASH_FIFO" || true

case "$RC" in
  0)
    notify "Second Opinion - ready" "Up in ${ELAPSED}s. Opening Zed."
    ;;
  2)
    # User clicked Cancel on the yad splash. Stop what we started.
    llama-shutdown -f >/dev/null 2>&1 || true
    notify "Second Opinion" "Launch cancelled."
    exit 1
    ;;
  *)
    notify "Second Opinion - failed" \
      "llama did not become healthy within ${HARD_TIMEOUT}s. journalctl -u ${PRIMARY_UNIT}"
    exit 1
    ;;
esac

# ── Run editor in foreground; politely shut down on exit ────────────────────

launch_editor "$@"

if llama-shutdown; then
  notify "Second Opinion - stopped" "llama stopped, VRAM released."
else
  notify "Second Opinion" "llama still in use by another session. Services left running."
fi
