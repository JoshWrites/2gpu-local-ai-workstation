#!/usr/bin/env bash
# check-anny-zed-isolated-profile.sh — verify whether the canonical
# isolated Zed profile (~/.local/share/zed-2gpu-remote/) is set up on
# anny's laptop, per docs/remote-user-setup.md Phase B6.
#
# Read-only; no fixes.

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

# ─── Zed binary on the laptop ────────────────────────────────────────────────

hdr "Zed binary"
ssh_anny 'echo "--- ~/.local/bin/zed ---"; ls -la ~/.local/bin/zed 2>&1
echo "--- /usr/local/bin/zed ---"; ls -la /usr/local/bin/zed 2>&1
echo "--- which zed (login shell PATH) ---"; bash -lc "command -v zed" 2>&1
echo "--- flatpak ---"; flatpak list 2>/dev/null | grep -i zed || echo "  (no flatpak)"
echo "--- snap ---"; snap list 2>/dev/null | grep -i zed || echo "  (no snap)"'

# ─── Isolated profile directory ──────────────────────────────────────────────

hdr "Isolated Zed profile dir (~/.local/share/zed-2gpu-remote/)"
profile_check=$(ssh_anny '[ -d ~/.local/share/zed-2gpu-remote ] && echo PRESENT || echo MISSING')
case "$profile_check" in
  PRESENT) ok "directory exists"; ssh_anny 'ls -la ~/.local/share/zed-2gpu-remote/ 2>&1' ;;
  MISSING) bad "directory does not exist — setup-laptop.sh has not been run for anny" ;;
  *)       bad "unexpected: $profile_check" ;;
esac

# ─── settings.json contents ──────────────────────────────────────────────────

hdr "Isolated profile settings.json"
settings_check=$(ssh_anny '[ -f ~/.local/share/zed-2gpu-remote/config/settings.json ] && echo PRESENT || echo MISSING')
if [[ "$settings_check" == "PRESENT" ]]; then
  ok "settings.json exists"
  ssh_anny 'cat ~/.local/share/zed-2gpu-remote/config/settings.json 2>&1'

  hdr "settings.json key sanity (agent_servers, edit_predictions, acp-beta)"
  ssh_anny "python3 -c \"
import json, re, os, sys
with open(os.path.expanduser('~/.local/share/zed-2gpu-remote/config/settings.json')) as f:
    raw = f.read()
stripped = re.sub(r'//[^\n]*', '', raw)
stripped = re.sub(r',(\s*[}\]])', r'\1', stripped)
try:
    cfg = json.loads(stripped)
except Exception as e:
    print('PARSE_ERROR:', e); sys.exit(1)

agents = cfg.get('agent_servers', {})
ep = cfg.get('edit_predictions') or cfg.get('language_model_settings', {}).get('zed_predict_settings', {})
ff = cfg.get('feature_flags', {})

print('agent_servers keys:', list(agents.keys()))
oc = agents.get('opencode', {})
print('opencode.command:', oc.get('command'))
print('opencode.args:   ', oc.get('args'))
print('edit_predictions:', json.dumps(ep, indent=2) if ep else 'NONE')
print('feature_flags:   ', json.dumps(ff, indent=2) if ff else 'NONE')
\" 2>&1"
else
  bad "settings.json missing"
fi

# ─── .desktop launcher ───────────────────────────────────────────────────────

hdr ".desktop launcher entry"
desktop_check=$(ssh_anny '[ -f ~/.local/share/applications/zed-2gpu-remote.desktop ] && echo PRESENT || echo MISSING')
if [[ "$desktop_check" == "PRESENT" ]]; then
  ok ".desktop entry present"
  ssh_anny 'cat ~/.local/share/applications/zed-2gpu-remote.desktop 2>&1'
else
  bad ".desktop entry missing"
fi

# ─── PATH check (for ~/bin) ──────────────────────────────────────────────────

hdr "anny's login shell PATH (does ~/bin appear?)"
ssh_anny 'bash -lc "echo \$PATH" | tr ":" "\n" | nl' | head -15

# ─── Summary ─────────────────────────────────────────────────────────────────

printf "\n\e[1mResult: %d passed, %d failed\e[0m\n" "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
  cat <<'EOF'

Likely next step:
  Anny's laptop does not yet have the isolated Zed profile set up
  per docs/remote-user-setup.md Phase B6. The doc references a
  setup-laptop.sh that does not exist in the repo; we'll need to
  either write it or hand-craft the artifacts.
EOF
fi
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
