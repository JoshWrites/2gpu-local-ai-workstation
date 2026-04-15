#!/usr/bin/env bash
set -euo pipefail

# Isolated VSCodium instance for the second-opinion agentic stack.
# Separate user-data and extensions dirs keep Roo Code and experimental
# config off the normal editor.

DATA_DIR="${HOME}/.config/VSCodium-second-opinion"
EXT_DIR="${HOME}/.vscodium-second-opinion/extensions"

mkdir -p "$DATA_DIR" "$EXT_DIR"

# Default to opening the second-opinion repo so --wait has something to hold on.
DEFAULT_OPEN="${HOME}/Documents/Repos/Workstation/second-opinion"
ARGS=("$@")
if [[ ${#ARGS[@]} -eq 0 ]]; then
  ARGS=("$DEFAULT_OPEN")
elif [[ "${ARGS[0]}" == "--wait" && ${#ARGS[@]} -eq 1 ]]; then
  ARGS=("--wait" "$DEFAULT_OPEN")
fi

exec /usr/bin/codium \
  --user-data-dir "$DATA_DIR" \
  --extensions-dir "$EXT_DIR" \
  "${ARGS[@]}"
