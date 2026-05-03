#!/usr/bin/env bash
# fix-anny-ssh-via-wg.sh — make 'ssh laptop' (run as anny on workstation)
# resolve to the laptop's WireGuard IP instead of its LAN hostname, so it
# works regardless of which wifi/AP the laptop is on.
#
# Steps:
#   1. Probe SSH to anny@10.50.0.5 (WG IP) to confirm sshd is reachable there.
#   2. Back up /home/anny/.ssh/config with a timestamp.
#   3. Rewrite the 'HostName' line in the 'Host laptop' block to 10.50.0.5.
#   4. Verify: ssh -G shows the new hostname; ssh BatchMode echo round-trip works.
#
# Idempotent: safe to re-run; if HostName is already 10.50.0.5, the rewrite is
# a no-op.

set -uo pipefail

WG_IP="10.50.0.5"
ANNY_SSH_CONFIG="/home/anny/.ssh/config"
ANNY_KEY="/home/anny/.ssh/to-laptop"

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; exit 1; }

# ─── 1. Confirm SSH works over WireGuard before touching anything ────────────

hdr "Probe: ssh anny@${WG_IP} (direct, bypasses anny's ssh config)"
probe=$(sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=accept-new \
  -i "$ANNY_KEY" \
  "anny@${WG_IP}" 'echo PROBE_OK; hostname' 2>&1)

if [[ "$probe" != *"PROBE_OK"* ]]; then
  echo "$probe"
  bad "cannot reach laptop over WireGuard at ${WG_IP} — fix WG before running this script"
fi
laptop_hostname=$(echo "$probe" | tail -1)
ok "WG SSH works (laptop hostname: $laptop_hostname)"

# ─── 2. Backup anny's ssh config ─────────────────────────────────────────────

hdr "Backup ${ANNY_SSH_CONFIG}"
backup="${ANNY_SSH_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
sudo cp "$ANNY_SSH_CONFIG" "$backup"
sudo chown anny:anny "$backup"
sudo chmod 600 "$backup"
ok "backup: $backup"

# ─── 3. Show current Host laptop block, then rewrite HostName line ───────────

hdr "Current 'Host laptop' block in anny's ssh config"
sudo awk '
  /^[[:space:]]*Host[[:space:]]/ { in_block = ($0 ~ /[[:space:]]laptop([[:space:]]|$)/) ? 1 : 0 }
  in_block { print }
' "$ANNY_SSH_CONFIG"

current_hostname=$(sudo awk '
  /^[[:space:]]*Host[[:space:]]/ { in_block = ($0 ~ /[[:space:]]laptop([[:space:]]|$)/) ? 1 : 0 }
  in_block && /^[[:space:]]*HostName[[:space:]]/ { print $2; exit }
' "$ANNY_SSH_CONFIG")

if [[ -z "$current_hostname" ]]; then
  bad "could not find HostName line in 'Host laptop' block — manual edit required"
fi

if [[ "$current_hostname" == "$WG_IP" ]]; then
  ok "HostName is already $WG_IP — no rewrite needed"
else
  hdr "Rewriting HostName: $current_hostname → $WG_IP"
  # In-place edit of just the HostName line inside the Host laptop block.
  sudo awk -v wg_ip="$WG_IP" '
    /^[[:space:]]*Host[[:space:]]/ { in_block = ($0 ~ /[[:space:]]laptop([[:space:]]|$)/) ? 1 : 0 }
    in_block && /^[[:space:]]*HostName[[:space:]]/ {
      sub(/HostName[[:space:]]+[^[:space:]]+/, "HostName " wg_ip)
    }
    { print }
  ' "$ANNY_SSH_CONFIG" | sudo tee "${ANNY_SSH_CONFIG}.new" >/dev/null
  sudo chown anny:anny "${ANNY_SSH_CONFIG}.new"
  sudo chmod 600 "${ANNY_SSH_CONFIG}.new"
  sudo mv "${ANNY_SSH_CONFIG}.new" "$ANNY_SSH_CONFIG"
  ok "HostName rewritten"
fi

# ─── 4. Verify ───────────────────────────────────────────────────────────────

hdr "ssh -G anny@laptop (anny's view) — confirm it now resolves to ${WG_IP}"
sudo -n -u anny ssh -G anny@laptop 2>&1 | grep -iE '^(hostname|user|identityfile) ' | head -8

hdr "End-to-end test: sudo -u anny ssh anny@laptop 'hostname'"
roundtrip=$(sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 anny@laptop 'echo OK_END_TO_END; hostname' 2>&1)
if [[ "$roundtrip" == *"OK_END_TO_END"* ]]; then
  ok "ssh anny@laptop now reaches: $(echo "$roundtrip" | tail -1)"
else
  echo "$roundtrip"
  bad "round-trip test failed — investigate"
fi

cat <<EOF

== Done ==

Re-run the readiness check to confirm everything's now green:
  sudo /home/levine/Documents/Repos/2gpu-local-ai-workstation/scripts/check-anny-remote-ready.sh

Backup of original ssh config: $backup
EOF
