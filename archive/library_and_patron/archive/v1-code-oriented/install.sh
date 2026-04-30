#!/usr/bin/env bash
# Install script for library_and_patron
# Run once after cloning to a new machine.
# Safe to re-run — all steps are idempotent.

set -e
REPO="$(cd "$(dirname "$0")" && pwd)"
USER="$(whoami)"

echo "=== library_and_patron install ==="
echo "Repo: $REPO"
echo "User: $USER"
echo ""

# 1. Python venv
if [ ! -d "$REPO/.venv" ]; then
    echo "[1/6] Creating venv..."
    python3 -m venv "$REPO/.venv"
    "$REPO/.venv/bin/pip" install -e ".[dev]" --quiet
    echo "      Done."
else
    echo "[1/6] Venv already exists — skipping"
fi

# 2. ollama-gpu0 system service
echo "[2/6] Installing ollama-gpu0.service..."
sudo cp "$REPO/systemd/ollama-gpu0.service" /etc/systemd/system/ollama-gpu0.service
sudo systemctl daemon-reload
echo "      Installed (NOT enabled — managed by session manager)"

# 3. ollama-gpu1 system service
echo "[3/7] Installing ollama-gpu1.service..."
sudo cp "$REPO/systemd/ollama-gpu1.service" /etc/systemd/system/ollama-gpu1.service
sudo systemctl daemon-reload
echo "      Installed (NOT enabled — managed by session manager)"

# 4. librarian system service
echo "[4/7] Installing librarian.service..."
sudo cp "$REPO/systemd/librarian.service" /etc/systemd/system/librarian.service
# Patch username into service file if not already correct
sudo sed -i "s/User=levine/User=$USER/g" /etc/systemd/system/librarian.service
sudo sed -i "s/Group=levine/Group=$USER/g" /etc/systemd/system/librarian.service
sudo sed -i "s|/home/levine|$HOME|g" /etc/systemd/system/librarian.service
sudo systemctl daemon-reload
echo "      Installed (NOT enabled — managed by session manager)"

# 4. sudoers drop-in
echo "[5/7] Installing sudoers rules..."
sudo cp "$REPO/systemd/ai-session-sudoers" /etc/sudoers.d/ai-session
sudo sed -i "s/levine/$USER/g" /etc/sudoers.d/ai-session
sudo chmod 440 /etc/sudoers.d/ai-session
echo "      Installed at /etc/sudoers.d/ai-session"

# 5. ai-session user service
echo "[6/7] Installing ai-session user service..."
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO/systemd/ai-session.service" "$HOME/.config/systemd/user/ai-session.service"
sed -i "s|/home/levine|$HOME|g" "$HOME/.config/systemd/user/ai-session.service"
systemctl --user daemon-reload
systemctl --user enable ai-session.service
echo "      Enabled (will start on next login)"

# 6. Config dirs
echo "[7/7] Creating config dirs..."
mkdir -p "$HOME/.config/ai-session"
mkdir -p "$HOME/.config/librarian"
mkdir -p "$HOME/.local/share/librarian/lancedb"

if [ ! -f "$HOME/.config/ai-session/config.yaml" ]; then
    cp "$REPO/systemd/../" /dev/null 2>/dev/null || true
    echo "      NOTE: Copy config templates from docs/config-examples/ if needed"
fi

echo ""
echo "=== Install complete ==="
echo ""
echo "Next steps:"
echo "  1. Disable the stock Ollama service if present:"
echo "       sudo systemctl disable ollama.service"
echo "       sudo rm -f /etc/systemd/system/ollama.service /etc/systemd/system/ollama.service.d/override.conf"
echo ""
echo "  2. Start the session manager now:"
echo "       systemctl --user start ai-session.service"
echo ""
echo "  3. Open VSCodium or Aider — GPU services will start automatically"
echo ""
echo "  4. Index your first repo from Cline:"
echo "       index_repo_tool(repo_path='/path/to/your/repo')"
