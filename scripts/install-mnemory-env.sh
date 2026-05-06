#!/usr/bin/env bash
# Install /etc/workstation/mnemory.env from the example template plus
# a per-user keys file. One-shot.
#
# Idempotent: re-running overwrites /etc/workstation/mnemory.env with
# the current keys + template. Backs up the previous file first.
#
# Keys file format ($HOME/.config/mnemory/keys):
#   One line per user, shell-style: KEY_<USERNAME>=<api-key>
#   Example:
#     KEY_alice=da3b7f...
#     KEY_bob=9c1e22...
#   Generate keys with `openssl rand -hex 32`.
#
# Users included in the rendered MCP_API_KEYS are taken from
# WS_LLAMA_USERS in /etc/workstation/system.env (space-separated list).
# Each user listed there must have a matching KEY_<USERNAME> entry in
# the keys file or the script aborts.
#
# After this lands, you can `sudo systemctl enable --now mnemory`.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$REPO/configs/workstation/mnemory.env.example"
TARGET="/etc/workstation/mnemory.env"
KEYS_FILE="$HOME/.config/mnemory/keys"
SYSTEM_ENV="/etc/workstation/system.env"

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; exit 1; }

[[ -r "$EXAMPLE" ]] || bad "$EXAMPLE not found"
[[ -r "$KEYS_FILE" ]] || bad "$KEYS_FILE not found — generate per-user keys with: openssl rand -hex 32"
[[ -r "$SYSTEM_ENV" ]] || bad "$SYSTEM_ENV not found — install configs/workstation/system.env.example first"

# Read WS_LLAMA_USERS from system.env. We can't `source` system.env
# unconditionally (it may have shell metacharacters in port comments
# or future fields), so grep+cut for safety.
WS_LLAMA_USERS=$(awk -F= '/^WS_LLAMA_USERS=/{ sub(/^[^=]*=/, ""); gsub(/"/, ""); print; exit }' "$SYSTEM_ENV")
[[ -n "$WS_LLAMA_USERS" ]] || bad "WS_LLAMA_USERS not set in $SYSTEM_ENV"
ok "WS_LLAMA_USERS = $WS_LLAMA_USERS"

# Source the keys file. It contains KEY_<USERNAME>=<value> lines only.
# shellcheck source=/dev/null
source "$KEYS_FILE"
ok "loaded keys from $KEYS_FILE"

# Build the MCP_API_KEYS JSON by iterating over WS_LLAMA_USERS.
# For each username, look up KEY_<USERNAME> from the sourced keys file.
# Aborts if any user is missing.
JQ_ARGS=()
JQ_FILTER='{}'
KEY_COUNT=0
for user in $WS_LLAMA_USERS; do
  varname="KEY_${user}"
  key_value="${!varname:-}"
  if [[ -z "$key_value" ]]; then
    bad "$varname missing in $KEYS_FILE (need one entry per WS_LLAMA_USERS member)"
  fi
  JQ_ARGS+=(--arg "k${KEY_COUNT}" "$key_value" --arg "u${KEY_COUNT}" "$user")
  if [[ "$JQ_FILTER" == '{}' ]]; then
    JQ_FILTER="{(\$k${KEY_COUNT}): \$u${KEY_COUNT}}"
  else
    JQ_FILTER="${JQ_FILTER} + {(\$k${KEY_COUNT}): \$u${KEY_COUNT}}"
  fi
  KEY_COUNT=$((KEY_COUNT + 1))
done

MCP_API_KEYS=$(jq -nc "${JQ_ARGS[@]}" "$JQ_FILTER")
ok "composed MCP_API_KEYS JSON ($KEY_COUNT users mapped)"

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
