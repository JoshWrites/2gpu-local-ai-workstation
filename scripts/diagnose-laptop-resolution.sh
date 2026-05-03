#!/usr/bin/env bash
# diagnose-laptop-resolution.sh — figure out why 'ssh anny@laptop' was
# resolving correctly earlier and now times out on
# 'anny-s-laptop-phoenix'. Read-only: no fixes applied.

set -uo pipefail

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }

hdr "How does the workstation resolve 'laptop' right now?"
getent hosts laptop 2>&1 || echo "  (no result)"
echo "--- all addresses for 'laptop' ---"
getent ahosts laptop 2>&1 | head

hdr "What about anny-s-laptop-phoenix?"
getent hosts anny-s-laptop-phoenix 2>&1 || echo "  (no result)"

hdr "Avahi / mDNS resolution"
which avahi-resolve >/dev/null && avahi-resolve -n laptop.local 2>&1 || echo "  no avahi-resolve installed"
which avahi-resolve >/dev/null && avahi-resolve -n pheonix.local 2>&1 || true

hdr "ssh config on workstation: any 'laptop' host alias?"
for f in ~/.ssh/config /etc/ssh/ssh_config /etc/ssh/ssh_config.d/*; do
  [ -f "$f" ] || continue
  if grep -qiE '^[[:space:]]*Host[[:space:]].*laptop' "$f" 2>/dev/null; then
    echo "--- $f ---"
    awk '/^[[:space:]]*Host[[:space:]]/{p=0} /^[[:space:]]*Host[[:space:]].*laptop/i{p=1} p' "$f" | head -20
  fi
done

hdr "anny's ssh config (workstation side, requires sudo to read)"
sudo cat /home/anny/.ssh/config 2>&1 | head -60

hdr "What ssh actually picks for 'anny@laptop' (workstation, levine's view)"
ssh -G anny@laptop 2>&1 | grep -iE '^(hostname|user|port|identityfile|identitiesonly|controlpath|controlmaster|proxyjump|proxycommand) ' | head

hdr "What ssh actually picks for 'anny@laptop' (workstation, anny's view)"
sudo -n -u anny ssh -G anny@laptop 2>&1 | grep -iE '^(hostname|user|port|identityfile|identitiesonly|controlpath|controlmaster|proxyjump|proxycommand) ' | head

hdr "ssh ControlMaster sockets that may be wedged"
ls -la ~/.ssh/cm-* ~/.ssh/control-* /tmp/ssh-* 2>/dev/null | head -20 || echo "  no levine sockets"
sudo -n ls -la /home/anny/.ssh/cm-* /home/anny/.ssh/control-* /tmp/ssh-anny-* 2>/dev/null | head -20 || echo "  no anny sockets"

hdr "Any leftover ssh processes from anny holding a master connection"
pgrep -af 'ssh.*ControlMaster' 2>/dev/null || true
ps -u anny -o pid,etime,cmd 2>/dev/null | grep -E '\bssh\b' | grep -v 'grep' || echo "  no anny ssh processes"

hdr "Conflicting ssh configs ON THE LAPTOP (anny's view + system)"
TIMEOUT_SSH() { sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 anny@laptop "$@"; }
echo "--- ~/.ssh/config on laptop ---"
TIMEOUT_SSH 'cat ~/.ssh/config 2>&1 | head -60' 2>&1 | head -65
echo ""
echo "--- /etc/ssh/ssh_config.d/* on laptop ---"
TIMEOUT_SSH 'ls /etc/ssh/ssh_config.d/ 2>/dev/null && for f in /etc/ssh/ssh_config.d/*; do echo "=== $f ==="; cat "$f"; done' 2>&1 | head -40
echo ""
echo "--- ssh -G on laptop: how does laptop itself resolve 'anny@workstation' / 'anny@10.100.102.182' ---"
TIMEOUT_SSH "ssh -G anny@10.100.102.182 2>&1 | grep -iE '^(hostname|user|port|identityfile|identitiesonly|proxyjump|proxycommand) '" 2>&1 | head -10
echo ""
echo "--- ControlMaster sockets on laptop (anny's home) ---"
TIMEOUT_SSH 'ls -la ~/.ssh/cm-* ~/.ssh/control-* /tmp/ssh-anny-* 2>/dev/null || echo "  none"' 2>&1 | head

hdr "Direct ping by known IPs"
echo "--- WireGuard IP 10.50.0.5 ---"
ping -c 1 -W 2 10.50.0.5 2>&1 | tail -3
echo "--- known LAN IP for the laptop? guess from /etc/hosts or arp ---"
arp -n 2>/dev/null | grep -iE 'pheonix|laptop' | head
grep -iE 'pheonix|laptop' /etc/hosts 2>/dev/null

hdr "Active wg peer endpoints from workstation side"
sudo -n wg show 2>&1 | head -30 || echo "  (need sudo for wg show)"

hdr "Workstation's route to 10.50.0.5"
ip route get 10.50.0.5 2>&1
