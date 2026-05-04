#!/usr/bin/env bash
# Test --preflight mode emits valid JSON with the documented schema.
# Uses a fixture registry; stubs the router and memory readers via env.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/model-swap.sh"
FIXTURE="$REPO/tests/model-swap-modes/fixtures/primary-pool.json"

# Stub /sys + /proc + router by overriding the helper functions via env.
# The script must support these overrides so tests can run without a
# live router or specific hardware. (Implementation step adds them.)
export WS_PRIMARY_POOL="$FIXTURE"
export WS_TEST_VRAM_TOTAL_MB=24576
export WS_TEST_DRAM_AVAIL_MB=48000
export WS_TEST_CURRENT_LOADED=""        # no current model
export WS_TEST_SESSION_TOKENS=0

out=$("$SCRIPT" --preflight tiny-test-model)
echo "$out" | jq -e '.target.id == "tiny-test-model"' >/dev/null \
  || { echo "FAIL: target.id wrong"; echo "$out"; exit 1; }
echo "$out" | jq -e '.target.description == "Toy model for tests, fully GPU-resident"' >/dev/null \
  || { echo "FAIL: target.description wrong"; exit 1; }
echo "$out" | jq -e '.target.vram_required_mb == 2048' >/dev/null \
  || { echo "FAIL: vram_required_mb wrong"; exit 1; }
echo "$out" | jq -e '.current == null' >/dev/null \
  || { echo "FAIL: current should be null when no model loaded"; exit 1; }
echo "$out" | jq -e '.resources.vram_state == "ok"' >/dev/null \
  || { echo "FAIL: resources.vram_state should be ok"; exit 1; }
echo "$out" | jq -e '.resources.ram_state == "ok"' >/dev/null \
  || { echo "FAIL: resources.ram_state should be ok"; exit 1; }
echo "$out" | jq -e '.soft_block == false' >/dev/null \
  || { echo "FAIL: soft_block should be false"; exit 1; }
echo "$out" | jq -e '.compaction_recommended == false' >/dev/null \
  || { echo "FAIL: compaction_recommended should be false"; exit 1; }

echo "PASS: preflight emits valid JSON for tiny-test-model"

# Soft-block scenario: target VRAM exceeds available
export WS_TEST_VRAM_TOTAL_MB=2048   # tiny — 1 GB after baseline
export WS_TEST_DRAM_AVAIL_MB=48000
export WS_TEST_CURRENT_LOADED=""

out=$("$SCRIPT" --preflight tiny-test-model)
echo "$out" | jq -e '.resources.vram_state == "short"' >/dev/null \
  || { echo "FAIL: vram_state should be 'short' when total < required"; echo "$out"; exit 1; }
echo "$out" | jq -e '.soft_block == true' >/dev/null \
  || { echo "FAIL: soft_block should be true when vram is short"; exit 1; }

echo "PASS: soft-block detected for VRAM-starved scenario"

# Compaction recommendation: current model has bigger context than target
# AND session tokens > target.usable
export WS_TEST_VRAM_TOTAL_MB=24576
export WS_TEST_DRAM_AVAIL_MB=48000
export WS_TEST_CURRENT_LOADED="big-test-model"
export WS_TEST_SESSION_TOKENS=10000   # > 8192 - 20000 = negative, so any positive triggers

# The existing needs_pre_swap_compaction reads current_loaded_model and compares
# against TARGET_CTX. With big-test (131K) currently loaded, swapping to
# tiny-test (8K) and a 10K-token session => recommended.
out=$("$SCRIPT" --preflight tiny-test-model)
echo "$out" | jq -e '.compaction_recommended == true' >/dev/null \
  || { echo "FAIL: compaction_recommended should be true"; echo "$out"; exit 1; }

echo "PASS: compaction recommended when current ctx > target ctx + session overflow"
