#!/usr/bin/env bash
# tail-anny-launch-evidence.sh — after anny attempts to launch the Zed
# agent and it fails, dump the most recent evidence from both sides so
# we can see exactly which step broke.

set -uo pipefail

LAPTOP_HOST="laptop"
ANNY_LAPTOP_USER="anny"
SINCE="3 min ago"

ssh_anny() {
  sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" "$@"
}

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }

# ─── Workstation: live state right now ───────────────────────────────────────

hdr "Workstation: /proc/mounts (anny sshfs entries)"
grep sshfs /proc/mounts | grep -i anny || echo "  none"

hdr "Workstation: anny's processes right now"
ps -u anny -o pid,etime,comm,args 2>/dev/null | grep -vE '^\s*PID|grep'

hdr "Workstation: sshd journal — anny logins in last $SINCE"
sudo journalctl --since "$SINCE" --no-pager _SYSTEMD_UNIT=ssh.service 2>&1 \
  | grep -iE 'anny' | tail -30 || echo "  (none)"

hdr "Workstation: opencode/sshfs/llama in syslog last $SINCE"
sudo journalctl --since "$SINCE" --no-pager 2>&1 \
  | grep -iE 'opencode|sshfs|llama-(primary|secondary|coder|embed)|/mnt/anny-laptop' \
  | tail -40 || echo "  (none)"

# ─── Laptop: launcher's stderr captured by Zed ───────────────────────────────

hdr "Laptop: latest Zed.log (most recent agent stderr lines)"
ssh_anny 'tail -120 ~/.local/share/zed-2gpu-remote/logs/Zed.log 2>/dev/null \
  | grep -E "(opencode-remote|opencode-session|agent stderr|spawn|ENOENT|server.*shut|SSHFS|mount|cd:|cwd|ERROR)" \
  | tail -40' || echo "  (no log)"

hdr "Laptop: any sshfs daemon currently running on laptop side"
ssh_anny 'pgrep -af sshfs 2>/dev/null || echo "  none"'

hdr "Laptop: laptop's sshd journal — workstation logins in last $SINCE"
ssh_anny "sudo -n journalctl --since '$SINCE' --no-pager _SYSTEMD_UNIT=ssh.service 2>&1 | grep -iE 'workstation|10.50.0|10.100.102.182|levine-positron|anny' | tail -20 || journalctl --user --since '$SINCE' --no-pager 2>&1 | tail -20 || echo '  (cannot read journal)'"
