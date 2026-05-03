#!/usr/bin/env bash
# redeploy-anny-launcher.sh — push the workstation copy of
# scripts/laptop/opencode-remote-session to anny's laptop at
# ~/bin/opencode-remote-session. Backs up the old one first.
# Verifies the new check (`mountpoint -q`) is present after deploy.

set -uo pipefail

LAPTOP_HOST="laptop"
ANNY_LAPTOP_USER="anny"
SRC="/home/levine/Documents/Repos/2gpu-local-ai-workstation/scripts/laptop/opencode-remote-session"
DST_REL="bin/opencode-remote-session"
EXPECT_PATTERN='mountpoint -q'

ssh_anny() { sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" "$@"; }
hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; exit 1; }

# Verify source has the new check
hdr "Source: confirm new check is present in workstation copy"
[[ -f "$SRC" ]] || bad "$SRC not found"
grep -q "$EXPECT_PATTERN" "$SRC" || bad "$SRC does not contain '$EXPECT_PATTERN' — refusing to deploy"
ok "source contains '$EXPECT_PATTERN'"

# Stage to /tmp with anny-readable perms
STAGED=$(mktemp /tmp/opencode-remote-session.XXXXXX)
trap 'rm -f "$STAGED"' EXIT
cp "$SRC" "$STAGED"
chmod 0644 "$STAGED"

# Backup current laptop copy
hdr "Backup current launcher on laptop"
ssh_anny "cp ~/$DST_REL ~/${DST_REL}.bak.\$(date +%Y%m%d-%H%M%S)" && ok "backup taken" || bad "backup failed"

# Deploy
hdr "scp patched launcher to laptop"
sudo -n -u anny scp -o BatchMode=yes -o ConnectTimeout=5 \
  "$STAGED" "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}:${DST_REL}" || bad "scp failed"
ssh_anny "chmod +x ~/${DST_REL}" || bad "chmod failed"
ok "deployed"

# Verify
hdr "Verify new check is present on laptop"
verify=$(ssh_anny "grep -c '$EXPECT_PATTERN' ~/${DST_REL}")
if [[ "$verify" -ge 1 ]]; then
  ok "patch present on laptop"
else
  bad "patch NOT present on laptop after deploy — investigate"
fi

hdr "Show the actual deployed mount-check block (lines 38-50)"
ssh_anny "sed -n '38,50p' ~/${DST_REL}"

cat <<'EOF'

== Done ==

Anny can re-launch from Zed now. The launcher will correctly detect
that /mnt/anny-laptop is NOT a mount (just an empty dir), and will
take the "fresh mount" branch instead of falsely claiming "alive".
EOF
