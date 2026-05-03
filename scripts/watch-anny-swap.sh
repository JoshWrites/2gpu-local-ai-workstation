#!/usr/bin/env bash
# watch-anny-swap.sh — observe what's happening on the workstation
# during anny's model swap + first prompt. Read-only.
#
# Polls every 2s, prints a one-screen snapshot with:
#   - llama-primary-router status (loaded model? VRAM in use?)
#   - model-swap-remote.sh activity in the journal
#   - opencode-patched process state
#   - GPU VRAM (the big GPU is where primary models live)
#
# Ctrl-C to exit.

set -uo pipefail

INTERVAL=2

draw() {
  clear
  printf "\e[1m== %s ==\e[0m\n" "$(date +%H:%M:%S)"

  echo ""
  echo "── llama-primary-router (port 11434) ──"
  curl -s --max-time 1 http://127.0.0.1:11434/v1/models 2>/dev/null \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for m in data.get("data", []):
        print(f"  loaded: {m.get(\"id\")}")
    if not data.get("data"):
        print("  (no model loaded — router is idle)")
except Exception:
    print("  (no response from router)")
'

  echo ""
  echo "── llama-primary-router journal (last 8 lines) ──"
  sudo journalctl -u llama-primary-router.service -n 8 --no-pager 2>&1 \
    | tail -8 | sed 's/^/  /'

  echo ""
  echo "── model-swap activity (last 5 lines from system journal) ──"
  sudo journalctl --since "30 seconds ago" --no-pager 2>&1 \
    | grep -iE 'model-swap|model_swap|swap.sh' | tail -5 | sed 's/^/  /'
  if ! sudo journalctl --since "30 seconds ago" --no-pager 2>&1 | grep -qiE 'model-swap|swap.sh'; then
    echo "  (no recent swap activity in journal)"
  fi

  echo ""
  echo "── anny processes (model-swap, opencode, ssh) ──"
  ps -u anny -o pid,etime,comm,args 2>/dev/null \
    | grep -E 'opencode|model-swap|sshfs|ssh\s' | grep -v grep | sed 's/^/  /' \
    | head -10
  if ! ps -u anny -o args 2>/dev/null | grep -qE 'opencode|model-swap'; then
    echo "  (no swap/opencode process visible)"
  fi

  echo ""
  echo "── GPU VRAM ──"
  rocm-smi --showmeminfo vram 2>&1 | grep -E 'GPU\[' | sed 's/^/  /'

  echo ""
  echo "── /mnt/anny-laptop mount + sshfs daemon ──"
  grep sshfs /proc/mounts | grep anny | sed 's/^/  /' || echo "  (no anny sshfs mount)"
  pgrep -af 'sshfs.*anny-laptop' | sed 's/^/  /' || echo "  (no sshfs daemon)"

  echo ""
  printf "\e[2m(refresh every %ss — Ctrl-C to exit)\e[0m\n" "$INTERVAL"
}

while true; do
  draw
  sleep "$INTERVAL"
done
