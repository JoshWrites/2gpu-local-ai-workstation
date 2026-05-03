#!/usr/bin/env bash
# diagnose-anny-agent-crash.sh — Zed reported "internal error, server shut
# down unexpectedly" when anny launched the opencode agent. Gather evidence
# from both sides to figure out which stage failed:
#   stage 1: Zed → laptop launcher (opencode-remote-session) spawned at all?
#   stage 2: launcher → ssh to workstation succeeded?
#   stage 3: SSHFS reverse mount succeeded?
#   stage 4: opencode-patched on the workstation actually started?
#
# Read-only.

set -uo pipefail

LAPTOP_HOST="laptop"
ANNY_LAPTOP_USER="anny"
SINCE="10 min ago"

ssh_anny() {
  sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" "$@"
}

hdr()  { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
note() { printf "  \e[33m·\e[0m %s\n" "$*"; }

# ─── Workstation: live state ─────────────────────────────────────────────────

hdr "Workstation: SSHFS mount table (anny entries)"
grep sshfs /proc/mounts | grep -i anny || echo "  no anny sshfs mounts"

hdr "Workstation: anny's processes (opencode, sshfs, sshd-as-anny)"
ps -u anny -o pid,etime,comm,args 2>/dev/null | grep -vE '^\s*PID|grep' || echo "  none"

hdr "Workstation: sshd journal — anny logins in last $SINCE"
sudo journalctl --since "$SINCE" --no-pager _SYSTEMD_UNIT=ssh.service 2>&1 \
  | grep -iE 'anny|disconnected|accepted|invalid' | tail -25 || echo "  (none)"

hdr "Workstation: kernel/auth log — anny related, last $SINCE"
sudo journalctl --since "$SINCE" --no-pager _TRANSPORT=audit 2>&1 \
  | grep -i anny | tail -10 || echo "  (none)"

hdr "Workstation: anny user-session journal, last $SINCE (opencode/sshfs/llama)"
sudo journalctl --since "$SINCE" --no-pager _UID=1003 2>&1 | tail -40 || echo "  (none)"

hdr "Workstation: any opencode-patched output in syslog last $SINCE"
sudo journalctl --since "$SINCE" --no-pager 2>&1 \
  | grep -iE 'opencode|sshfs.*anny|/mnt/anny-laptop' | tail -30 || echo "  (none)"

hdr "Workstation: opencode-patched binary sanity"
ls -la /usr/local/bin/opencode-patched 2>&1
file /usr/local/bin/opencode-patched 2>&1
echo "--- expected env: OPENCODE_DISABLE_CHANNEL_DB=1, OPENCODE_BIN=/usr/local/bin/opencode-patched ---"

hdr "Workstation: opencode-session.sh content (the wrapper that launches opencode-patched)"
ls -la /home/anny/Documents/Repos/2gpu-local-ai-workstation/scripts/opencode-session.sh 2>&1
echo "--- first 40 lines ---"
sudo head -40 /home/anny/Documents/Repos/2gpu-local-ai-workstation/scripts/opencode-session.sh 2>&1

# ─── Workstation: try invoking opencode-patched as anny manually ─────────────

hdr "Workstation: smoke test — run opencode-patched --version as anny"
sudo -n -u anny bash -lc '
  export OPENCODE_BIN=/usr/local/bin/opencode-patched
  export OPENCODE_DISABLE_CHANNEL_DB=1
  cd /home/anny
  timeout 10 /usr/local/bin/opencode-patched --version 2>&1 | head -10
  echo "--- exit: $? ---"
'

# ─── Laptop: launcher invocation evidence ────────────────────────────────────

hdr "Laptop: was opencode-remote-session invoked? (process list)"
ssh_anny 'pgrep -af opencode-remote-session 2>/dev/null || echo "  not running now"; pgrep -af "ssh.*anny@10.50\|ssh.*anny@10.100.102.182" 2>/dev/null || echo "  no anny ssh procs"'

hdr "Laptop: Zed isolated-profile log (most recent)"
ssh_anny 'ls -la ~/.local/share/zed-2gpu-remote/logs/ 2>/dev/null | tail -10
echo "---"
for f in ~/.local/share/zed-2gpu-remote/logs/*.log; do
  [ -f "$f" ] || continue
  echo "=== $f (last 60 lines) ==="
  tail -60 "$f"
done' 2>&1 | tail -100

hdr "Laptop: any opencode/acp/agent error in Zed log"
ssh_anny 'grep -iE "opencode|acp|agent|server.*shut|server.*exit|spawn|enoent" ~/.local/share/zed-2gpu-remote/logs/*.log 2>/dev/null | tail -30' || echo "  (none)"

# ─── Final ───────────────────────────────────────────────────────────────────

cat <<'EOF'

== What to look for in the output above ==

1. If laptop log shows "spawn ENOENT" or "command not found" → launcher path
   in Zed settings doesn't resolve.
2. If laptop log shows the launcher started but errored quickly → the launcher
   itself failed early (probably pre-mount: WG IP missing, ssh failed, etc.).
3. If workstation sshd journal shows anny login + disconnect with no content,
   the launcher's `ssh` to workstation got a clean session but the wrapped
   command failed. Check the workstation user-session journal for the wrapped
   command's stderr.
4. If smoke test "opencode-patched --version" hangs or errors, the binary
   itself is broken and no Zed config will fix it.
EOF
