#!/usr/bin/env bash
# Build verification for our-patch-router-swap-v2.diff.
#
# Clones opencode v1.14.28 into /tmp/opencode-build-v2/, applies all five
# patches in order (skipping the v1 router-swap, which v2 supersedes),
# typechecks, and builds a single-platform binary. The build itself is
# the gate for this task; full ACP-mode integration testing happens in
# Task 4 (manual smoke in Zed).
#
# Re-runnable: cleans the build tree on each invocation.
#
# Time: ~3 minutes cold (clone + install + build).

set -euo pipefail

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/opencode-build-v2"
OPENCODE_VERSION="1.14.28"
BUN_DIR="/tmp/bun-1313"
BUN="$BUN_DIR/bin/bun"

# Sanity: isolated bun must already be installed per how-to-patch-opencode.md.
if [[ ! -x "$BUN" ]]; then
  echo "FAIL: $BUN not found. Install with:" >&2
  echo "  BUN_INSTALL=$BUN_DIR bash <(curl -fsSL https://bun.sh/install) bun-v1.3.13" >&2
  exit 1
fi

# Clean rebuild
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
git clone --depth 50 https://github.com/sst/opencode.git
cd opencode
git fetch --depth 50 --tags origin
git checkout "v$OPENCODE_VERSION"

# Apply patches 1-4 + v2 router-swap (replaces v1).
for p in our-patch-agent.diff our-patch-bash.diff our-patch-tools.diff \
         our-patch-skill-permission.diff our-patch-router-swap-v2.diff; do
  echo "--- Applying $p ---"
  git apply "$PATCH_DIR/$p"
done

# Build (uses the isolated bun per how-to-patch-opencode.md).
PATH="$BUN_DIR/bin:$PATH" "$BUN" install
PATH="$BUN_DIR/bin:$PATH" "$BUN" run typecheck

cd packages/opencode
PATH="$BUN_DIR/bin:$PATH" "$BUN" run script/build.ts --single

BIN="$BUILD_DIR/opencode/packages/opencode/dist/opencode-linux-x64/bin/opencode"
[[ -x "$BIN" ]] || { echo "FAIL: build did not produce $BIN"; exit 1; }

# Smoke: run --version
"$BIN" --version || { echo "FAIL: built binary doesn't run"; exit 1; }

echo "PASS: opencode built with v2 router-swap patch ($BIN)"
