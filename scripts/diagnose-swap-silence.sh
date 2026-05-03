#!/usr/bin/env bash
# diagnose-swap-silence.sh — anny's swap completed but she got no
# in-chat progress. Figure out which leg failed:
#   A. WS_REMOTE_SESSION wasn't set, so the script took the local
#      (yad) branch and failed silently.
#   B. WS_REMOTE_SESSION was set, but opencode-patched isn't
#      forwarding the script's stdout into the session.
#   C. The swap script never actually ran (no journal line shows it).

set -uo pipefail

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }

# ─── A. What env did opencode-patched start with? ────────────────────────────

hdr "Env of running opencode-patched (anny's process)"
PID=$(pgrep -u anny -f opencode-patched 2>/dev/null | head -1)
if [[ -z "$PID" ]]; then
  echo "  no opencode-patched running for anny"
else
  echo "  PID: $PID"
  sudo tr '\0' '\n' < "/proc/$PID/environ" 2>&1 | grep -E '^(WS_|OPENCODE_|DISPLAY|HOME|USER)' | sort
fi

# ─── B. Did model-swap-remote.sh run recently? ───────────────────────────────

hdr "model-swap-remote.sh execution evidence (last 30 min)"
echo "--- as a process (probably gone now) ---"
ps -ef --sort=start_time 2>/dev/null | grep -E 'model-swap' | grep -v grep || echo "  (none currently running)"

echo ""
echo "--- in journal: anything mentioning model-swap or the swap script ---"
sudo journalctl --since "30 min ago" --no-pager 2>&1 \
  | grep -iE 'model-swap|swap.sh|/models/load' | tail -20 \
  || echo "  (nothing in journal)"

# ─── C. Is opencode-patched even configured for swap? ────────────────────────

hdr "opencode-patched: search binary for swap-script handling"
strings /usr/local/bin/opencode-patched 2>/dev/null \
  | grep -iE 'OPENCODE_MODEL_SWAP_SCRIPT|model_swap|swap_script' | head -10 \
  || echo "  (no swap-related strings — the swap-script feature might not be in this build)"

# ─── D. Did the router actually receive a /models/load? ──────────────────────

hdr "Router journal: /models/load requests in last 30 min"
sudo journalctl -u llama-primary-router.service --since "30 min ago" --no-pager 2>&1 \
  | grep -iE 'POST /models/load|models/load|switch|load.*model' | tail -20 \
  || echo "  (no load requests visible)"

# ─── E. What's currently loaded? ─────────────────────────────────────────────

hdr "Router state right now (currently loaded model)"
curl -s --max-time 2 http://127.0.0.1:11434/v1/models 2>&1 \
  | python3 -m json.tool 2>&1 | head -30 || echo "  (router unreachable)"

cat <<'EOF'

== How to read the output ==

  - If env (A) shows WS_REMOTE_SESSION=1 → the launcher set it correctly.
    If missing → that's the bug.
  - If swap-script wasn't run (B is empty) → opencode-patched never invoked
    OPENCODE_MODEL_SWAP_SCRIPT, so the swap happened via a different code
    path with no progress emission.
  - If (C) shows no swap-related strings in the binary → opencode-patched
    doesn't have the swap-script feature; she got swap via raw
    /models/load with no progress wiring. UX gap is on the opencode side.
  - If router journal (D) shows the load happened but (B) is empty →
    opencode hit /models/load directly, bypassing the script.
EOF
