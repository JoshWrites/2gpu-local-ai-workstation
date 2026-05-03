#!/usr/bin/env bash
# clear-anny-stale-mount.sh — anny's /mnt/anny-laptop is in /proc/mounts
# but doesn't actually serve laptop content (Dolphin doesn't see it; cd
# into subdirs fails with ENOENT). The launcher's `timeout 3 ls` check
# passes anyway because ls of an empty/cached FUSE root returns 0 fast.
#
# This script:
#   1. Confirms the failure mode (entry in /proc/mounts, but listing
#      Projects/ fails or returns empty).
#   2. Lazy-unmounts and kills the stale sshfs daemon.
#   3. Verifies the mount is fully gone.
# Anny can then re-launch from Zed; the launcher will mount fresh.

set -uo pipefail

MOUNT="/mnt/anny-laptop"

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; }

# ─── 1. Confirm the failure mode ─────────────────────────────────────────────

hdr "Current state"
mount_entry=$(grep sshfs /proc/mounts | grep -i anny || true)
if [[ -z "$mount_entry" ]]; then
  ok "no anny sshfs mount entry — nothing to clear"
  exit 0
fi
echo "  mount entry: $mount_entry"

echo ""
echo "  contents of $MOUNT/ (should show laptop home; if empty or fails, mount is stale):"
sudo -n -u anny timeout 5 ls -la "$MOUNT/" 2>&1 | head -10 | sed 's/^/    /'

echo ""
echo "  contents of $MOUNT/Projects/ (where the launcher's cwd lives):"
sudo -n -u anny timeout 5 ls -la "$MOUNT/Projects/" 2>&1 | head -10 | sed 's/^/    /'

# ─── 2. Identify and clean up ────────────────────────────────────────────────

hdr "sshfs daemon PID(s) for $MOUNT"
sshfs_pids=$(pgrep -af "sshfs.*$MOUNT" 2>/dev/null | awk '{print $1}' || true)
if [[ -z "$sshfs_pids" ]]; then
  echo "  no sshfs process found — mount entry is fully orphaned"
else
  echo "$sshfs_pids" | while read -r pid; do
    echo "  PID $pid: $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)"
  done
fi

hdr "Lazy unmount $MOUNT"
sudo -u anny fusermount -uz "$MOUNT" 2>&1 && ok "fusermount -uz succeeded" || bad "fusermount -uz failed"

if [[ -n "$sshfs_pids" ]]; then
  hdr "Kill stale sshfs daemon(s)"
  echo "$sshfs_pids" | while read -r pid; do
    if kill -9 "$pid" 2>/dev/null; then
      ok "killed PID $pid"
    else
      bad "could not kill PID $pid (already gone?)"
    fi
  done
fi

# ─── 3. Verify ───────────────────────────────────────────────────────────────

hdr "Final state"
remaining=$(grep sshfs /proc/mounts | grep -i anny || true)
if [[ -z "$remaining" ]]; then
  ok "no anny sshfs entries in /proc/mounts"
else
  bad "still present:"
  echo "  $remaining"
fi

remaining_pids=$(pgrep -af "sshfs.*$MOUNT" || true)
if [[ -z "$remaining_pids" ]]; then
  ok "no sshfs daemons for $MOUNT"
else
  bad "still running: $remaining_pids"
fi

cat <<EOF

== Done ==

Anny can now re-launch the agent from Zed. The launcher will SSH to the
workstation, see no mount, and create a fresh one via WireGuard.

If this happens again, the launcher's mount-liveness check is too weak —
'timeout 3 ls' on an empty/cached root passes even when the FUSE backend
is dead. The check should probe a path that round-trips to the laptop,
e.g. 'timeout 3 ls Projects/' (assuming Projects/ exists). That fix lives
in scripts/laptop/opencode-remote-session.
EOF
