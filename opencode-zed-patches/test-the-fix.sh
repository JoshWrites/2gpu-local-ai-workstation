#!/usr/bin/env bash
# test-the-fix.sh - verify the rawInput patch is actually working
#
# This is a 3-stage test. Each stage is a hard gate; if it fails, stop and
# investigate before proceeding. Run as: bash test-the-fix.sh

set -euo pipefail

BIN="${1:-$HOME/.local/bin/opencode-patched}"
LOG_DIR="$HOME/.local/share/opencode/log"

echo "=== Stage 1: source check (free, no run) ==="
echo "Binary under test: $BIN"
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: $BIN not executable / does not exist"
  exit 1
fi
"$BIN" --version
echo "OK"
echo

echo "=== Stage 2: ACP boot smoke test ==="
# Send a single 'initialize' request and confirm opencode answers without
# crashing. Times out after 10s; opencode acp keeps the stream open.
INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}'
echo "Request: $INIT_REQ"
RESPONSE=$(echo "$INIT_REQ" | timeout 10 "$BIN" acp 2>/dev/null | head -1 || true)
echo "Response (first line): $RESPONSE"
if [[ -z "$RESPONSE" ]]; then
  echo "FAIL: opencode acp returned no output for initialize"
  exit 1
fi
if ! echo "$RESPONSE" | grep -q '"protocolVersion"'; then
  echo "FAIL: response did not contain protocolVersion field"
  exit 1
fi
if ! echo "$RESPONSE" | grep -q '"agentInfo"'; then
  echo "FAIL: response did not contain agentInfo field"
  exit 1
fi
echo "OK: opencode acp boots and responds to initialize"
echo

echo "=== Stage 3: end-to-end via Zed (manual) ==="
cat <<'EOF'
This stage requires Zed pointing at the patched binary. After wiring up
Zed (see install-and-wire.md), do the following IN ZED:

1. Open a project (any git repo with a remote).
2. Open the AI panel, start a new opencode chat.
3. Ask: "run git fetch origin"
4. WATCH the tool-approval prompt that appears in Zed's UI.

PASS criteria:
  - The prompt shows the actual command "git fetch origin" (or similar
    text containing "git fetch"), NOT just an empty "bash" box.
  - You can click Approve / Deny.
  - On Approve, opencode runs the command and shows output.

FAIL criteria:
  - The prompt is still empty.
  - The prompt doesn't appear and the call is silently rejected.

Then VERIFY in opencode's log:
  - Find the active log file (tail on log dir below):
EOF
echo "      $LOG_DIR/"
ls -lat "$LOG_DIR" 2>/dev/null | head -3 || echo "  (no logs yet; run a session first)"
cat <<'EOF'
  - Search the active log for the requestPermission event:
      grep '"method":"session/request_permission"' <logfile>
    OR
      grep -A2 '"requestPermission"' <logfile>
  - The captured event MUST contain "rawInput":{"command":"git fetch...
    NOT "rawInput":{}.

If the log shows "rawInput":{} again, the patch is not active.
If the log shows "rawInput":{"command":...}, the patch works.

EOF
echo "Stages 1+2 PASSED. Stage 3 requires manual UI verification."
