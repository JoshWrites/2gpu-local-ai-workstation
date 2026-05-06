# Third-Party Components and Licenses

The umbrella repo's own code (scripts, systemd units, opencode
patches, configs, docs) is MIT-licensed; see [LICENSE](LICENSE) for
the full text.

The full *running stack* combines this repo with several upstream
projects and a set of model weights, each with its own license. This
file lists the components a working install pulls in and their
licenses, so downstream users know what they can do with the whole.

If you redistribute, modify, or build commercially on this stack,
read each component's actual LICENSE file -- this list is a
navigation aid, not a substitute.

---

## Code components

| Component | Source | License | Notes |
|---|---|---|---|
| 2gpu-local-ai-workstation (this repo) | this repo | MIT | Includes scripts, systemd units, configs, docs. |
| opencode-zed-patches (this repo) | `opencode-zed-patches/` | MIT | Patches against opencode; could be submitted upstream. |
| Library MCP server | `Library/` (submodule) | TBD | Currently private; license to be confirmed when made public. |
| mnemory | external repo | TBD | Optional install; check the upstream repo's LICENSE. |
| opencode (patched build) | https://github.com/sst/opencode | MIT | We patch v1.14.28, ship the patches not the binary. |
| llama.cpp (Vulkan + HIP builds) | https://github.com/ggml-org/llama.cpp | MIT | Built from source; we ship the build instructions, not the binary. |
| Zed | https://zed.dev | GPL-3.0 (Zed Industries dual-license) | Editor; not redistributed by this repo. |
| ROCm | https://github.com/ROCm | MIT (per-component varies) | AMD GPU runtime; per-distro install. |
| bun | https://bun.sh | MIT | Required for the opencode build. |
| uv | https://astral.sh/uv | Apache 2.0 / MIT | Used by Library and mnemory. |
| huggingface_hub | https://github.com/huggingface/huggingface_hub | Apache 2.0 | Used by `download-models.sh`. |
| pandoc | https://pandoc.org | GPL-2.0+ | Used by Library for export. |
| docling | https://github.com/DS4SD/docling | MIT | Used by Library for binary-to-text conversion. |
| SearxNG | https://github.com/searxng/searxng | AGPL-3.0 | Used by Library for web search; user runs locally. |
| Qdrant | embedded in mnemory | Apache 2.0 | Vector store used by mnemory. |

## Model weights (default tested set)

Model licenses are typically more restrictive than code licenses
(non-commercial clauses, attribution requirements, etc.) -- read
each upstream model card before any production use.

| Model | License | Source |
|---|---|---|
| GLM-4.7-Flash | Apache 2.0 | https://huggingface.co/unsloth/GLM-4.7-Flash-GGUF |
| Qwen3-Coder-30B-A3B-Instruct | Apache 2.0 | https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF |
| Qwen3-Next-80B-A3B-Instruct | Apache 2.0 | https://huggingface.co/unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF |
| Qwen3-Next-80B-A3B-Thinking | Apache 2.0 | https://huggingface.co/unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF |
| Qwen3-4B-Instruct-2507 | Apache 2.0 | https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507-GGUF |
| multilingual-e5-large | MIT | https://huggingface.co/intfloat/multilingual-e5-large |
| Qwen2.5-Coder-3B-Instruct | Apache 2.0 | https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF |

If you swap models via `models.toml`, check the new model's license
yourself. Examples of license shapes you might run into when swapping
sidecars:

- **Apache 2.0 / MIT** — generally permissive for commercial use.
- **CC-BY-NC-4.0** — non-commercial only; e.g. `aya-expanse-8b`.
- **Llama license** — Meta-specific terms; read the model card.
- **Custom research-only** — frequent on small experimental GGUFs.

## Models in `docs/tested-models.md` not in the default set

Each entry in the alternatives tables lists the upstream license.
That doc is the authoritative per-model reference; this file lists
only the *installed* defaults.

---

## "Can I redistribute this whole stack?"

The stack is a *build-from-source* recipe, not a redistributable
binary. The umbrella's MIT license covers the recipe (scripts,
patches, docs); each component you build follows its own license
when you actually run it.

In particular:
- **You CANNOT ship pre-built model weights** without the upstream
  model's permission.
- **You CANNOT ship Zed** unless you comply with its license.
- **You CAN share the recipe and your own scripts** under MIT (or
  any compatible license) -- that's what this repo does.

For commercial deployments, audit each component's license against
your specific use case. The Apache 2.0 / MIT spine of the toolchain
is permissive, but several model licenses (notably non-Qwen
research models) are not.
