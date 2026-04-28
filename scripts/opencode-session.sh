#!/usr/bin/env bash
# opencode-session — preflight the local AI stack, then launch opencode.
#
# What this does on every invocation:
#   1. pkill any rogue llama-server / ollama processes not under systemd
#   2. systemctl start llama-primary, llama-secondary, llama-embed
#      (system-scoped units, polkit grants permission to levine & anny)
#   3. Wait for all three endpoints (:11434, :11435, :11437) to respond
#   4. exec opencode with the invoking args
#
# On exit (clean or signalled): calls `llama-shutdown`, which refuses to
# stop services if anny (or anyone else) has active connections. Services
# stay up as long as someone is using them. See llama-shutdown --help.
#
# Aliased to `opencode` in zsh; invoke the raw binary directly at
# ~/.opencode/bin/opencode if you ever want to bypass this.

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────

OPENCODE_BIN="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"
LLAMA_UNITS=(llama-primary llama-secondary llama-embed)
ENDPOINTS=(
  "11434"   # llama-primary
  "11435"   # llama-secondary
  "11437"   # llama-embed
)
WAIT_TIMEOUT_SEC=60

# ── Utilities ────────────────────────────────────────────────────────────────

log() { printf "\e[36m[opencode-session]\e[0m %s\n" "$*" >&2; }
warn() { printf "\e[33m[opencode-session]\e[0m WARN: %s\n" "$*" >&2; }
err() { printf "\e[31m[opencode-session]\e[0m ERROR: %s\n" "$*" >&2; }

# ── Preflight ────────────────────────────────────────────────────────────────

pkill_rogue_servers() {
  # Kill any llama-server or ollama process not spawned by systemd (those
  # are OK — systemctl stop will handle them on teardown). Shell-launched
  # ones would fight for ports and we can't tell them apart cleanly, so we
  # just kill anything on our target ports.
  local found=0
  for port in "${ENDPOINTS[@]}"; do
    # lsof might not be available; use ss with pid column
    local pids
    pids=$(ss -lntpH 2>/dev/null | awk -v p=":${port}" '$4 ~ p {
      n = split($6, a, ",");
      for (i = 1; i <= n; i++) if (a[i] ~ /pid=/) {
        gsub(/[^0-9]/, "", a[i]); print a[i]
      }
    }' | sort -u)
    for pid in $pids; do
      # Skip if pid belongs to one of our systemd units (comm matches)
      local comm
      comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
      if [[ -z "$comm" ]]; then continue; fi
      # Be aggressive: kill llama-server / ollama on our ports regardless of parent.
      # systemd will restart its own managed instance after we start units below.
      if [[ "$comm" =~ ^(llama-server|ollama)$ ]]; then
        log "killing rogue $comm (pid=$pid) on :$port"
        kill "$pid" 2>/dev/null || true
        found=1
      fi
    done
  done
  if (( found )); then
    sleep 1  # give ports a moment to free
  fi
}

ensure_units_loaded() {
  # Units live at /etc/systemd/system/ (system scope) and are managed by
  # root. We don't own them; no daemon-reload. Just verify they exist so
  # we fail fast with a clear message rather than a cryptic systemctl
  # error if something got moved.
  for u in "${LLAMA_UNITS[@]}"; do
    if ! systemctl cat "${u}.service" >/dev/null 2>&1; then
      err "unit not found: ${u}.service"
      err "expected at /etc/systemd/system/${u}.service"
      exit 1
    fi
  done
}

start_services() {
  log "starting: ${LLAMA_UNITS[*]}"
  # System-scoped units; polkit rule at /etc/polkit-1/rules.d/10-llama-services.rules
  # grants this without password for levine and anny. If the rule is missing
  # or you're running as a different user, systemctl will prompt or fail.
  systemctl start "${LLAMA_UNITS[@]/%/.service}"
}

wait_for_endpoints() {
  local start_ts deadline
  start_ts=$(date +%s)
  deadline=$(( start_ts + WAIT_TIMEOUT_SEC ))
  log "waiting for endpoints on :${ENDPOINTS[*]} (up to ${WAIT_TIMEOUT_SEC}s)"
  while :; do
    local all_up=1
    for port in "${ENDPOINTS[@]}"; do
      if ! curl -fs --max-time 2 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
        all_up=0
        break
      fi
    done
    if (( all_up )); then
      local elapsed=$(( $(date +%s) - start_ts ))
      log "all endpoints up (${elapsed}s)"
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      err "timed out waiting for endpoints. Service states:"
      for u in "${LLAMA_UNITS[@]}"; do
        systemctl status "$u" --no-pager -n 5 2>&1 | head -15 >&2
      done
      return 1
    fi
    sleep 1
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────
#
# Service lifecycle is owned by the launcher (second-opinion-launch.sh) and
# by the manual `llama-shutdown` command. This wrapper only brings llama up
# if it isn't already and then runs opencode. On exit we leave services
# running — terminal opencode and Zed-spawned opencode share endpoints, and
# tearing down here would yank them out from under a still-active session.

if [[ ! -x "$OPENCODE_BIN" ]]; then
  err "opencode binary not found or not executable at: $OPENCODE_BIN"
  err "set OPENCODE_BIN env var to override."
  exit 1
fi

pkill_rogue_servers
ensure_units_loaded
start_services
wait_for_endpoints || {
  err "endpoints did not come up; aborting before opencode launch"
  exit 1
}

log "launching opencode: $OPENCODE_BIN $*"
exec "$OPENCODE_BIN" "$@"
