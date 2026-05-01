# Second User Setup

How to onboard an additional local or remote user onto an existing 2GPU workstation installation.

The system-level pieces (llama.cpp, models, systemd units, polkit rule, opencode-patched binary, llama-shutdown) are already installed. A second user needs only the user-space pieces.

## Who this is for

A second person who will either:
- **Work locally** on the workstation (sit at the machine or SSH in)
- **Work remotely** from a laptop (SSHFS reverse mount + SSH to run opencode, Zed locally)

## Steps

### 1. Polkit — add user to llama service grant

Edit `/etc/polkit-1/rules.d/10-llama-services.rules` and add the new username to the condition:

```js
if (subject.user === "<admin>" || subject.user === "newuser") {
    return polkit.Result.YES;
}
```

> **Known issue:** usernames are hardcoded. See `docs/repo-issues.md` for the planned fix.

### 2. Clone the repo as the new user

```bash
sudo -u newuser mkdir -p /home/newuser/Documents/Repos
sudo -u newuser git clone --recurse-submodules \
  https://github.com/JoshWrites/2gpu-local-ai-workstation.git \
  /home/newuser/Documents/Repos/2gpu-local-ai-workstation
```

If the Library submodule fails (private repo / no key), copy from the existing install:

```bash
sudo cp -r /home/<admin>/Documents/Repos/2gpu-local-ai-workstation/Library/. \
           /home/newuser/Documents/Repos/2gpu-local-ai-workstation/Library
sudo chown -R newuser:newuser /home/newuser/Documents/Repos/2gpu-local-ai-workstation/Library
```

Note the trailing `/. ` on the source path — avoids creating a nested `Library/Library/`.

### 3. Install env files (install.md step 4)

```bash
sudo -u newuser mkdir -p /home/newuser/.config/workstation

sudo -u newuser tee /home/newuser/.config/workstation/user.env > /dev/null << 'EOF'
WS_USER_ROOT=/home/newuser/Documents/Repos/2gpu-local-ai-workstation
WS_LIBRARY_ROOT=$WS_USER_ROOT/Library
WS_ZED_PROFILE_DIR=/home/newuser/.local/share/zed-second-opinion
WS_USER_MODELS_DIR=/home/newuser/models-experiments
# Optional: extra skill directories opencode should scan beyond its
# default ~/.claude/skills and ~/.agents/skills (colon-separated paths,
# tildes expanded). E.g.:
# WS_OPENCODE_SKILL_PATHS=/home/newuser/.claude/plugins/cache/claude-plugins-official/superpowers/5.0.7/skills
EOF

sudo -u newuser tee /home/newuser/.config/workstation/secrets.env > /dev/null << 'EOF'
WS_PROXMOX_USER=<your-proxmox-user>
WS_PROXMOX_HOST=<your-proxmox-host>
# Or leave both empty if you don't have a Proxmox host (see docs/repo-issues.md).
EOF
sudo chmod 600 /home/newuser/.config/workstation/secrets.env
sudo chown newuser:newuser /home/newuser/.config/workstation/secrets.env
```

### 4. Symlink AGENTS.md (install.md step 10)

```bash
sudo -u newuser mkdir -p /home/newuser/.config/opencode
sudo -u newuser ln -sf \
  /home/newuser/Documents/Repos/2gpu-local-ai-workstation/configs/opencode/AGENTS.md \
  /home/newuser/.config/opencode/AGENTS.md
```

### 5. Install uv and sync Library venv (install.md step 8)

```bash
sudo -u newuser bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
sudo -u newuser bash -c '
  cd /home/newuser/Documents/Repos/2gpu-local-ai-workstation/Library
  /home/newuser/.local/bin/uv sync
'
```

### 6. Create Zed isolated profile (install.md step 9)

```bash
sudo -u newuser mkdir -p /home/newuser/.local/share/zed-second-opinion/config
sudo -u newuser tee /home/newuser/.local/share/zed-second-opinion/config/settings.json > /dev/null << 'EOF'
{
  "cli_default_open_behavior": "existing_window",
  "agent_servers": {
    "opencode": {
      "command": "/home/newuser/Documents/Repos/2gpu-local-ai-workstation/scripts/opencode-session.sh",
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
  },
  "feature_flags": { "acp-beta": "on" }
}
EOF
```

The `feature_flags.acp-beta` flag turns on Zed's live context-window
indicator (a ring with a percentage, next to the model picker). Opencode
already emits the underlying `usage_update` events on every turn; the
flag is what makes Zed render them.

### 7. Verify (install.md step 7 equivalent)

SSH in as the new user and confirm polkit works:

```bash
ssh newuser@localhost
systemctl start llama-primary.service   # should succeed without password
curl -fs http://127.0.0.1:11434/v1/models | jq '.data[0].id'
systemctl stop llama-primary.service
```

## Remote laptop setup

If the user will work from a laptop rather than locally, follow the additional steps in:
`docs/remote-user-setup.md` (Phase B)

Key pieces:
- `~/bin/opencode-remote-session` — SSHFS + cwd translation + opencode over SSH
- `~/bin/2gpu-remote-launch` — WoL + SSH wait + llama start + Zed
- `~/.local/share/applications/zed-2gpu-remote.desktop` — one-click launcher
- llama-coder systemd drop-in to listen on `0.0.0.0` for Zed edit-predictions
