#!/usr/bin/env bash
# build-patched-opencode.sh -- one-command build of opencode-patched.
#
# Clones opencode at the pinned tag, applies the 5 patches, fetches
# a pinned bun, builds, installs to /usr/local/bin/opencode-patched.
#
# Idempotent. Safe to re-run; uses /tmp/opencode-build/ and
# /tmp/bun-1313/ as scratch dirs (cleaned and recreated on each run).
#
# Pinned versions in the script header are the ones validated by the
# stack. To rebase against a newer opencode tag, change OPENCODE_TAG
# and re-run; if any patch fails to apply, the script aborts and you
# resolve the conflicts manually.

set -euo pipefail

OPENCODE_REPO="https://github.com/anomalyco/opencode.git"
OPENCODE_TAG="v1.14.28"
BUN_VERSION="1.3.13"
BUILD_ROOT="/tmp/opencode-build"
BUN_INSTALL_DIR="/tmp/bun-1313"
INSTALL_PATH="/usr/local/bin/opencode-patched"
STAGING_PATH="$HOME/.local/bin/opencode-patched"

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES=(
  "our-patch-agent.diff"
  "our-patch-bash.diff"
  "our-patch-tools.diff"
  "our-patch-skill-permission.diff"
  "our-patch-router-swap-v3.diff"
)

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*" >&2; exit 1; }

# ── 1. Verify patches present ────────────────────────────────────────────────
hdr "Patches"
for p in "${PATCHES[@]}"; do
  [[ -r "$PATCH_DIR/$p" ]] || bad "$PATCH_DIR/$p not found"
  ok "$p"
done

# ── 2. Clean and clone ───────────────────────────────────────────────────────
hdr "Clone $OPENCODE_REPO @ $OPENCODE_TAG"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"
git clone --depth 50 "$OPENCODE_REPO" opencode
cd opencode
git fetch --depth 50 --tags origin
git checkout "$OPENCODE_TAG"
ok "checked out $OPENCODE_TAG ($(git rev-parse --short HEAD))"

# ── 3. Apply patches ─────────────────────────────────────────────────────────
hdr "Apply patches"
for p in "${PATCHES[@]}"; do
  if ! git apply "$PATCH_DIR/$p"; then
    bad "patch $p failed to apply against $OPENCODE_TAG. Either rebase the patch or pin to an older tag."
  fi
  ok "applied $p"
done

# ── 4. Install pinned bun ────────────────────────────────────────────────────
hdr "Install bun $BUN_VERSION"
rm -rf "$BUN_INSTALL_DIR"
BUN_INSTALL="$BUN_INSTALL_DIR" bash <(curl -fsSL https://bun.sh/install) "bun-v$BUN_VERSION"
[[ -x "$BUN_INSTALL_DIR/bin/bun" ]] || bad "bun installer did not produce $BUN_INSTALL_DIR/bin/bun"
ok "bun: $($BUN_INSTALL_DIR/bin/bun --version)"

# ── 5. Install workspace deps ────────────────────────────────────────────────
hdr "Workspace deps"
PATH="$BUN_INSTALL_DIR/bin:$PATH" "$BUN_INSTALL_DIR/bin/bun" install
ok "deps installed"

# ── 6. Build single-platform ─────────────────────────────────────────────────
hdr "Build (single platform)"
cd packages/opencode
PATH="$BUN_INSTALL_DIR/bin:$PATH" "$BUN_INSTALL_DIR/bin/bun" run script/build.ts --single
[[ -x dist/opencode-linux-x64/bin/opencode ]] || bad "build did not produce dist/opencode-linux-x64/bin/opencode"
ok "built dist/opencode-linux-x64/bin/opencode"

# ── 7. Stage to per-user path ────────────────────────────────────────────────
hdr "Staging install"
mkdir -p "$(dirname "$STAGING_PATH")"
cp dist/opencode-linux-x64/bin/opencode "$STAGING_PATH"
chmod +x "$STAGING_PATH"
ok "staged at $STAGING_PATH"

# ── 8. System install (atomic) ───────────────────────────────────────────────
hdr "System install"
sudo install -m 0755 -o root -g root \
  "$STAGING_PATH" "${INSTALL_PATH}.new"
sudo mv "${INSTALL_PATH}.new" "$INSTALL_PATH"
ok "installed at $INSTALL_PATH ($(ls -lh "$INSTALL_PATH" | awk '{print $5}'))"

# ── 9. Smoke test ────────────────────────────────────────────────────────────
hdr "Smoke test"
"$INSTALL_PATH" --version | head -1 | sed 's/^/  /'
ok "binary runs"

cat <<EOF

== Done ==

Patched opencode is at $INSTALL_PATH.
Point Zed at it via OPENCODE_BIN in the isolated profile's settings.json:

  "agent_servers": {
    "opencode": {
      "command": "<path-to>/scripts/opencode-session.sh",
      "args": ["acp"],
      "env": {
        "OPENCODE_BIN": "$INSTALL_PATH",
        "OPENCODE_DISABLE_CHANNEL_DB": "1",
        "OPENCODE_MODEL_SWAP_SCRIPT": "<path-to>/scripts/model-swap.sh"
      }
    }
  }

See opencode-zed-patches/install-and-wire.md for the full wiring guide.
EOF
