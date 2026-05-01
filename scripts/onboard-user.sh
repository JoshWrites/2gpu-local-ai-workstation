#!/usr/bin/env bash
# onboard-user: set up a second local user on an existing 2GPU workstation install.
#
# Run as the admin user (or any sudoer) after the system-level pieces are already installed:
#   sudo ./scripts/onboard-user.sh <username>
#
# What this does (mirrors install.md steps 4, 8, 9, 10 for the new user):
#   1. Creates ~/.config/workstation/user.env and secrets.env
#   2. Creates ~/.config/opencode/ and symlinks AGENTS.md from the user's repo clone
#   3. Copies Library from the admin user's clone (avoids submodule auth issues)
#   4. Installs uv and runs uv sync for the Library MCP venv
#   5. Creates the Zed isolated profile (zed-second-opinion)
#
# Prerequisites:
#   - The new user account already exists (useradd/adduser)
#   - The new user is already in the polkit rule (10-llama-services.rules)
#   - the admin's clone at ~/Documents/Repos/2gpu-local-ai-workstation is the source of truth
#
# Does NOT:
#   - Clone the umbrella repo (assumed already done, or do it manually first)
#   - Add the user to polkit (edit /etc/polkit-1/rules.d/10-llama-services.rules manually)
#   - Set up laptop-side launcher (see docs/remote-user-setup.md, Phase B)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_LIBRARY="$REPO/Library"

# ── Args ─────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: sudo $0 <username>" >&2
  exit 1
fi

TARGET_USER="$1"
TARGET_HOME="/home/${TARGET_USER}"
TARGET_REPO="${TARGET_HOME}/Documents/Repos/2gpu-local-ai-workstation"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "ERROR: user '$TARGET_USER' does not exist." >&2
  exit 1
fi

log() { printf "\e[36m[onboard-user]\e[0m %s\n" "$*"; }
ok()  { printf "\e[32m[onboard-user]\e[0m ✓ %s\n" "$*"; }
err() { printf "\e[31m[onboard-user]\e[0m ERROR: %s\n" "$*" >&2; }

run_as() { sudo -u "$TARGET_USER" bash -c "$*"; }

log "onboarding user: $TARGET_USER"
log "target home:     $TARGET_HOME"
log "target repo:     $TARGET_REPO"

# ── Step 1: Ensure repo clone exists ─────────────────────────────────────────

if [[ ! -d "$TARGET_REPO" ]]; then
  log "cloning umbrella repo for $TARGET_USER..."
  run_as "mkdir -p '${TARGET_HOME}/Documents/Repos'"
  sudo -u "$TARGET_USER" git clone --recurse-submodules \
    https://github.com/JoshWrites/2gpu-local-ai-workstation.git \
    "$TARGET_REPO" 2>/dev/null || {
    log "submodule clone failed (Library may be private) — copying from source install..."
    sudo -u "$TARGET_USER" git clone \
      https://github.com/JoshWrites/2gpu-local-ai-workstation.git \
      "$TARGET_REPO"
  }
fi
ok "repo present at $TARGET_REPO"

# ── Step 2: Copy Library (handles private submodule) ─────────────────────────

TARGET_LIBRARY="${TARGET_REPO}/Library"
if [[ ! -f "${TARGET_LIBRARY}/pyproject.toml" ]]; then
  log "copying Library from source install..."
  if [[ ! -d "$SOURCE_LIBRARY" || ! -f "${SOURCE_LIBRARY}/pyproject.toml" ]]; then
    err "source Library not found or incomplete at $SOURCE_LIBRARY"
    exit 1
  fi
  rm -rf "$TARGET_LIBRARY"
  cp -r "${SOURCE_LIBRARY}/." "$TARGET_LIBRARY"
  chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_LIBRARY"
  ok "Library copied"
else
  ok "Library already present"
fi

# ── Step 3: Env files ─────────────────────────────────────────────────────────

CONFIG_DIR="${TARGET_HOME}/.config/workstation"
run_as "mkdir -p '${CONFIG_DIR}'"

USER_ENV="${CONFIG_DIR}/user.env"
if [[ ! -f "$USER_ENV" ]]; then
  log "writing user.env..."
  sudo -u "$TARGET_USER" tee "$USER_ENV" > /dev/null << EOF
WS_USER_ROOT=${TARGET_REPO}
WS_LIBRARY_ROOT=\$WS_USER_ROOT/Library
WS_ZED_PROFILE_DIR=${TARGET_HOME}/.local/share/zed-second-opinion
WS_USER_MODELS_DIR=${TARGET_HOME}/models-experiments
# Optional: colon-separated personal skill directories for the Library MCP.
# WS_SKILLS_DIRS=${TARGET_HOME}/skills-personal:${TARGET_HOME}/.claude/skills
EOF
  ok "user.env written"
else
  ok "user.env already exists — skipping"
fi

SECRETS_ENV="${CONFIG_DIR}/secrets.env"
if [[ ! -f "$SECRETS_ENV" ]]; then
  log "writing secrets.env..."
  # Read from system.env if available, otherwise prompt
  if [[ -r /etc/workstation/system.env ]]; then
    . /etc/workstation/system.env
  fi
  if [[ -z "${WS_PROXMOX_USER:-}" ]]; then
    read -rp "Proxmox SSH user (WS_PROXMOX_USER): " WS_PROXMOX_USER
  fi
  if [[ -z "${WS_PROXMOX_HOST:-}" ]]; then
    read -rp "Proxmox SSH host/IP (WS_PROXMOX_HOST): " WS_PROXMOX_HOST
  fi
  sudo -u "$TARGET_USER" tee "$SECRETS_ENV" > /dev/null << EOF
WS_PROXMOX_USER=${WS_PROXMOX_USER}
WS_PROXMOX_HOST=${WS_PROXMOX_HOST}
EOF
  chmod 600 "$SECRETS_ENV"
  chown "${TARGET_USER}:${TARGET_USER}" "$SECRETS_ENV"
  ok "secrets.env written (mode 0600)"
else
  ok "secrets.env already exists — skipping"
fi

# ── Step 4: AGENTS.md symlink ─────────────────────────────────────────────────

OPENCODE_CONFIG="${TARGET_HOME}/.config/opencode"
run_as "mkdir -p '${OPENCODE_CONFIG}'"

AGENTS_LINK="${OPENCODE_CONFIG}/AGENTS.md"
AGENTS_TARGET="${TARGET_REPO}/configs/opencode/AGENTS.md"
if [[ ! -L "$AGENTS_LINK" ]]; then
  sudo -u "$TARGET_USER" ln -sf "$AGENTS_TARGET" "$AGENTS_LINK"
  ok "AGENTS.md symlinked"
else
  ok "AGENTS.md symlink already exists"
fi

# ── Step 5: uv + Library venv ─────────────────────────────────────────────────

UV_BIN="${TARGET_HOME}/.local/bin/uv"
if [[ ! -x "$UV_BIN" ]]; then
  log "installing uv for $TARGET_USER..."
  sudo -u "$TARGET_USER" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  ok "uv installed"
else
  ok "uv already installed"
fi

VENV="${TARGET_LIBRARY}/.venv"
if [[ ! -d "$VENV" ]]; then
  log "syncing Library venv..."
  sudo -u "$TARGET_USER" bash -c "cd '${TARGET_LIBRARY}' && '${UV_BIN}' sync"
  ok "Library venv ready"
else
  ok "Library venv already exists"
fi

# ── Step 6: Zed isolated profile ──────────────────────────────────────────────

ZED_PROFILE="${TARGET_HOME}/.local/share/zed-second-opinion/config"
run_as "mkdir -p '${ZED_PROFILE}'"

ZED_SETTINGS="${ZED_PROFILE}/settings.json"
if [[ ! -f "$ZED_SETTINGS" ]]; then
  log "writing Zed isolated profile..."
  sudo -u "$TARGET_USER" tee "$ZED_SETTINGS" > /dev/null << EOF
{
  "cli_default_open_behavior": "existing_window",
  "agent_servers": {
    "opencode": {
      "command": "${TARGET_REPO}/scripts/opencode-session.sh",
      "args": ["acp"],
      "env": {
        "OPENCODE_BIN": "/usr/local/bin/opencode-patched",
        "OPENCODE_DISABLE_CHANNEL_DB": "1"
      }
    }
  },
  "base_keymap": "Cursor",
  "theme": { "mode": "system", "light": "One Light", "dark": "One Dark" },
  "edit_predictions": {
    "provider": "open_ai_compatible_api",
    "open_ai_compatible_api": {
      "api_url": "http://127.0.0.1:11438/v1/completions",
      "model": "qwen2.5-coder-3b",
      "prompt_format": "qwen",
      "max_output_tokens": 64
    }
  }
}
EOF
  ok "Zed profile written"
else
  ok "Zed profile already exists — skipping"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
log "onboarding complete for $TARGET_USER"
echo ""
echo "Next steps:"
echo "  1. Verify polkit: ssh ${TARGET_USER}@localhost 'systemctl start llama-primary.service'"
echo "  2. For remote laptop setup: see docs/remote-user-setup.md (Phase B)"
echo "  3. Commit docs/second-user-setup.md and this script to the repo"
