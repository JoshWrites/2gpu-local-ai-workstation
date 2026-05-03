#!/usr/bin/env bash
# check-anny-zed-ready.sh — verify anny's laptop has Zed configured to
# spawn opencode-remote-session as an ACP agent. Read-only.

set -uo pipefail

LAPTOP_HOST="laptop"
ANNY_LAPTOP_USER="anny"

ssh_anny() {
  sudo -n -u anny ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "${ANNY_LAPTOP_USER}@${LAPTOP_HOST}" "$@"
}

PASS=0
FAIL=0
ok()   { printf "  \e[32m✓\e[0m %s\n" "$*"; PASS=$((PASS+1)); }
bad()  { printf "  \e[31m✗\e[0m %s\n" "$*"; FAIL=$((FAIL+1)); }
note() { printf "  \e[33m·\e[0m %s\n" "$*"; }
hdr()  { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }

# ─── Zed installation ────────────────────────────────────────────────────────

hdr "Zed installed and runnable as anny"
zed_check=$(ssh_anny 'command -v zed >/dev/null && zed --version 2>&1 || echo MISSING')
case "$zed_check" in
  MISSING) bad "zed not in PATH on laptop" ;;
  *)       ok "$zed_check" ;;
esac

# ─── Zed settings.json ───────────────────────────────────────────────────────

hdr "Zed user settings.json exists"
SETTINGS_PATH=$(ssh_anny 'for p in ~/.config/zed/settings.json ~/.zed/settings.json; do [ -f "$p" ] && echo "$p" && break; done')
if [[ -z "$SETTINGS_PATH" ]]; then
  bad "no settings.json found at ~/.config/zed/ or ~/.zed/"
else
  ok "settings: $SETTINGS_PATH"
fi

if [[ -n "$SETTINGS_PATH" ]]; then
  hdr "agent_servers config (full block + path resolution)"
  ssh_anny "python3 -c '
import json, os, sys
with open(os.path.expanduser(\"$SETTINGS_PATH\")) as f:
    raw = f.read()
# Strip JSON-with-comments (Zed allows // and trailing commas)
import re
stripped = re.sub(r\"//[^\n]*\", \"\", raw)
stripped = re.sub(r\",(\s*[}\]])\", r\"\1\", stripped)
try:
    cfg = json.loads(stripped)
except Exception as e:
    print(f\"  PARSE_ERROR: {e}\")
    sys.exit(1)
servers = cfg.get(\"agent_servers\", {})
if not servers:
    print(\"  NO_AGENT_SERVERS_KEY\")
    sys.exit(0)
for name, s in servers.items():
    cmd = s.get(\"command\")
    args = s.get(\"args\", [])
    env = s.get(\"env\", {})
    print(f\"  agent: {name}\")
    print(f\"    command: {cmd}\")
    print(f\"    args:    {args}\")
    if env:
        print(f\"    env:     {env}\")
    if cmd:
        from shutil import which
        resolved = which(cmd) or (cmd if os.path.isabs(cmd) and os.path.exists(cmd) else None)
        if resolved:
            executable = os.access(resolved, os.X_OK)
            print(f\"    resolved: {resolved} (executable={executable})\")
        else:
            print(f\"    resolved: NOT FOUND on PATH\")
'"

  hdr "Sanity: does the agent's command point to opencode-remote-session?"
  found=$(ssh_anny "grep -c 'opencode-remote-session' '$SETTINGS_PATH'" 2>/dev/null)
  if [[ "$found" -ge 1 ]]; then
    ok "settings.json references opencode-remote-session"
  else
    bad "settings.json does NOT reference opencode-remote-session — Zed won't know how to launch the workstation agent"
  fi
fi

# ─── Anny's PATH (for shell-PATH resolution from Zed) ────────────────────────

hdr "anny's login PATH (does ~/bin show up?)"
ssh_anny 'echo "$PATH" | tr ":" "\n" | nl' | head -20
in_path=$(ssh_anny "echo \$PATH | tr ':' '\n' | grep -c '^/home/anny/bin\$'")
if [[ "$in_path" -ge 1 ]]; then
  ok "~/bin is on anny's PATH"
else
  note "~/bin NOT on anny's PATH — Zed config must use the absolute path /home/anny/bin/opencode-remote-session"
fi

# ─── Verify the launcher will run cleanly under Zed's expected env ───────────

hdr "Smoke test: invoke the launcher with --help / no-op (should not hang)"
note "skipping — launcher has no --help and exec's into a remote session; running it would block. Use Zed itself to test."

# ─── Summary ─────────────────────────────────────────────────────────────────

printf "\n\e[1mResult: %d passed, %d failed\e[0m\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
