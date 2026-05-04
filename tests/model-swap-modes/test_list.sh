#!/usr/bin/env bash
# Test --list mode emits valid JSON merging router state with registry data.
# Stubs the router via Python HTTP server.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/model-swap.sh"
FIXTURE="$REPO/tests/model-swap-modes/fixtures/primary-pool.json"

# Start a stub router that returns three models: tiny-test (loaded),
# big-test (unloaded — both in fixture), and a third "unknown-model"
# that the router knows but the registry doesn't.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - <<PYEOF &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a, **kw): pass
    def _send(self, body):
        b = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path == "/models":
            self._send({"data":[
                {"id":"tiny-test-model","status":{"value":"loaded"}},
                {"id":"big-test-model","status":{"value":"unloaded"}},
                {"id":"unknown-model","status":{"value":"unloaded"}},
            ]})
http.server.HTTPServer(("127.0.0.1", $PORT), H).serve_forever()
PYEOF
STUB_PID=$!
trap "kill $STUB_PID 2>/dev/null" EXIT
sleep 0.3

export WS_PRIMARY_POOL="$FIXTURE"
export WS_ROUTER_BASE="http://127.0.0.1:$PORT"

out=$("$SCRIPT" --list)
echo "--- captured output ---"
echo "$out"
echo "-----------------------"

# Validate the top-level schema
echo "$out" | jq -e 'has("models")' >/dev/null \
  || { echo "FAIL: top-level missing 'models' key"; exit 1; }
echo "$out" | jq -e '.models | type == "array"' >/dev/null \
  || { echo "FAIL: .models is not an array"; exit 1; }
echo "$out" | jq -e '.models | length == 3' >/dev/null \
  || { echo "FAIL: expected 3 models, got something else"; exit 1; }

# Tiny-test: in registry, loaded
echo "$out" | jq -e '.models[] | select(.id == "tiny-test-model") | .status == "loaded" and .in_registry == true and .description == "Toy model for tests, fully GPU-resident"' >/dev/null \
  || { echo "FAIL: tiny-test-model fields wrong"; echo "$out" | jq '.models[] | select(.id == "tiny-test-model")'; exit 1; }

# Big-test: in registry, unloaded
echo "$out" | jq -e '.models[] | select(.id == "big-test-model") | .status == "unloaded" and .in_registry == true' >/dev/null \
  || { echo "FAIL: big-test-model fields wrong"; exit 1; }

# Unknown: NOT in registry, description+display_name null
echo "$out" | jq -e '.models[] | select(.id == "unknown-model") | .in_registry == false and .description == null and .display_name == null' >/dev/null \
  || { echo "FAIL: unknown-model fields wrong"; echo "$out" | jq '.models[] | select(.id == "unknown-model")'; exit 1; }

echo "PASS: --list emits merged JSON with router state + registry data"
