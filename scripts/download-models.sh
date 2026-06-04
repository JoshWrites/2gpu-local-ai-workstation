#!/usr/bin/env bash
# download-models.sh -- pull every GGUF named in models.toml from
# HuggingFace into /var/lib/llama-models/<model-id>/<filename>.
#
# Idempotent: skips files that already exist with non-zero size.
# Aborts on any error.
#
# Requires: hf (the HuggingFace CLI, from `uv tool install huggingface_hub`
# or `pip install huggingface_hub`; formerly named huggingface-cli). Public
# repos are anonymous; private repos need `hf auth login` first.
#
# The model catalog (/var/lib/llama-models) is root-owned so every user on
# the box can read it. Writes therefore need root. If invoked as a normal
# user, this script re-execs itself under sudo, preserving the caller's
# environment (-E) and PATH so the caller's `hf` shim and HuggingFace cache
# are used rather than root's.

set -euo pipefail

# Re-exec under sudo if not already root, so writes into the root-owned
# catalog succeed. Preserve the environment and an explicit PATH (sudo
# resets PATH by default, which would hide a user-local `hf` shim).
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E env "PATH=$PATH" bash "${BASH_SOURCE[0]}" "$@"
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO/configs/workstation/models.toml"
SYSTEM_ENV="/etc/workstation/system.env"

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; exit 1; }

[[ -r "$MANIFEST" ]] || bad "$MANIFEST not found — copy from models.toml.example and edit"

# Resolve the catalog root from system.env, fall back to /var/lib/llama-models.
MODELS_DIR=""
if [[ -r "$SYSTEM_ENV" ]]; then
  MODELS_DIR=$(awk -F= '/^WS_MODELS_DIR=/{ sub(/^[^=]*=/, ""); gsub(/"/, ""); print; exit }' "$SYSTEM_ENV")
fi
MODELS_DIR="${MODELS_DIR:-/var/lib/llama-models}"
ok "models dir: $MODELS_DIR"

command -v hf >/dev/null 2>&1 || bad "hf not found — install with: uv tool install huggingface_hub (and ensure it is on PATH; sudo -E preserves the caller's PATH)"

# Extract the (id, gguf_filename, hf_repo, hf_file) tuples for every
# model the manifest references. Sidecars live under <role>.user_choice;
# primary pool members live under primary_pool.members[].
TUPLES=$(python3 - "$MANIFEST" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    m = tomllib.load(f)
out = []
for role in ("summarizer", "embeddings", "edit_prediction"):
    if role in m and "user_choice" in m[role]:
        c = m[role]["user_choice"]
        out.append((c["id"], c["gguf_filename"], c["huggingface_repo"], c["huggingface_file"]))
for member in m.get("primary_pool", {}).get("members", []):
    out.append((member["id"], member["gguf_filename"], member["huggingface_repo"], member["huggingface_file"]))
for t in out:
    print("|".join(t))
PY
)

[[ -n "$TUPLES" ]] || bad "manifest contained no models to download"

# Catalog stays root-owned (world-readable) so every user can read it.
# We are root here (the script re-execs under sudo above), so just create
# the dir if missing -- no chown, ownership stays root:root.
if [[ ! -d "$MODELS_DIR" ]]; then
  hdr "Create $MODELS_DIR"
  mkdir -p "$MODELS_DIR"
  ok "created $MODELS_DIR (owner root)"
fi

while IFS='|' read -r id gguf hf_repo hf_file; do
  [[ -z "$id" ]] && continue
  hdr "$id"
  target_dir="$MODELS_DIR/$id"
  target_file="$target_dir/$gguf"
  if [[ -s "$target_file" ]]; then
    ok "already present: $target_file ($(du -h "$target_file" | cut -f1))"
    continue
  fi
  mkdir -p "$target_dir"
  echo "  downloading $hf_repo/$hf_file -> $target_file"
  if ! hf download "$hf_repo" "$hf_file" --local-dir "$target_dir"; then
    bad "hf download failed for $hf_repo/$hf_file"
  fi
  # hf may write under a nested structure; normalize.
  if [[ ! -f "$target_file" ]]; then
    found=$(find "$target_dir" -type f -name "$gguf" -print -quit)
    if [[ -n "$found" && "$found" != "$target_file" ]]; then
      mv "$found" "$target_file"
    fi
  fi
  [[ -s "$target_file" ]] || bad "download did not produce $target_file"
  ok "saved $target_file ($(du -h "$target_file" | cut -f1))"
done <<< "$TUPLES"

hdr "Done"
echo "  catalog: $MODELS_DIR"
du -sh "$MODELS_DIR"/*/ 2>/dev/null | head
