#!/usr/bin/env bash
# 2GPU launcher: starts the system-scoped llama services and
# opens Zed in an isolated profile, with a yad progress splash.
#
# Lifecycle:
#   1. If llama is already up (a terminal opencode, a second user, an
#      earlier launch), skip the splash and go straight to Zed.
#   2. Otherwise: start llama-primary/secondary/embed/coder (system
#      units; polkit grants the local users passwordless start), show
#      a yad splash that tails the journal, poll /v1/models on each
#      port until ready.
#   3. Open Zed.
#   4. If invoked with one or more path arguments, run Zed under
#      `--wait`, block until the editor closes, then call
#      `llama-shutdown` for polite GPU release. The shutdown refuses
#      if any other user or process is still using llama.
#   5. If invoked with no path arguments, run Zed detached. Polite
#      shutdown is the user's responsibility (run `llama-shutdown`
#      when done to free VRAM, important for gaming after coding).
#
# Zed's `--wait` flag requires at least one path argument. The split
# in step 4 vs 5 accommodates that requirement.
#
# Polite-shutdown holder detection (called in step 4) uses an age
# filter: opencode/zed processes younger than 30 seconds are excluded
# as likely teardown children of an editor that just closed, so
# closing Zed and letting the launcher run llama-shutdown does the
# right thing. See systemd/llama-shutdown for the implementation.
#
# yad thresholds are tuned for ~60s expected ready (universal; terminal
# opencode launches have always cleared this). Warn at 75s, 180s ceiling.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Env files ───────────────────────────────────────────────────────────────

# Hardware identity, port assignments, and other system-wide values come
# from /etc/workstation/system.env. Per-user paths come from
# ~/.config/workstation/user.env. Both must exist; see
# configs/workstation/README.md for the install steps.

if [[ ! -r /etc/workstation/system.env ]]; then
  echo "ERROR: /etc/workstation/system.env not readable." >&2
  echo "       See $REPO/configs/workstation/README.md for install steps." >&2
  exit 1
fi
. /etc/workstation/system.env

if [[ ! -r "$HOME/.config/workstation/user.env" ]]; then
  echo "ERROR: ~/.config/workstation/user.env not readable." >&2
  echo "       See $REPO/configs/workstation/README.md for install steps." >&2
  exit 1
fi
. "$HOME/.config/workstation/user.env"

# ── Config derived from env ─────────────────────────────────────────────────

LLAMA_UNITS=(llama-primary llama-secondary llama-embed llama-coder)
ENDPOINTS=(
  "$WS_PORT_PRIMARY"
  "$WS_PORT_SECONDARY"
  "$WS_PORT_EMBED"
  "$WS_PORT_CODER"
)
PRIMARY_UNIT="llama-primary.service"   # the one whose journal we tail in the splash
EXPECTED_READY=60
WARN_READY=75
HARD_TIMEOUT=180

ZED_DATA_DIR="$WS_ZED_PROFILE_DIR"
ZED_BIN="$HOME/.local/bin/zed"

# ── Args ────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<EOF
Usage: 2gpu-launch.sh [-- zed args...]

Starts llama-primary/secondary/embed/coder, shows a yad splash until
ready, then opens Zed in the isolated Zed profile.

If invoked with one or more path arguments after a literal --,
Zed runs under --wait and the script blocks until the editor closes,
then calls llama-shutdown for polite GPU release.

If invoked with no path arguments (the normal desktop-launcher path),
Zed runs detached. Run llama-shutdown manually when done to free
GPU memory.
EOF
      exit 0
      ;;
    --) shift; break ;;
    *)  break ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────

notify() {
  notify-send --app-name="2GPU Workstation" "$1" "${2:-}" || true
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
  # System-scoped units; polkit rule grants the configured local users
  # passwordless start (see systemd/polkit/10-llama-services.rules).
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
  # Zed's --wait flag requires at least one path argument. With a path,
  # the script blocks until the window closes and we can run polite
  # shutdown on return. Without a path, Zed prints a usage error and
  # exits, so we drop --wait and let Zed run detached. Polite shutdown
  # then has to be invoked manually after a no-path launch.
  if [[ $# -gt 0 ]]; then
    "$ZED_BIN" \
      --user-data-dir "$ZED_DATA_DIR" \
      --wait \
      "$@"
  else
    "$ZED_BIN" \
      --user-data-dir "$ZED_DATA_DIR" \
      "$@"
  fi
}

editor_will_block() {
  # Tells the calling code whether launch_editor will block until Zed
  # closes (true) or return immediately (false). The polite-shutdown
  # call only makes sense when launch_editor blocks.
  [[ $# -gt 0 ]]
}

# ── Fast path: llama already up ─────────────────────────────────────────────

if llama_all_up; then
  notify "2GPU" "llama already running. Opening Zed."
  if editor_will_block "$@"; then
    launch_editor "$@"
    llama-shutdown || notify "2GPU" "llama-shutdown declined to stop (someone still using it)."
  else
    launch_editor "$@"
    notify "2GPU" "Zed launched detached. Run llama-shutdown when finished to free GPU memory."
  fi
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

  yad --title="2GPU - starting" \
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
      notify "2GPU - slow start" "Past ${WARN_READY}s. Check the splash log for the hung phase."
    fi
  ) &
  WATCHDOG_PID=$!
else
  notify "2GPU" "Starting llama (yad not installed; no splash)."
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
    notify "2GPU - ready" "Up in ${ELAPSED}s. Opening Zed."
    ;;
  2)
    # User clicked Cancel on the yad splash. Stop what we started.
    llama-shutdown -f >/dev/null 2>&1 || true
    notify "2GPU" "Launch cancelled."
    exit 1
    ;;
  *)
    notify "2GPU - failed" \
      "llama did not become healthy within ${HARD_TIMEOUT}s. journalctl -u ${PRIMARY_UNIT}"
    exit 1
    ;;
esac

# ── Run editor; politely shut down on exit when blocking ────────────────────

launch_editor "$@"

if editor_will_block "$@"; then
  if llama-shutdown; then
    notify "2GPU - stopped" "llama stopped, VRAM released."
  else
    notify "2GPU" "llama still in use by another session. Services left running."
  fi
else
  notify "2GPU" "Zed launched detached. Run llama-shutdown when finished to free GPU memory."
fi
