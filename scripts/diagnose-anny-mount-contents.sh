#!/usr/bin/env bash
# diagnose-anny-mount-contents.sh — the launcher's `cd` fails with
# "No such file or directory" on the SSHFS mount path. Either the path
# doesn't exist on the laptop, or the mount is stale and not actually
# reflecting laptop state.

set -uo pipefail

MOUNT="/mnt/anny-laptop"
PROJECT_NAME="MATI-Klita_Entrepreneurship Course"
LAPTOP_HOST="laptop"
ANNY_LAPTOP_USER="anny"

ssh_anny() {
  sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" "$@"
}

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }

# ─── Workstation side: what's actually under the mount? ──────────────────────

hdr "Workstation: is /mnt/anny-laptop currently mounted? (sshfs entry)"
grep sshfs /proc/mounts | grep -i anny || echo "  NO mount present"

hdr "Workstation: ls /mnt/anny-laptop/ (top-level, as anny, with timeout)"
sudo -n -u anny timeout 5 ls -la "$MOUNT/" 2>&1 | head -20 || echo "  (failed/timeout)"

hdr "Workstation: ls /mnt/anny-laptop/Projects/ (as anny, with timeout)"
sudo -n -u anny timeout 5 ls -la "$MOUNT/Projects/" 2>&1 | head -30 || echo "  (failed/timeout — path doesn't exist or mount is stale)"

hdr "Workstation: probe the exact failing path"
sudo -n -u anny bash -c "
target='$MOUNT/Projects/$PROJECT_NAME'
echo \"target: \$target\"
if [ -e \"\$target\" ]; then
  echo \"  exists\"
  ls -la \"\$target\" | head
elif [ -L \"\$target\" ]; then
  echo \"  is a broken symlink\"
  ls -la \"\$target\"
else
  echo \"  DOES NOT EXIST\"
fi
"

# ─── Laptop side: ground truth ───────────────────────────────────────────────

hdr "Laptop: what's in ~/Projects/?"
ssh_anny "ls -la ~/Projects/ 2>&1 | head -30"

hdr "Laptop: does the exact project directory exist?"
ssh_anny "
target=\"\$HOME/Projects/$PROJECT_NAME\"
echo \"target: \$target\"
if [ -e \"\$target\" ]; then
  echo \"  exists\"
  ls -la \"\$target\" | head -5
else
  echo \"  DOES NOT EXIST on laptop either\"
fi
"

# ─── Compare contents to detect stale mount ──────────────────────────────────

hdr "Workstation /mnt/anny-laptop/ vs laptop ~/ — quick directory compare"
echo "--- workstation mount top level ---"
sudo -n -u anny timeout 5 ls "$MOUNT/" 2>&1 | sort | head -20
echo "--- laptop home top level ---"
ssh_anny "ls ~/ 2>&1 | sort | head -20"

cat <<'EOF'

== Likely root cause ==

If "Projects" directory exists on laptop but NOT in /mnt/anny-laptop/,
the SSHFS mount is stale — present in /proc/mounts but not actually
syncing with the laptop. The patched `timeout 3 ls` check probably
passed because the empty/cached mount root responded quickly, but
deeper paths fail.

Fix: force a clean remount. From the workstation:
  sudo -u anny fusermount -uz /mnt/anny-laptop
  # then re-launch from Zed; the launcher will re-mount cleanly.
EOF
