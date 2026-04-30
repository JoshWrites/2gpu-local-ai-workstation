#!/usr/bin/env bash
# Download mxbai-embed-large-v1 Q8_0 GGUF to /home/levine/models/mxbai-embed-large/.
# Idempotent — skips download if the file already exists and passes a minimal sanity check.
#
# Source: ChristianAzinn/mxbai-embed-large-v1-gguf on Hugging Face.
# Q8_0 is recommended over smaller quants for embedding models (quant quality matters
# more than for large LLMs; Q8 stays near f16 quality at ~2x smaller).

set -euo pipefail

DEST_DIR="/home/levine/models/mxbai-embed-large"
FILE_NAME="mxbai-embed-large-v1.Q8_0.gguf"
DEST_PATH="${DEST_DIR}/${FILE_NAME}"
URL="https://huggingface.co/ChristianAzinn/mxbai-embed-large-v1-gguf/resolve/main/mxbai-embed-large-v1.Q8_0.gguf?download=true"

mkdir -p "$DEST_DIR"

if [[ -f "$DEST_PATH" ]]; then
  size=$(stat -c %s "$DEST_PATH")
  # Q8 quant of a 335M-param model should be ~340 MB; bail if clearly truncated.
  if (( size < 300000000 )); then
    echo "Existing file looks truncated (${size} bytes); re-downloading."
    rm -f "$DEST_PATH"
  else
    echo "Already present: $DEST_PATH (${size} bytes). Skipping."
    exit 0
  fi
fi

echo "Downloading mxbai-embed-large-v1.Q8_0.gguf (~340 MB)..."
curl -L --fail --progress-bar -o "$DEST_PATH" "$URL"

size=$(stat -c %s "$DEST_PATH")
echo ""
echo "Downloaded: $DEST_PATH"
echo "Size: ${size} bytes"

if (( size < 300000000 )); then
  echo "ERROR: downloaded file looks truncated. Aborting." >&2
  exit 1
fi

echo "Done."
