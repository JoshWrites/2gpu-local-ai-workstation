#!/usr/bin/env bash
# sync-anny-agents-md.sh — copy the canonical AGENTS.md from anny's
# repo clone to her opencode config dir, replacing the stale copy.
# Per docs/remote-user-setup.md A4, this must be a real copy (not a
# symlink) because opencode does not follow symlinks for global rules.
#
# Backs up the old copy first, then verifies hashes match after copy.

set -uo pipefail

ANNY_REPO_SRC="/home/anny/Documents/Repos/2gpu-local-ai-workstation/configs/opencode/AGENTS.md"
LEVINE_REPO_SRC="/home/levine/Documents/Repos/2gpu-local-ai-workstation/configs/opencode/AGENTS.md"
ANNY_DEPLOYED="/home/anny/.config/opencode/AGENTS.md"

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; exit 1; }

# Pick source: anny's repo clone first (per docs); fall back to levine's if
# anny's is missing or older.
hdr "Choose source"
if [[ -f "$ANNY_REPO_SRC" ]]; then
  anny_md5=$(md5sum "$ANNY_REPO_SRC" | awk '{print $1}')
  levine_md5=$(md5sum "$LEVINE_REPO_SRC" | awk '{print $1}')
  if [[ "$anny_md5" == "$levine_md5" ]]; then
    SRC="$ANNY_REPO_SRC"
    ok "anny's repo clone matches levine's — using $SRC"
  else
    bad "anny's repo clone diverges from levine's. Run 'git pull' in $ANNY_REPO_SRC's repo first, or set SRC manually."
  fi
else
  bad "anny's repo source $ANNY_REPO_SRC not found"
fi

src_md5=$(md5sum "$SRC" | awk '{print $1}')

# If already in sync, exit early
hdr "Current state of anny's deployed copy"
if [[ -e "$ANNY_DEPLOYED" ]]; then
  current_md5=$(sudo md5sum "$ANNY_DEPLOYED" | awk '{print $1}')
  echo "  current md5: $current_md5"
  echo "  source  md5: $src_md5"
  if [[ "$current_md5" == "$src_md5" ]]; then
    ok "already in sync — nothing to do"
    exit 0
  fi
else
  echo "  (not present — will create)"
fi

# Backup
hdr "Backup current copy"
if [[ -e "$ANNY_DEPLOYED" ]]; then
  backup="${ANNY_DEPLOYED}.bak.$(date +%Y%m%d-%H%M%S)"
  sudo -u anny cp "$ANNY_DEPLOYED" "$backup" || bad "backup failed"
  ok "backup: $backup"
else
  echo "  (no existing file to back up)"
fi

# Copy: as anny, real file (not symlink)
hdr "Copy canonical → anny's config"
sudo -u anny cp -f "$SRC" "$ANNY_DEPLOYED" || bad "copy failed"
ok "copied"

# Verify hash, type, ownership
hdr "Verify"
new_md5=$(sudo md5sum "$ANNY_DEPLOYED" | awk '{print $1}')
if [[ "$new_md5" == "$src_md5" ]]; then
  ok "hash matches source ($new_md5)"
else
  bad "hash mismatch after copy ($new_md5 != $src_md5)"
fi

if sudo test -L "$ANNY_DEPLOYED"; then
  bad "result is a symlink — opencode won't follow it"
else
  ok "result is a regular file"
fi

sudo ls -la "$ANNY_DEPLOYED"

cat <<'EOF'

== Done ==

If anny's opencode session is running, the new rules take effect on her
next prompt (opencode reads AGENTS.md per-turn, not at startup).
EOF
