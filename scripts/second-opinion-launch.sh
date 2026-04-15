#!/usr/bin/env bash
# Second Opinion launcher: starts llama-server + VSCodium with progress UI.
#
# Flow:
#   1. Decide cold vs warm based on a boot-marker file.
#   2. Start the llama-second-opinion.service unit.
#   3. Show a yad progress dialog that tails the journal and highlights the
#      current phase. Kill the dialog when /health reports ok.
#   4. Start codium-second-opinion.service (which Requires llama).
#   5. Wait for codium service to stop. Shut llama down. Toast notification.
#
# Phase thresholds derived from bench-llama-startup.sh (3 cold + 7 warm runs).
# Alerts fire at "warn" level, not hard fail — this is diagnostic, not fatal.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT_MARKER="/tmp/second-opinion-launched-this-boot"
LLAMA_UNIT="llama-second-opinion.service"
CODIUM_UNIT="codium-second-opinion.service"

# ---------- cold vs warm detection ----------
# A marker file in /tmp is cleared every boot. First launch after boot is cold.
if [[ -f "$BOOT_MARKER" ]]; then
  STATE="warm"
  EXPECTED_READY=5
  WARN_READY=10
  EXPECTED_TENSOR=4
  WARN_TENSOR=8
else
  STATE="cold"
  EXPECTED_READY=40
  WARN_READY=55
  EXPECTED_TENSOR=40
  WARN_TENSOR=50
fi

# ---------- helpers ----------
notify() {
  notify-send --app-name="Second Opinion" "$1" "${2:-}" || true
}

have_yad() { command -v yad >/dev/null 2>&1; }

# ---------- start llama ----------
# If already up (user relaunching the launcher while an editor is open), skip.
if systemctl --user is-active --quiet "$LLAMA_UNIT"; then
  notify "Second Opinion" "llama-server already running; launching editor."
  systemctl --user start "$CODIUM_UNIT"
  exit 0
fi

systemctl --user start "$LLAMA_UNIT"
START_EPOCH=$(date +%s)

# ---------- yad splash with journal tail + phase timer ----------
if have_yad; then
  # Pipe: journal tail filtered to interesting lines → yad text-info window.
  # Phase timer: a background awk that watches the same stream and emits
  # phase-change lines that yad will highlight by virtue of being at the tail.
  SPLASH_FIFO=$(mktemp -u)
  mkfifo "$SPLASH_FIFO"

  # Tail the llama unit's journal.
  journalctl --user -u "$LLAMA_UNIT" -f --since=now -o cat 2>/dev/null \
    | stdbuf -oL grep -E "ROCm devices|load_tensors|llama_context:|llama_kv_cache: size|warming up|server is listening|error|failed|Aborted|Killed" \
    > "$SPLASH_FIFO" &
  TAIL_PID=$!

  # Fire yad in the background; it exits when the FIFO closes.
  yad --title="Second Opinion — starting" \
      --text="<b>Loading Qwen3-Coder-30B onto 7900 XTX (${STATE} cache)</b>\nExpected ready: ~${EXPECTED_READY}s. Warning if &gt; ${WARN_READY}s.\n\nLive log:" \
      --text-info \
      --tail \
      --width=820 --height=420 \
      --button="Cancel launch:1" \
      --no-escape \
      --on-top \
      --fontname="monospace 9" \
      < "$SPLASH_FIFO" &
  YAD_PID=$!

  # Watchdog: emit a warning toast if we pass the warn threshold without ready.
  (
    sleep "$WARN_READY"
    if ! curl -fs --max-time 0.5 http://127.0.0.1:11434/health >/dev/null 2>&1; then
      notify "Second Opinion — slow start" "Past ${WARN_READY}s on a ${STATE} launch. Check the splash log for the hung phase."
    fi
  ) &
  WATCHDOG_PID=$!
else
  notify "Second Opinion" "Starting llama-server (yad not installed — no splash)."
  WATCHDOG_PID=""
  YAD_PID=""
  TAIL_PID=""
fi

# ---------- poll for health ----------
READY=0
for i in $(seq 1 180); do
  if curl -fs --max-time 0.5 http://127.0.0.1:11434/health >/dev/null 2>&1; then
    READY=1; break
  fi
  # If user clicked Cancel on yad, stop and abort.
  if [[ -n "${YAD_PID:-}" ]] && ! kill -0 "$YAD_PID" 2>/dev/null; then
    # yad exited — check if it was the cancel button (exit 1) vs our kill.
    # We only kill yad after READY=1, so if we're here and yad is gone, user cancelled.
    systemctl --user stop "$LLAMA_UNIT" || true
    [[ -n "${TAIL_PID:-}" ]] && kill "$TAIL_PID" 2>/dev/null || true
    [[ -n "${WATCHDOG_PID:-}" ]] && kill "$WATCHDOG_PID" 2>/dev/null || true
    notify "Second Opinion" "Launch cancelled."
    exit 1
  fi
  sleep 1
done

ELAPSED=$(( $(date +%s) - START_EPOCH ))

# Clean up splash + watchdog regardless of outcome.
[[ -n "${YAD_PID:-}" ]] && kill "$YAD_PID" 2>/dev/null || true
[[ -n "${TAIL_PID:-}" ]] && kill "$TAIL_PID" 2>/dev/null || true
[[ -n "${WATCHDOG_PID:-}" ]] && kill "$WATCHDOG_PID" 2>/dev/null || true
[[ -n "${SPLASH_FIFO:-}" ]] && rm -f "$SPLASH_FIFO"

if [[ "$READY" != 1 ]]; then
  notify "Second Opinion — failed" "llama-server did not become healthy within 180s. See: journalctl --user -u ${LLAMA_UNIT}"
  exit 1
fi

touch "$BOOT_MARKER"
notify "Second Opinion — ready" "Launched in ${ELAPSED}s (${STATE}). Opening editor…"

# ---------- start codium and wait ----------
systemctl --user start "$CODIUM_UNIT"

# Wait for the codium unit to go inactive (user closed the editor).
while systemctl --user is-active --quiet "$CODIUM_UNIT"; do
  sleep 2
done

# codium stopped → stop llama (no systemd reverse-dep; see the unit file).
systemctl --user stop "$LLAMA_UNIT" 2>/dev/null || true

notify "Second Opinion — stopped" "llama-server stopped, VRAM released."
