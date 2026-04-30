#!/usr/bin/env bash
# Install or refresh the systemd user units and the sysctl setting
# that keeps Electron apps from crashing on Ubuntu 24.04.
#
# Idempotent. Safe to re-run after repo updates.
#
# Scope today: searxng.service. The llama-* services live in
# /etc/systemd/system/ as system-scoped units installed separately;
# they are not managed here.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="$REPO/systemd"
UNIT_DST="$HOME/.config/systemd/user"
SYSCTL_SRC="$REPO/etc/sysctl.d/60-apparmor-namespace.conf"
SYSCTL_DST="/etc/sysctl.d/60-apparmor-namespace.conf"

mkdir -p "$UNIT_DST"
install -m 0644 "$UNIT_SRC/searxng.service" "$UNIT_DST/"
systemctl --user daemon-reload

# sysctl: Ubuntu 24.04 restricts unprivileged user namespaces by default,
# which triggers kernel traps in Electron apps during window transitions
# (Open Folder, reload). Turning the restriction off restores 22.04 behavior.
if [[ ! -f "$SYSCTL_DST" ]] || ! cmp -s "$SYSCTL_SRC" "$SYSCTL_DST"; then
  sudo install -m 0644 "$SYSCTL_SRC" "$SYSCTL_DST"
  sudo sysctl --system >/dev/null
fi

echo "Installed:"
echo "  $UNIT_DST/searxng.service"
echo "  $SYSCTL_DST"
