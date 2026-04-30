#!/usr/bin/env bash
#
# regression.sh - freeze-point and post-phase health check for the
# workstation stack. Asserts the four llama units are active, each
# serves the expected model, the coder and embed endpoints respond,
# VRAM is in budget, configs parse, and the launcher is syntactically
# valid. Exits non-zero on first failure. Run before and after every
# restructuring step.
#
# Usage:
#   bench/regression.sh            run all checks
#   bench/regression.sh --skip-vram  skip VRAM checks (idle services
#                                    can report below the floor)
#   bench/regression.sh --writing-lint  also run the keyboard-ASCII
#                                       check on committed text
#
# Exit codes:
#   0  all checks pass
#   1  one or more checks fail
#   2  required tool missing (cannot proceed)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Settings ───────────────────────────────────────────────────────────

# Service to port to expected-model-substring map. Substring match is
# case-insensitive; the goal is to confirm the right model loaded, not
# match the exact filename.
declare -A SERVICE_PORT=(
  [llama-primary]=11434
  [llama-secondary]=11435
  [llama-embed]=11437
  [llama-coder]=11438
)
declare -A SERVICE_MODEL=(
  [llama-primary]="glm-4"
  [llama-secondary]="qwen3-4b"
  [llama-embed]="multilingual-e5-large"
  [llama-coder]="qwen2.5-coder-3b"
)

# VRAM thresholds in bytes. Idle floor is the minimum we expect when
# weights are loaded but no requests are active. Active ceiling is the
# maximum we tolerate during sustained load. The freeze-point soak
# (E3, 2026-04-29) showed 8.12 GB peak on the secondary card.
VRAM_SECONDARY_FLOOR=$((  2 * 1024 * 1024 * 1024 ))   # 2.0 GB
VRAM_SECONDARY_CEILING=$(( 9 * 1024 * 1024 * 1024 ))  # 9.0 GB (card is 8.57 GB; ceiling above total catches misreads)
VRAM_PRIMARY_CEILING=$(( 22 * 1024 * 1024 * 1024 ))   # 22 GB (card is 25.75 GB)

# Required tools. If any are missing, exit 2.
REQUIRED_TOOLS=(curl jq python3 systemctl ss)

# Required system files.
LLAMA_BIN_DEFAULT="/home/levine/src/llama.cpp/llama-b8799-vulkan/llama-server"
OPENCODE_PATCHED="/usr/local/bin/opencode-patched"
LLAMA_SHUTDOWN="/usr/local/bin/llama-shutdown"
LAUNCHER="$REPO_ROOT/scripts/second-opinion-launch.sh"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
ZED_ISO_CONFIG="$HOME/.local/share/zed-second-opinion/config/settings.json"

# Phase 0 invariant: the env directory does NOT exist yet. If it does,
# we have started Phase 1 already and should not be running the
# freeze-point regression.
PHASE_1_MARKER="/etc/workstation/system.env"

# Default flags.
SKIP_VRAM=0
RUN_LINT=0
WAIT_FOR_STARTUP=0
WAIT_TIMEOUT=180

# ── Output helpers ─────────────────────────────────────────────────────

PASSED=0
FAILED=0
LAST_FAIL_REASON=""

ok()   { printf "  OK    %s\n" "$1";       PASSED=$((PASSED+1)); }
fail() { printf "  FAIL  %s\n" "$1"; FAILED=$((FAILED+1)); LAST_FAIL_REASON="$1"; }
section() { printf "\n[%s] %s\n" "$1" "$2"; }
note()    { printf "  ----  %s\n" "$1"; }

# ── Argument parsing ───────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --skip-vram) SKIP_VRAM=1 ;;
    --writing-lint) RUN_LINT=1 ;;
    --wait-for-startup) WAIT_FOR_STARTUP=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      printf "unknown argument: %s\n" "$arg" >&2
      exit 2
      ;;
  esac
done

# ── Section 1: required tools ──────────────────────────────────────────

section 1 "required tools"
for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "tool present: $tool"
  else
    fail "tool missing: $tool"
    printf "\nCannot proceed without %s. Install it and retry.\n" "$tool" >&2
    exit 2
  fi
done

# ── Section 2: required system files ───────────────────────────────────

section 2 "required system files"

if [[ -x "$LLAMA_BIN_DEFAULT" ]]; then
  ok "llama-server binary present at $LLAMA_BIN_DEFAULT"
else
  fail "llama-server binary missing at $LLAMA_BIN_DEFAULT"
fi

if [[ -x "$OPENCODE_PATCHED" ]]; then
  ok "opencode-patched present at $OPENCODE_PATCHED"
  version_line=$("$OPENCODE_PATCHED" --version 2>/dev/null | head -1)
  if [[ -n "$version_line" ]]; then
    note "opencode-patched version: $version_line"
  fi
else
  fail "opencode-patched missing at $OPENCODE_PATCHED"
fi

if [[ -x "$LLAMA_SHUTDOWN" ]]; then
  ok "llama-shutdown present at $LLAMA_SHUTDOWN"
else
  fail "llama-shutdown missing at $LLAMA_SHUTDOWN"
fi

if [[ -x "$LAUNCHER" ]]; then
  ok "launcher present at $LAUNCHER"
else
  fail "launcher missing at $LAUNCHER"
fi

# ── Section 3: phase marker ────────────────────────────────────────────

section 3 "phase invariant (we are still at the freeze point)"
if [[ -e "$PHASE_1_MARKER" ]]; then
  fail "phase invariant broken: $PHASE_1_MARKER exists; Phase 1 has started"
else
  ok "phase invariant holds: $PHASE_1_MARKER does not exist"
fi

# ── Section 4: systemd unit state ──────────────────────────────────────

section 4 "systemd units active"
for svc in "${!SERVICE_PORT[@]}"; do
  state=$(systemctl is-active "$svc.service" 2>/dev/null)
  if [[ "$state" == "active" ]]; then
    ok "$svc.service is active"
  else
    fail "$svc.service is $state (expected active)"
  fi
done

# ── Section 4b: wait for cold-start (optional) ─────────────────────────

if [[ "$WAIT_FOR_STARTUP" -eq 1 ]]; then
  section 4b "wait for cold-start (--wait-for-startup, max ${WAIT_TIMEOUT}s)"
  for svc in "${!SERVICE_PORT[@]}"; do
    port="${SERVICE_PORT[$svc]}"
    waited=0
    until curl -fsS --max-time 2 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; do
      waited=$((waited + 2))
      if [[ "$waited" -ge "$WAIT_TIMEOUT" ]]; then
        note "$svc on $port still not ready after ${WAIT_TIMEOUT}s"
        break
      fi
      sleep 2
    done
    if [[ "$waited" -lt "$WAIT_TIMEOUT" ]]; then
      ok "$svc on $port ready after ${waited}s"
    fi
  done
fi

# ── Section 5: each port serves a /v1/models response ──────────────────

section 5 "each port serves /v1/models"
for svc in "${!SERVICE_PORT[@]}"; do
  port="${SERVICE_PORT[$svc]}"
  resp=$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/v1/models" 2>/dev/null)
  if [[ -z "$resp" ]]; then
    fail "$svc on $port: no response from /v1/models"
    continue
  fi
  if ! echo "$resp" | python3 -c "import json,sys; json.load(sys.stdin)" >/dev/null 2>&1; then
    fail "$svc on $port: /v1/models returned non-JSON"
    continue
  fi
  ok "$svc on $port: /v1/models returns valid JSON"
done

# ── Section 6: model identity per port ─────────────────────────────────

section 6 "each port serves the expected model"
for svc in "${!SERVICE_PORT[@]}"; do
  port="${SERVICE_PORT[$svc]}"
  expect="${SERVICE_MODEL[$svc]}"
  resp=$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/v1/models" 2>/dev/null)
  id=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
  if [[ -z "$id" ]]; then
    fail "$svc on $port: could not parse model id"
    continue
  fi
  if echo "$id" | grep -qi "$expect"; then
    ok "$svc on $port serves $id"
  else
    fail "$svc on $port: expected substring $expect, got $id"
  fi
done

# ── Section 7: coder endpoint serves /v1/completions ───────────────────

section 7 "coder serves /v1/completions"
coder_text=$(curl -fsS --max-time 15 -X POST \
  "http://127.0.0.1:${SERVICE_PORT[llama-coder]}/v1/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"qwen2.5-coder-3b","prompt":"def add(a, b):\n    ","max_tokens":15,"temperature":0,"stream":false}' \
  2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['text'] if d.get('choices') and d['choices'][0].get('text') else '')" 2>/dev/null)
if [[ -n "$coder_text" ]]; then
  ok "/v1/completions returned text"
else
  fail "/v1/completions returned empty or invalid response"
fi

# ── Section 8: embed endpoint serves /v1/embeddings ────────────────────

section 8 "embed serves /v1/embeddings"
embed_dim=$(curl -fsS --max-time 10 -X POST \
  "http://127.0.0.1:${SERVICE_PORT[llama-embed]}/v1/embeddings" \
  -H 'content-type: application/json' \
  -d '{"input":"hello world","model":"e5"}' \
  2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['data'][0]['embedding']) if d.get('data') and d['data'][0].get('embedding') else 0)" 2>/dev/null)
if [[ "${embed_dim:-0}" -gt 0 ]]; then
  ok "/v1/embeddings returned ${embed_dim}-dim vector"
else
  fail "/v1/embeddings returned no vector"
fi

# ── Section 9: VRAM budget ─────────────────────────────────────────────

if [[ "$SKIP_VRAM" -eq 1 ]]; then
  section 9 "VRAM budget (skipped per --skip-vram)"
  note "vram floor and ceiling checks not run"
else
  section 9 "VRAM budget"
  if ! command -v rocm-smi >/dev/null 2>&1; then
    fail "rocm-smi not present; cannot check VRAM"
  else
    # Card 0 is the 5700 XT (secondary). Card 1 is the 7900 XTX (primary).
    sec_used=$(rocm-smi --showmeminfo vram -d 0 --json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); c=next(iter(d.values())); print(c['VRAM Total Used Memory (B)'])" 2>/dev/null)
    prim_used=$(rocm-smi --showmeminfo vram -d 1 --json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); c=next(iter(d.values())); print(c['VRAM Total Used Memory (B)'])" 2>/dev/null)

    if [[ -z "$sec_used" || -z "$prim_used" ]]; then
      fail "could not parse rocm-smi VRAM output"
    else
      sec_gb=$(python3 -c "print(round($sec_used/1e9, 2))")
      prim_gb=$(python3 -c "print(round($prim_used/1e9, 2))")

      if [[ "$sec_used" -lt "$VRAM_SECONDARY_CEILING" ]]; then
        ok "secondary card (5700 XT) at ${sec_gb} GB, under ceiling"
      else
        fail "secondary card at ${sec_gb} GB, over ceiling"
      fi

      if [[ "$prim_used" -lt "$VRAM_PRIMARY_CEILING" ]]; then
        ok "primary card (7900 XTX) at ${prim_gb} GB, under ceiling"
      else
        fail "primary card at ${prim_gb} GB, over ceiling"
      fi

      # Floor check: warns about idle floor without failing. If services
      # are warm and weights are loaded, we expect at least the floor.
      if [[ "$sec_used" -lt "$VRAM_SECONDARY_FLOOR" ]]; then
        note "secondary card under idle floor (${sec_gb} GB < $((VRAM_SECONDARY_FLOOR/1024/1024/1024)) GB); services may not have loaded weights yet"
      fi
    fi
  fi
fi

# ── Section 10: config files parse ─────────────────────────────────────

section 10 "config files parse"
if jq . "$OPENCODE_CONFIG" >/dev/null 2>&1; then
  ok "opencode.json parses as JSON"
else
  fail "opencode.json does not parse"
fi

if [[ -f "$ZED_ISO_CONFIG" ]]; then
  if node -e "const fs=require('fs'); const t=fs.readFileSync(process.argv[1],'utf8'); const s=t.replace(/^\s*\/\/.*\$/gm,''); JSON.parse(s.replace(/,(\s*[}\]])/g,'\$1'))" "$ZED_ISO_CONFIG" 2>/dev/null; then
    ok "zed-second-opinion settings.json parses (JSONC tolerated)"
  else
    fail "zed-second-opinion settings.json does not parse"
  fi
else
  fail "zed-second-opinion settings.json not found at $ZED_ISO_CONFIG"
fi

# ── Section 11: launcher script syntax ─────────────────────────────────

section 11 "launcher syntactically valid"
if bash -n "$LAUNCHER" 2>/dev/null; then
  ok "$LAUNCHER passes bash -n"
else
  fail "$LAUNCHER has bash syntax error"
fi

# ── Section 12: editor binary present ──────────────────────────────────

section 12 "editor binary present (Zed)"
zed_bin="$HOME/.local/bin/zed"
if [[ -x "$zed_bin" || -L "$zed_bin" ]]; then
  ok "$zed_bin present"
else
  fail "$zed_bin missing or not executable"
fi

# ── Section 13: known gap (Library MCP probe) ──────────────────────────

section 13 "known gaps"
note "Library MCP probe not yet implemented; planned for Phase 1 once env files exist"

# ── Section 14: writing-style lint (optional) ──────────────────────────

if [[ "$RUN_LINT" -eq 1 ]]; then
  section 14 "writing-style lint (--writing-lint)"
  cd "$REPO_ROOT"
  # Track which files in the working tree have non-ASCII bytes. Files
  # under .git, build artifacts, and binary fixtures are excluded.
  files=$(git ls-files '*.md' '*.txt' '*.sh' '*.py' '*.js' '*.ts' '*.toml' '*.json' '*.service' 2>/dev/null \
    | grep -vE '^(node_modules|\.git|build|dist)' || true)
  violations=0
  if [[ -z "$files" ]]; then
    note "no candidate files to lint"
  else
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      hits=$(LC_ALL=C grep -nP '[^\x00-\x7F]' "$f" 2>/dev/null | head -3 || true)
      if [[ -n "$hits" ]]; then
        violations=$((violations + 1))
        printf "  LINT  %s\n" "$f"
        echo "$hits" | sed 's/^/        /'
      fi
    done <<< "$files"
    if [[ "$violations" -eq 0 ]]; then
      ok "no non-ASCII characters found in committed text"
    else
      note "$violations file(s) have non-ASCII characters; legacy debt for now"
    fi
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────

printf "\n"
printf "regression: %d passed, %d failed\n" "$PASSED" "$FAILED"
if [[ "$FAILED" -eq 0 ]]; then
  printf "result: OK\n"
  exit 0
else
  printf "result: FAIL\n"
  printf "last failure: %s\n" "$LAST_FAIL_REASON"
  exit 1
fi
