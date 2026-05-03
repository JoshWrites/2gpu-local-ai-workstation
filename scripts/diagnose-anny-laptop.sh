#!/usr/bin/env bash
# diagnose-anny-laptop.sh — investigate the two failures from
# check-anny-remote-ready.sh: wg0 not up, and launcher script not patched
# (or not where we expected). Read-only; suggests fixes but applies none.
#
# Run from the workstation as a user with `sudo -u anny ssh` access.

set -uo pipefail

LAPTOP_HOST="laptop"
ANNY_LAPTOP_USER="anny"

ssh_anny() {
  sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" "$@"
}

hdr() { printf "\n\e[1m== %s ==\e[1m\e[0m\n" "$*"; }

# ─── 1. Where is the repo on the laptop? ─────────────────────────────────────

hdr "Laptop: locate opencode-remote-session script"
ssh_anny 'find ~ -maxdepth 6 -type f -name opencode-remote-session 2>/dev/null'

hdr "Laptop: list ~/Documents and look for any 2gpu-* directory"
ssh_anny 'ls -la ~/Documents/ 2>&1 | head -20; echo "---"; find ~ -maxdepth 4 -type d -name "2gpu*" 2>/dev/null'

# ─── 2. If the repo IS present, check git state and the patch ────────────────

hdr "Laptop: if a 2gpu repo exists, show git state + check for the patch"
ssh_anny 'set -e
for d in $(find ~ -maxdepth 4 -type d -name "2gpu*" 2>/dev/null); do
  echo "--- $d ---"
  cd "$d" || continue
  echo "branch: $(git branch --show-current 2>/dev/null)"
  echo "head:   $(git log -1 --oneline 2>/dev/null)"
  echo "behind/ahead vs origin:"
  git fetch --quiet 2>/dev/null && git rev-list --left-right --count HEAD...@{u} 2>/dev/null | awk "{print \"  ahead=\" \$1 \" behind=\" \$2}"
  if [ -f scripts/laptop/opencode-remote-session ]; then
    if grep -q "timeout 3 ls" scripts/laptop/opencode-remote-session; then
      echo "patch:  PRESENT (timeout 3 ls found)"
    else
      echo "patch:  MISSING (would need git pull)"
    fi
  else
    echo "patch:  no scripts/laptop/opencode-remote-session in this dir"
  fi
done'

# ─── 3. WireGuard state on the laptop ────────────────────────────────────────

hdr "Laptop: WireGuard interface state"
ssh_anny 'ip link show wg0 2>&1 || true; echo "---ip addr---"; ip -4 addr show wg0 2>&1 || true'

hdr "Laptop: WireGuard config files"
ssh_anny 'sudo -n ls -la /etc/wireguard/ 2>&1 || ls -la /etc/wireguard/ 2>&1'

hdr "Laptop: wg-quick systemd units (enabled / active?)"
ssh_anny 'systemctl list-unit-files "wg-quick*" 2>&1 | head -10
echo "---"
systemctl status "wg-quick@*" --no-pager 2>&1 | head -30'

hdr "Laptop: NetworkManager-managed WireGuard connections (if any)"
ssh_anny 'nmcli -t -f NAME,TYPE,DEVICE,STATE connection show 2>/dev/null | grep -iE "wireguard|wg" || echo "no NM-managed wg connections"'

hdr "Laptop: was wg0 ever up? Check journal for wg-quick"
ssh_anny 'journalctl -u "wg-quick@*" -n 20 --no-pager 2>&1 | tail -25 || echo "no journal entries"'

# ─── 4. Suggest next steps ───────────────────────────────────────────────────

cat <<'EOF'

== Suggested next actions ==

If a 2gpu-* repo exists on the laptop with the patch MISSING:
  sudo -u anny ssh anny@laptop 'cd ~/Documents/Repos/2gpu-local-ai-workstation && git pull --ff-only'

If the repo doesn't exist on the laptop at all, the launcher needs to be
deployed there first (clone the repo, or copy just scripts/laptop/).

If wg-quick@wg0.service is disabled but a config exists:
  sudo -u anny ssh -t anny@laptop 'sudo systemctl start wg-quick@wg0'
  (use -t for the password prompt)

If wg0 is NetworkManager-managed and inactive:
  sudo -u anny ssh anny@laptop 'nmcli connection up wg0'

After fixing, re-run:
  sudo /home/levine/Documents/Repos/2gpu-local-ai-workstation/scripts/check-anny-remote-ready.sh
EOF
