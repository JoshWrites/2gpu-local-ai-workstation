# Shared paths for second-opinion launchers and bench scripts.
# Source (don't exec) from any script that needs to locate the model
# or the llama.cpp binary.

: "${LLAMA_BIN:=$HOME/src/llama.cpp/llama-b8799/llama-server}"
: "${MODEL_DIR:=$HOME/models/qwen3-coder-30b-a3b}"
: "${MODEL_GGUF:=$MODEL_DIR/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf}"

export LLAMA_BIN MODEL_DIR MODEL_GGUF
