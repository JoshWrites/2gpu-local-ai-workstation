#!/usr/bin/env bash
# check-anny-remote-ready.sh — verify all preconditions for anny's remote
# opencode session. Runs workstation-side checks locally and laptop-side
# checks via SSH (as anny). Exit code 0 = all green, non-zero = at least
# one check failed.
#
# Run from the workstation as a user with `sudo -u anny` access.

set -uo pipefail

WORKSTATION_IP="10.100.102.182"
LAPTOP_HOST="laptop"
ANNY_LAPTOP_USER="anny"
MOUNT_POINT="/mnt/anny-laptop"
REPO_ON_WS="/home/anny/Documents/Repos/2gpu-local-ai-workstation"
LAPTOP_LAUNCHER='~/bin/opencode-remote-session'

PASS=0
FAIL=0

ok()   { printf "  \e[32m✓\e[0m %s\n" "$*"; PASS=$((PASS+1)); }
bad()  { printf "  \e[31m✗\e[0m %s\n" "$*"; FAIL=$((FAIL+1)); }
note() { printf "  \e[33m·\e[0m %s\n" "$*"; }
hdr()  { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }

# ─── Workstation side ────────────────────────────────────────────────────────

hdr "Workstation: no stale anny sshfs mounts"
stale=$(grep sshfs /proc/mounts | grep -E 'anny|/mnt/anny-laptop' || true)
if [[ -z "$stale" ]]; then
  ok "no anny sshfs mounts present"
else
  bad "stale anny sshfs mount(s) present:"
  echo "$stale" | sed 's/^/      /'
fi

hdr "Workstation: no orphan anny sshfs daemons"
# Filter out our grep itself
orphans=$(pgrep -af sshfs | grep -v 'pgrep' | grep -E 'anny@|/home/anny' || true)
if [[ -z "$orphans" ]]; then
  ok "no orphan sshfs daemons"
else
  bad "lingering sshfs daemon(s):"
  echo "$orphans" | sed 's/^/      /'
fi

hdr "Workstation: support llama-servers running"
for svc in llama-primary-router llama-secondary llama-coder llama-embed; do
  state=$(systemctl is-active "$svc" 2>/dev/null)
  if [[ "$state" == "active" ]]; then
    ok "$svc: $state"
  else
    bad "$svc: $state"
  fi
done

hdr "Workstation: opencode-session.sh + model-swap-remote.sh exist"
for f in "${REPO_ON_WS}/scripts/opencode-session.sh" "${REPO_ON_WS}/scripts/model-swap-remote.sh"; do
  if [[ -x "$f" ]]; then
    ok "$f (executable)"
  elif [[ -f "$f" ]]; then
    bad "$f exists but is not executable"
  else
    bad "$f MISSING"
  fi
done

hdr "Workstation: opencode-patched binary exists"
if [[ -x /usr/local/bin/opencode-patched ]]; then
  ok "/usr/local/bin/opencode-patched (executable)"
else
  bad "/usr/local/bin/opencode-patched MISSING or not executable"
fi

# ─── Laptop side (over SSH as anny) ──────────────────────────────────────────

hdr "Laptop: SSH reachability (sudo -u anny ssh ${ANNY_LAPTOP_USER}@${LAPTOP_HOST})"
laptop_probe=$(sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
  "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" 'echo SSH_OK; hostname' 2>&1)
if [[ "$laptop_probe" == *"SSH_OK"* ]]; then
  ok "ssh OK ($(echo "$laptop_probe" | tail -1))"
else
  bad "ssh failed:"
  echo "$laptop_probe" | sed 's/^/      /'
  note "skipping remaining laptop-side checks"
  printf "\n\e[1mResult: %d passed, %d failed\e[0m\n" "$PASS" "$FAIL"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

hdr "Laptop: WireGuard wg0 has an IP"
wg_ip=$(sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
  "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" \
  "ip -4 addr show wg0 2>/dev/null | awk '/inet / {sub(/\/.*/, \"\", \$2); print \$2}'" 2>/dev/null)
if [[ -n "$wg_ip" ]]; then
  ok "wg0 IP: $wg_ip"
else
  bad "wg0 has no IP (VPN down?)"
fi

hdr "Laptop: WireGuard handshake to workstation peer is recent"
wg_show=$(sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
  "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" \
  "sudo -n wg show wg0 latest-handshakes 2>/dev/null || wg show wg0 latest-handshakes 2>/dev/null" 2>/dev/null)
if [[ -z "$wg_show" ]]; then
  note "could not read 'wg show' (needs sudo on laptop) — skipping"
else
  now=$(date +%s)
  while IFS=$'\t' read -r peer ts; do
    [[ -z "$ts" || "$ts" == "0" ]] && { bad "peer $peer: never handshook"; continue; }
    age=$((now - ts))
    if (( age < 300 )); then
      ok "peer $peer: handshake ${age}s ago"
    else
      bad "peer $peer: handshake ${age}s ago (stale)"
    fi
  done <<< "$wg_show"
fi

hdr "Laptop: launcher script exists with the patched mount-liveness check"
launcher_check=$(sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
  "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" \
  "test -x ${LAPTOP_LAUNCHER} && \
   grep -q 'timeout 3 ls' ${LAPTOP_LAUNCHER} && echo PATCHED || echo OLD_OR_MISSING" 2>&1)
case "$launcher_check" in
  PATCHED)        ok "${LAPTOP_LAUNCHER} present and includes the stale-mount fix" ;;
  OLD_OR_MISSING) bad "${LAPTOP_LAUNCHER} missing OR doesn't have the stale-mount fix — re-run fix-anny-laptop.sh" ;;
  *)              bad "could not check: $launcher_check" ;;
esac

hdr "Laptop → Workstation: SSH reachable from laptop (BatchMode, anny@${WORKSTATION_IP})"
ws_from_laptop=$(sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
  "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" \
  "ssh -o BatchMode=yes -o ConnectTimeout=5 anny@${WORKSTATION_IP} 'echo WS_OK; hostname'" 2>&1)
if [[ "$ws_from_laptop" == *"WS_OK"* ]]; then
  ok "laptop can SSH to workstation as anny without prompting ($(echo "$ws_from_laptop" | tail -1))"
else
  bad "laptop → workstation SSH failed (key not deployed, or BatchMode rejection):"
  echo "$ws_from_laptop" | sed 's/^/      /'
fi

hdr "Workstation: mount point ${MOUNT_POINT} exists and is empty"
if [[ -d "$MOUNT_POINT" ]]; then
  if mountpoint -q "$MOUNT_POINT"; then
    bad "$MOUNT_POINT is currently a mountpoint (should be unmounted before fresh test)"
  else
    contents=$(ls -A "$MOUNT_POINT" 2>/dev/null)
    if [[ -z "$contents" ]]; then
      ok "$MOUNT_POINT exists, not mounted, empty"
    else
      bad "$MOUNT_POINT not mounted but not empty: $contents"
    fi
  fi
else
  bad "$MOUNT_POINT does not exist"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

printf "\n\e[1mResult: %d passed, %d failed\e[0m\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
