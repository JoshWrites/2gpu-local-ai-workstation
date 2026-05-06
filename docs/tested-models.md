# Tested Models

Per-role models that have been validated on the reference 7900 XTX +
5700 XT hardware. The `configs/workstation/models.toml.example` ships
with these as the defaults; copy it to `models.toml` and edit if you
want to use something else.

Each role is an *interchangeable slot*. Any model that satisfies the
role's `hard_contract` (described in `models.toml.example`) should
work, but only the entries in the tables below have been observed to
work on this hardware. If you swap to something untested, run the
regression suite (`bench/regression.sh`) afterwards and consider
contributing your results back.

---

## Summarizer (port 11435, secondary GPU)

Compresses Library research output. Latency budget ~5s. Hard
contract: must respond on `/v1/chat/completions` with INSTRUCT or
CHAT tuning, small enough to leave ~6 GB free for the other two
sidecars.

| Model | Quant | ctx | VRAM | Tok/s (gen) | Source | License |
|---|---|---:|---:|---:|---|---|
| Qwen3-4B-Instruct-2507 *(default)* | Q4_K_M | 32K | ~3.0 GB | ~140 | [Qwen/Qwen3-4B-Instruct-2507-GGUF](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507-GGUF) | Apache 2.0 |
| aya-expanse-8b | Q4_K_M | 8K | ~5.0 GB | ~85 | [bartowski/aya-expanse-8b-GGUF](https://huggingface.co/bartowski/aya-expanse-8b-GGUF) | CC BY-NC 4.0 |

Avoid: any base/completion model (uncontrolled output); models >8 GB
(squeezes the embeddings + coder sidecars off the card).

## Embeddings (port 11437, secondary GPU)

Embeddings for Library retrieval and mnemory's vector search. Hard
contract: dimension is baked into mnemory's qdrant collection at
first run. Changing this model later requires dropping
`$HOME/.mnemory/qdrant/` and updating `EMBED_DIMS` in
`/etc/workstation/mnemory.env`.

| Model | Quant | dim | VRAM | Source | License |
|---|---|---:|---:|---|---|
| multilingual-e5-large *(default)* | Q8_0 | 1024 | ~0.6 GB | [MahmoudFathy/multilingual-e5-large-Q8_0-GGUF](https://huggingface.co/MahmoudFathy/multilingual-e5-large-Q8_0-GGUF) | MIT |
| mxbai-embed-large-v1 | Q8_0 | 1024 | ~0.7 GB | [mixedbread-ai/mxbai-embed-large-v1](https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1) | Apache 2.0 |

mxbai-embed-large-v1 is dim-compatible with multilingual-e5-large
(both 1024) -- swapping them does NOT require dropping the qdrant
collection. Any other embedding model probably has a different
dimension; check `EMBED_DIMS` carefully.

Avoid: OpenAI-default 1536-dim models -- mnemory currently assumes
1024. Future revisions may make this configurable end-to-end.

## Edit prediction (port 11438, secondary GPU)

Inline edit predictions for Zed. Single sub-100ms latency budget on
the stack. Hard contract: code-tuned, Q4 strongly preferred over Q8.

| Model | Quant | ctx | VRAM | Latency p50 | Source | License |
|---|---|---:|---:|---:|---|---|
| Qwen2.5-Coder-3B-Instruct *(default)* | Q4_K_M | 4K | ~2.0 GB | ~60 ms | [Qwen/Qwen2.5-Coder-3B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF) | Apache 2.0 |
| Qwen2.5-Coder-1.5B-Instruct | Q4_K_M | 4K | ~1.0 GB | ~35 ms | [Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF) | Apache 2.0 |
| Qwen2.5-Coder-7B-Instruct | Q4_K_M | 4K | ~4.5 GB | ~110 ms | [Qwen/Qwen2.5-Coder-7B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF) | Apache 2.0 |

7B exceeds the latency budget at p50 on the 5700 XT but is documented
here for users with a faster secondary card. 1.5B is the right
choice if you want to free VRAM for a larger summarizer.

Avoid: general-purpose chat models; they produce poor FIM completions.

## Primary pool (port 11434, primary GPU, swappable)

Multiple members; one loaded at a time. Hard contract: chat/instruct
tuning, tool-call support if driving the agent loop, MoE-offload
friendly if larger than 24 GB. Per-model launch flags live in
`configs/workstation/llama-router.ini`, not in `models.toml` (see
that file's comments for why -- get one of these flags wrong and you
OOM, leak `<think>` tags, or stall on unbounded deliberation).

### Default pool (24 GB GPU + 64 GB RAM)

| Model | Quant | ctx | VRAM | DRAM (MoE offload) | Tok/s (gen) | Source | License |
|---|---|---:|---:|---:|---:|---|---|
| GLM-4.7-Flash | UD-Q4_K_XL | 64K | ~10 GB | -- | ~70 | [unsloth/GLM-4.7-Flash-GGUF](https://huggingface.co/unsloth/GLM-4.7-Flash-GGUF) | Apache 2.0 |
| Qwen3-Coder-30B-A3B-Instruct | Q4_K_M | 64K | ~17 GB | -- | ~90 | [unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF) | Apache 2.0 |
| Qwen3-Next-80B-A3B-Instruct | UD-Q4_K_XL | 96K | ~19 GB | ~25 GB | ~30 | [unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF](https://huggingface.co/unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF) | Apache 2.0 |
| Qwen3-Next-80B-A3B-Thinking *(default for hard)* | UD-Q4_K_XL | 96K | ~19 GB | ~25 GB | ~30 | [unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF](https://huggingface.co/unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF) | Apache 2.0 |

### Validated alternatives (kept for restoration)

- **GPT-OSS-120B Q4_0** — formerly in the default pool, dropped
  2026-05-05 after benchmarks showed Qwen3-Next-Thinking matched or
  beat it on every measured axis at lower memory cost. Weights still
  on disk for restoration; see Phase 11-12 of the build history doc
  for the bench data.

### Smaller-GPU pool suggestions (untested)

If your primary card is 16 GB instead of 24 GB, drop the
Qwen3-Next-80B pair and consider:

- GLM-4.7-Flash @ Q3_K_M (~7 GB)
- Qwen3-Coder-30B-A3B-Instruct @ Q3_K_M (~13 GB)
- Mistral-Small-3.1-24B Q4_K_M (~14 GB)

These have not been benchmarked on this stack. If you try them,
contribute results.

---

## How to add a model

1. Find a GGUF on HuggingFace; verify license matches your needs.
2. Add an entry under the appropriate role in `models.toml` (see the
   comments in `models.toml.example` for shape).
3. For sidecars: run `scripts/download-models.sh` then
   `scripts/install-systemd-units.sh` then
   `sudo systemctl restart llama-<role>.service`.
4. For primary pool: also add a `[model.<id>]` section in
   `configs/workstation/llama-router.ini` with the per-model flags.
   See the existing sections in router.ini for the conventions.
5. After it works, document VRAM usage and tok/s here.

## How to read this doc safely

VRAM and tok/s numbers are hardware-specific (RX 7900 XTX for the
primary, RX 5700 XT for the sidecars, AMD Vulkan path or HIP path as
documented). On a different GPU these numbers are estimates only.
Latency and throughput on Vulkan vary 20-40% between consumer RDNA
generations even at the same VRAM tier.
