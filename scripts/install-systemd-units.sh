#!/usr/bin/env bash
# Install or refresh the systemd unit files and the sysctl setting
# that keeps Electron apps from crashing on Ubuntu 24.04.
#
# Idempotent. Safe to re-run after repo updates.
#
# Scope:
# - searxng.service goes to ~/.config/systemd/user/ (user-scope).
# - llama-primary, llama-secondary, llama-embed, llama-coder go to
#   /etc/systemd/system/ (system-scope) so polkit-managed start/stop
#   works for both local users.
# - The sysctl drop-in goes to /etc/sysctl.d/.
#
# Requires sudo for the system-scope and sysctl steps. The script
# uses `sudo install` for those; configure passwordless sudo or be
# prepared to type your password.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="$REPO/systemd"

USER_UNIT_DST="$HOME/.config/systemd/user"
SYSTEM_UNIT_DST="/etc/systemd/system"

SYSCTL_SRC="$REPO/etc/sysctl.d/60-apparmor-namespace.conf"
SYSCTL_DST="/etc/sysctl.d/60-apparmor-namespace.conf"

LLAMA_UNITS=(llama-primary llama-secondary llama-embed llama-coder)

# ── User-scope units ───────────────────────────────────────────────────────

mkdir -p "$USER_UNIT_DST"
install -m 0644 "$UNIT_SRC/searxng.service" "$USER_UNIT_DST/"
systemctl --user daemon-reload

# ── System-scope llama units ──────────────────────────────────────────────

# These units use `EnvironmentFile=/etc/workstation/system.env` for paths
# and ports. Make sure that file exists before installing units; otherwise
# the units will fail to start with "missing variable" errors at exec time.
if [[ ! -f /etc/workstation/system.env ]]; then
  echo "ERROR: /etc/workstation/system.env not found." >&2
  echo "       Install configs/workstation/system.env.example there first:" >&2
  echo "       sudo install -m 0644 configs/workstation/system.env.example /etc/workstation/system.env" >&2
  exit 1
fi

for unit in "${LLAMA_UNITS[@]}"; do
  if [[ ! -f "$UNIT_SRC/${unit}.service" ]]; then
    echo "ERROR: $UNIT_SRC/${unit}.service missing from repo" >&2
    exit 1
  fi
  sudo install -m 0644 "$UNIT_SRC/${unit}.service" "$SYSTEM_UNIT_DST/"
done
sudo systemctl daemon-reload

# ── llama-shutdown helper script ──────────────────────────────────────────

# llama-shutdown is the polite-shutdown coordinator for the llama units.
# It lives at /usr/local/bin/ so both local users can invoke it directly.
# The script reads /etc/workstation/system.env for port numbers; same
# env-file dependency as the units.

LLAMA_SHUTDOWN_SRC="$UNIT_SRC/llama-shutdown"
LLAMA_SHUTDOWN_DST="/usr/local/bin/llama-shutdown"

if [[ ! -x "$LLAMA_SHUTDOWN_SRC" ]]; then
  echo "ERROR: $LLAMA_SHUTDOWN_SRC missing or not executable" >&2
  exit 1
fi
sudo install -m 0755 "$LLAMA_SHUTDOWN_SRC" "$LLAMA_SHUTDOWN_DST"

# ── polkit rule for passwordless systemctl on llama units ─────────────────

# Lets the local users run systemctl start/stop/restart on the llama
# services without sudo. Every llama unit must be listed in the rule's
# allowedUnits array; missing units silently fall through to the
# password prompt and break the launcher's polite-start path.

POLKIT_SRC="$UNIT_SRC/polkit/10-llama-services.rules"
POLKIT_DST="/etc/polkit-1/rules.d/10-llama-services.rules"

if [[ ! -f "$POLKIT_SRC" ]]; then
  echo "ERROR: $POLKIT_SRC missing from repo" >&2
  exit 1
fi
sudo install -m 0644 "$POLKIT_SRC" "$POLKIT_DST"

# ── sysctl drop-in ────────────────────────────────────────────────────────

# Ubuntu 24.04 restricts unprivileged user namespaces by default, which
# triggers kernel traps in Electron apps during window transitions
# (Open Folder, reload). Turning the restriction off restores 22.04 behavior.
if [[ ! -f "$SYSCTL_DST" ]] || ! cmp -s "$SYSCTL_SRC" "$SYSCTL_DST"; then
  sudo install -m 0644 "$SYSCTL_SRC" "$SYSCTL_DST"
  sudo sysctl --system >/dev/null
fi

echo "Installed:"
echo "  $USER_UNIT_DST/searxng.service"
for unit in "${LLAMA_UNITS[@]}"; do
  echo "  $SYSTEM_UNIT_DST/${unit}.service"
done
echo "  $LLAMA_SHUTDOWN_DST"
echo "  $POLKIT_DST"
echo "  $SYSCTL_DST"
echo
echo "Note: the llama units were installed but not started. Start them"
echo "individually with: sudo systemctl start llama-primary.service"
echo "(or use the second-opinion launcher to bring them all up at once)."
