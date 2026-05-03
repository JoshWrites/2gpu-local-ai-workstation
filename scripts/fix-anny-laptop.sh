#!/usr/bin/env bash
# fix-anny-laptop.sh — apply the two fixes diagnose-anny-laptop.sh surfaced:
#   1. Deploy the patched opencode-remote-session to ~/bin/ on the laptop
#      (overwriting the stale standalone copy; not a git checkout).
#   2. Restart wg-quick@wg0 on the laptop so wg0 gets its IP back after the
#      address quietly disappeared (likely from sleep/resume).
#
# Backs up the laptop's current launcher to ~/bin/opencode-remote-session.bak
# before overwriting. Needs sudo on workstation (for `sudo -u anny`) AND on
# the laptop (for `systemctl restart`) — uses ssh -t for the laptop password.

set -uo pipefail

LAPTOP_HOST="laptop"
ANNY_LAPTOP_USER="anny"
SRC_LAUNCHER="/home/levine/Documents/Repos/2gpu-local-ai-workstation/scripts/laptop/opencode-remote-session"
DST_LAUNCHER='~/bin/opencode-remote-session'

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; }

ssh_anny()    { sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" "$@"; }
ssh_anny_t()  { sudo    -u anny ssh -t -o ConnectTimeout=5             "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" "$@"; }

# ─── Sanity: source file present and patched ─────────────────────────────────

hdr "Source: workstation copy of launcher"
if [[ ! -f "$SRC_LAUNCHER" ]]; then
  bad "$SRC_LAUNCHER not found"; exit 1
fi
if ! grep -q 'timeout 3 ls' "$SRC_LAUNCHER"; then
  bad "$SRC_LAUNCHER does not contain the 'timeout 3 ls' fix — refusing to deploy"; exit 1
fi
ok "$SRC_LAUNCHER present and patched"

# ─── Step 1: backup + copy launcher to laptop ────────────────────────────────

hdr "Laptop: backup current launcher"
ssh_anny "cp ${DST_LAUNCHER} ${DST_LAUNCHER}.bak.\$(date +%Y%m%d-%H%M%S) && ls -la ${DST_LAUNCHER}.bak.* 2>/dev/null | tail -3"
ok "backup written"

hdr "Laptop: deploy patched launcher (scp via anny)"
# anny can't read /home/levine/... so stage the file in /tmp with world-read
# perms first, then scp from there.
STAGED="/tmp/opencode-remote-session.$$"
cp "$SRC_LAUNCHER" "$STAGED"
chmod 0644 "$STAGED"
trap 'rm -f "$STAGED"' EXIT
if ! sudo -n -u anny scp -o BatchMode=yes -o ConnectTimeout=5 \
       "$STAGED" "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}:bin/opencode-remote-session"; then
  bad "scp failed — aborting"; exit 1
fi
ssh_anny "chmod +x ${DST_LAUNCHER} && ls -la ${DST_LAUNCHER}"
ok "launcher deployed"

hdr "Laptop: verify patch is in place"
verify=$(ssh_anny "grep -c 'timeout 3 ls' ${DST_LAUNCHER}")
if [[ "$verify" -ge 1 ]]; then
  ok "patch present in deployed launcher"
else
  bad "patch missing after deploy — investigate"; exit 1
fi

# ─── Step 2: restart wg-quick@wg0 on the laptop ──────────────────────────────

hdr "Laptop: wg0 state BEFORE restart"
ssh_anny 'ip -4 addr show wg0 2>&1 | grep -E "inet|state" || echo "  (no inet)"'

hdr "Laptop: restart wg-quick@wg0 (will prompt for sudo password on laptop)"
ssh_anny_t 'sudo systemctl restart wg-quick@wg0 && echo OK_RESTART'

hdr "Laptop: wg0 state AFTER restart"
ssh_anny 'sleep 1; ip -4 addr show wg0'

hdr "Laptop: WireGuard handshake check"
ssh_anny_t 'sudo wg show wg0 latest-handshakes endpoints' 2>&1 | head -10

# ─── Final ───────────────────────────────────────────────────────────────────

cat <<'EOF'

== Done ==

Re-run the readiness check:
  sudo /home/levine/Documents/Repos/2gpu-local-ai-workstation/scripts/check-anny-remote-ready.sh

Note: the readiness script looks for the launcher in
~/Documents/Repos/2gpu-local-ai-workstation/scripts/laptop/. Anny's actual
launcher lives at ~/bin/opencode-remote-session. The readiness script's
"launcher script missing" check will keep reporting failure until either
(a) the readiness script is updated, or (b) anny clones the repo.
For now, manual verification is in this script's output above.
EOF
