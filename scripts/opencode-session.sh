#!/usr/bin/env bash
# opencode-session: render opencode.json, preflight the local AI stack,
# then launch opencode.
#
# What this does on every invocation:
#   1. Source /etc/workstation/system.env, ~/.config/workstation/user.env,
#      and ~/.config/workstation/secrets.env
#   2. Render configs/opencode/opencode.json.template -> ~/.config/opencode/
#      opencode.json with env-var substitution. Validates JSON, atomically
#      replaces the live file. Preserves the runtime "model" field across
#      renders so model-swap edits survive.
#   3. pkill any rogue llama-server or ollama processes not under systemd
#   4. systemctl start the four llama units (system-scoped; polkit grants
#      both local users)
#   5. Wait for all four endpoints to respond
#   6. exec opencode with the invoking args
#
# On exit, this script does NOT call llama-shutdown. The launcher owns
# service lifecycle. Terminal opencode and Zed-spawned opencode share
# endpoints; tearing down here would yank them from under a still-active
# session.
#
# Aliased to `opencode` in zsh. Invoke the raw binary directly at
# ~/.opencode/bin/opencode to bypass this wrapper.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Env files ────────────────────────────────────────────────────────────────

if [[ ! -r /etc/workstation/system.env ]]; then
  echo "ERROR: /etc/workstation/system.env not readable." >&2
  echo "       See $REPO/configs/workstation/README.md for install steps." >&2
  exit 1
fi

# `set -a` auto-exports every variable assigned in sourced files. envsubst
# (used by the opencode.json render step) only sees exported env vars,
# not shell locals. The `.env` files use plain KEY=value syntax, so
# without auto-export they would be shell-local and envsubst would
# substitute them as empty strings.
set -a
. /etc/workstation/system.env

# user.env optional; sourced if present so per-user overrides land.
if [[ -r "$HOME/.config/workstation/user.env" ]]; then
  . "$HOME/.config/workstation/user.env"
fi

# secrets.env is required because the opencode.json template references
# WS_PROXMOX_USER and WS_PROXMOX_HOST in its permission rules. If those
# vars are missing, the rendered file would have empty SSH targets and
# every SSH-prefixed command would match the bare-prompt fallback.
if [[ ! -r "$HOME/.config/workstation/secrets.env" ]]; then
  set +a
  echo "ERROR: ~/.config/workstation/secrets.env not readable." >&2
  echo "       See $REPO/configs/workstation/README.md for install steps." >&2
  exit 1
fi
. "$HOME/.config/workstation/secrets.env"

# HOME is already exported by the parent shell, but the template uses
# ${HOME} so we need it in envsubst's view too. Already there.
set +a

# ── Paths and config derived from env ────────────────────────────────────────

OPENCODE_BIN="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"
LLAMA_UNITS=(llama-primary llama-secondary llama-embed llama-coder)
ENDPOINTS=(
  "$WS_PORT_PRIMARY"
  "$WS_PORT_SECONDARY"
  "$WS_PORT_EMBED"
  "$WS_PORT_CODER"
)
WAIT_TIMEOUT_SEC=60

OPENCODE_TEMPLATE="$REPO/configs/opencode/opencode.json.template"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

# Fields preserved from the existing rendered file across renders. The
# template default for these is what a fresh deploy gets; subsequent
# renders read the user-edited value and copy it forward. Today the
# only such field is "model", which the user changes when swapping
# models for a task.
PRESERVE_FIELDS=(model)

# ── Utilities ────────────────────────────────────────────────────────────────

log() { printf "\e[36m[opencode-session]\e[0m %s\n" "$*" >&2; }
warn() { printf "\e[33m[opencode-session]\e[0m WARN: %s\n" "$*" >&2; }
err() { printf "\e[31m[opencode-session]\e[0m ERROR: %s\n" "$*" >&2; }

# ── Render opencode.json ─────────────────────────────────────────────────────

render_opencode_config() {
  # Render the opencode.json template with current env values. Preserves
  # specific runtime-tunable fields from the existing rendered file
  # (PRESERVE_FIELDS, currently just "model"). Atomic replace via mv on
  # the same filesystem; either the new file lands fully or the old one
  # stays in place.
  #
  # Hard-fails on any error: missing template, render failure, invalid
  # JSON output. Better to refuse to launch than to start opencode with
  # silently broken config.

  if [[ ! -r "$OPENCODE_TEMPLATE" ]]; then
    err "opencode.json template missing at $OPENCODE_TEMPLATE"
    return 1
  fi

  mkdir -p "$(dirname "$OPENCODE_CONFIG")"

  local tmp="${OPENCODE_CONFIG}.tmp.$$"
  # Always remove the temp file on exit, even on signal interrupt.
  trap "rm -f '$tmp'" EXIT

  # envsubst expands every ${...} and $NAME by default, including ones
  # we did not intend to template. opencode.json contains "$schema" as a
  # JSON key, which a default envsubst would rewrite to "" (empty key).
  # Restrict to a named list so only our WS_* and HOME placeholders get
  # substituted; literal $names are left alone.
  local vars='${WS_PORT_PRIMARY} ${WS_PORT_SECONDARY} ${WS_PORT_EMBED} ${WS_PORT_CODER}'
  vars+=' ${WS_LIBRARY_ROOT} ${WS_PROXMOX_USER} ${WS_PROXMOX_HOST} ${HOME}'

  if ! envsubst "$vars" < "$OPENCODE_TEMPLATE" > "$tmp" 2>/dev/null; then
    err "envsubst failed rendering $OPENCODE_TEMPLATE"
    return 1
  fi

  # Preserve runtime fields from the existing rendered file. Only fires
  # if the existing file is valid JSON; if it is not, we treat that as
  # a fresh-render case and use template defaults.
  if [[ -f "$OPENCODE_CONFIG" ]] && jq empty "$OPENCODE_CONFIG" >/dev/null 2>&1; then
    local field
    for field in "${PRESERVE_FIELDS[@]}"; do
      local current_value
      current_value=$(jq -r --arg f "$field" '.[$f] // empty' "$OPENCODE_CONFIG")
      if [[ -n "$current_value" ]]; then
        local merged="${tmp}.merged"
        if jq --arg f "$field" --arg v "$current_value" '.[$f] = $v' "$tmp" > "$merged" 2>/dev/null; then
          mv "$merged" "$tmp"
        else
          warn "could not preserve $field; using template default"
        fi
      fi
    done
  fi

  # Validate before promoting. Catches stray ${UNDEFINED} that envsubst
  # left as empty strings inside JSON values, and any other malformed
  # JSON. If validation fails, the existing rendered file is untouched.
  if ! jq empty "$tmp" >/dev/null 2>&1; then
    err "rendered opencode.json is not valid JSON"
    err "  template: $OPENCODE_TEMPLATE"
    err "  bad output preserved at: $tmp"
    err "  jq error:"
    jq empty "$tmp" 2>&1 | sed 's/^/    /' >&2
    # Do not delete tmp on this path; the user needs it to debug.
    trap - EXIT
    return 1
  fi

  # Atomic promote. If $OPENCODE_CONFIG is a symlink (the pre-Phase-1
  # state pointed at the in-repo opencode.json), `mv -f` would follow
  # the link and overwrite the target file in the repo. Remove first,
  # then mv. The window between rm and mv is brief; opencode is not
  # running yet, so it cannot read mid-window.
  if [[ -L "$OPENCODE_CONFIG" ]]; then
    rm -f "$OPENCODE_CONFIG"
  fi
  mv -f "$tmp" "$OPENCODE_CONFIG"
  trap - EXIT
  log "rendered $OPENCODE_CONFIG from template"
}

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
# Service lifecycle is owned by the launcher (2gpu-launch.sh) and
# by the manual `llama-shutdown` command. This wrapper only brings llama up
# if it isn't already and then runs opencode. On exit we leave services
# running — terminal opencode and Zed-spawned opencode share endpoints, and
# tearing down here would yank them out from under a still-active session.

if [[ ! -x "$OPENCODE_BIN" ]]; then
  err "opencode binary not found or not executable at: $OPENCODE_BIN"
  err "set OPENCODE_BIN env var to override."
  exit 1
fi

# Render config first. Hard-fail before touching services if the
# render produces bad JSON or hits a missing template.
render_opencode_config || {
  err "config render failed; aborting before opencode launch"
  exit 1
}

pkill_rogue_servers
ensure_units_loaded
start_services
wait_for_endpoints || {
  err "endpoints did not come up; aborting before opencode launch"
  exit 1
}

log "launching opencode: $OPENCODE_BIN $*"
exec "$OPENCODE_BIN" "$@"
