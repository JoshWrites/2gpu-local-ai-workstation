#!/usr/bin/env bash
# Test --execute mode emits the documented heartbeat protocol and exits 0
# on a successful load. Stubs the router via a tiny Python HTTP server
# that responds to /models and /models/load.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/model-swap.sh"
FIXTURE="$REPO/tests/model-swap-modes/fixtures/primary-pool.json"

# Start a stub router on a random port that returns "loading" twice
# then "loaded".
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - <<PYEOF &
import http.server, json, sys
state = {"calls": 0}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a, **kw): pass
    def _send(self, body):
        b = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_POST(self):
        if self.path == "/models/load":
            self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def do_GET(self):
        if self.path == "/models":
            state["calls"] += 1
            status = "loading" if state["calls"] < 3 else "loaded"
            self._send({"data":[{"id":"tiny-test-model","status":{"value":status}}]})
http.server.HTTPServer(("127.0.0.1", $PORT), H).serve_forever()
PYEOF
STUB_PID=$!
trap "kill $STUB_PID 2>/dev/null" EXIT
sleep 0.3   # let the stub bind

export WS_PRIMARY_POOL="$FIXTURE"
export WS_ROUTER_BASE="http://127.0.0.1:$PORT"

# Override poll interval so the test finishes in <2s instead of >10s
export WS_TEST_POLL_INTERVAL=0.1
export WS_TEST_HEARTBEAT_EVERY=2   # heartbeat every 2nd poll for tests

out=$("$SCRIPT" --execute tiny-test-model)
echo "--- captured output ---"
echo "$out"
echo "-----------------------"

echo "$out" | grep -q "^\[swap\] Loading tiny-test-model" \
  || { echo "FAIL: missing 'Loading' line"; exit 1; }
echo "$out" | grep -q "^\[swap\] /models/load accepted" \
  || { echo "FAIL: missing '/models/load accepted' line"; exit 1; }
echo "$out" | grep -qE "^\[swap\] ✓ tiny-test-model loaded \([0-9]+s\)" \
  || { echo "FAIL: missing or malformed '✓ loaded' line"; exit 1; }
# With WS_TEST_HEARTBEAT_EVERY=2 and 3 polls (loading/loading/loaded), the
# heartbeat MUST fire after the 2nd non-terminal poll. Asserting this
# protects the wire-format guarantee even if the heartbeat block ever
# regresses or gets dropped accidentally.
echo "$out" | grep -qE "^\[swap\] still loading \([0-9]+s\)" \
  || { echo "FAIL: missing heartbeat 'still loading' line"; exit 1; }

echo "PASS: --execute mode emits documented heartbeat protocol"

# Failure path: stub returns "failed" status
PORT2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - <<PYEOF &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a, **kw): pass
    def _send(self, b):
        d = json.dumps(b).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_POST(self):
        if self.path == "/models/load":
            self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def do_GET(self):
        if self.path == "/models":
            self._send({"data":[{"id":"tiny-test-model","status":{"value":"failed"}}]})
http.server.HTTPServer(("127.0.0.1", $PORT2), H).serve_forever()
PYEOF
STUB2=$!
# Update trap immediately after the fork, before the sleep — closes the
# race window where Ctrl-C between the fork and the trap update would
# leak STUB2 on its random port.
trap "kill $STUB_PID $STUB2 2>/dev/null" EXIT
sleep 0.3

export WS_ROUTER_BASE="http://127.0.0.1:$PORT2"
set +e
out=$("$SCRIPT" --execute tiny-test-model 2>&1)
rc=$?
set -e
echo "--- failure-path output ---"
echo "$out"
echo "---------------------------"

[[ "$rc" -eq 1 ]] || { echo "FAIL: expected exit 1 on failure, got $rc"; exit 1; }
echo "$out" | grep -q "^\[swap\] ERROR: status entered 'failed'" \
  || { echo "FAIL: missing failure marker line"; exit 1; }

echo "PASS: --execute exits 1 with ERROR line on router-side failure"
