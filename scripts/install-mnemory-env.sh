#!/usr/bin/env bash
# Install /etc/workstation/mnemory.env from the example template plus
# the existing per-user keys at ~/.config/mnemory/keys. One-shot.
#
# Idempotent: re-running overwrites /etc/workstation/mnemory.env with
# the current keys + template. Backs up the previous file first.
#
# After this lands, you can `sudo systemctl enable --now mnemory`.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$REPO/configs/workstation/mnemory.env.example"
TARGET="/etc/workstation/mnemory.env"
KEYS_FILE="$HOME/.config/mnemory/keys"

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; exit 1; }

[[ -r "$EXAMPLE" ]] || bad "$EXAMPLE not found"
[[ -r "$KEYS_FILE" ]] || bad "$KEYS_FILE not found — run /tmp/start-mnemory.sh once to generate per-user keys"

# Read keys
# shellcheck source=/dev/null
source "$KEYS_FILE"
[[ -n "${LEVINE_KEY:-}" ]] || bad "LEVINE_KEY missing in $KEYS_FILE"
[[ -n "${ANNY_KEY:-}" ]] || bad "ANNY_KEY missing in $KEYS_FILE"
ok "loaded keys from $KEYS_FILE"

# Build the MCP_API_KEYS JSON
MCP_API_KEYS=$(jq -nc \
  --arg lk "$LEVINE_KEY" \
  --arg ak "$ANNY_KEY" \
  '{($lk): "levine", ($ak): "anny"}')
ok "composed MCP_API_KEYS JSON (2 users mapped)"

# Render the template by replacing the example MCP_API_KEYS line
RENDERED=$(mktemp)
trap 'rm -f "$RENDERED"' EXIT
awk -v new="MCP_API_KEYS=$MCP_API_KEYS" '
  /^MCP_API_KEYS=/ { print new; next }
  { print }
' "$EXAMPLE" > "$RENDERED"

# Backup any existing target file
hdr "Install $TARGET"
if [[ -f "$TARGET" ]]; then
  backup="${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"
  sudo cp "$TARGET" "$backup"
  ok "backup: $backup"
fi

sudo install -m 0640 -o root -g root "$RENDERED" "$TARGET"
ok "wrote $TARGET (mode 0640, owner root:root)"

# Verify
hdr "Verify"
echo "  size: $(sudo wc -c < "$TARGET") bytes"
echo "  permissions: $(sudo stat -c '%a %U:%G' "$TARGET")"
echo "  MCP_API_KEYS: <set, $(echo "$MCP_API_KEYS" | jq 'keys | length') keys>"

cat <<'EOF'

== Done ==

Next steps:
  sudo systemctl daemon-reload
  sudo systemctl enable --now mnemory.service
  systemctl status mnemory.service
  journalctl -u mnemory.service -f

Or run scripts/install-systemd-units.sh which now installs the unit too.
EOF
