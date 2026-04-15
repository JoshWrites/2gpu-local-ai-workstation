# Community Review: Private Local Agentic Coding (April 2026)

Scope: sanity-check the `second-opinion` stack (llama.cpp + Qwen3-Coder-30B-A3B on RX 7900 XTX / ROCm 7.2, VSCodium + Roo Code, Qdrant codebase indexing planned on a 5700 XT) against what the broader community is running in early 2026.

## Executive summary

1. **You are on the mainstream path.** llama.cpp + Qwen3-Coder-30B-A3B + Roo Code in VS Code/VSCodium is effectively the default recipe for private local agentic coding in early 2026. No exotic choices to unwind.
2. **ROCm 7.2 on gfx1100 is the single biggest smell.** Multiple open issues show ROCm 7.x regressions vs Vulkan on the 7900 XTX — Vulkan is now equal-or-faster on RDNA3 for most llama.cpp workloads, *especially MoE*, and is dramatically easier to set up. Benchmark your stack against `-DGGML_VULKAN=ON` before assuming ROCm is the right backend.
3. **rocWMMA on ROCm 7.2 is a known regression on gfx1100.** If you're building llama.cpp with `-DGGML_HIP_ROCWMMA_FATTN=ON` (or similar), turn it off and retest; community benches show it's neutral-to-harmful on ROCm 7.2.1/gfx1100.
4. **The 5700 XT (gfx1010) as an embedding server is the second smell.** gfx1010 has effectively no first-party ROCm math-library support in 2026; `HSA_OVERRIDE_GFX_VERSION=10.3.0` no longer works post-torch-2.0. Plan on Vulkan backend for that card, or consider running embeddings on CPU or on the 7900 XTX instead.
5. **Roo's built-in codebase indexing is genuinely the consensus choice** for the Roo/Cline/Kilo lineage — Qdrant + Ollama-served embeddings is the documented, working pattern. You're not off-pattern here.
6. **Your draft-model choice (Qwen3-0.6B) is fine but dated.** The 2026 state of the art for Qwen3-Coder-30B speculative decoding is jukofyork's `Qwen3-Coder-Instruct-DRAFT-0.75B` (GGUF, purpose-built) or EAGLE3 heads (SGLang/vLLM only, not llama.cpp). Swap the draft; keep the technique.
7. **Context: stay at 32K–64K.** Community guidance and Qwen's own docs say YaRN below 32K *hurts* quality; above ~131K is unvalidated. Everyone running 256K+ on a 30B-A3B is doing it for bragging rights, not quality.
8. **Prompt-injection defense is an unsolved community problem.** There is no standard guardrail pattern worth adopting wholesale; the realistic posture is least-privilege tool sandboxing + auto-approve discipline, not a magic judge model.

## Mainstream-path check

| Dimension | Your choice | Community mainstream? |
|---|---|---|
| Inference server | llama.cpp (llama-server) | Yes — the default for BYO-stack |
| Model | Qwen3-Coder-30B-A3B | Yes — the default 24 GB coder |
| Editor/agent | VSCodium + Roo Code | Yes — Roo is the local-first pick |
| Vector DB | Qdrant | Yes — Roo's first-class option |
| GPU vendor | AMD RDNA3 | Minority but well-represented |
| Backend | ROCm 7.2 | **Drifting off-mainstream; Vulkan preferred on RDNA3 in 2026** |
| Lifecycle | systemd user units | Common among Linux self-hosters |
| Draft model | Qwen3-0.6B | Workable; better options now exist |

Direction of weirdness: *hardware backend and secondary-GPU choice*, not software stack.

## Per-topic findings

### 1. Popular stacks, early 2026

The Cline → Roo Code → Kilo Code fork lineage dominates IDE-based agentic coding; OpenCode and Aider own the terminal; Continue.dev is the JetBrains default ([wetheflywheel 2026 comparison](https://wetheflywheel.com/en/guides/open-source-ai-coding-agents-2026/)). Inference is llama.cpp, LM Studio, or Ollama; for serious users llama.cpp direct is the production answer ([ServiceStack 2026 guide](https://servicestack.net/posts/hosting-llama-server)). Models cluster around Qwen3-Coder-30B-A3B (24 GB tier), GLM-4.6 / GLM-4.7-Flash (fast interactive), and Qwen3-Coder-480B / DeepSeek-V3.x derivatives for people with enough VRAM. You're on the median path.

### 2. AMD/ROCm peculiarities

- **ROCm 7.x vs Vulkan on gfx1100:** Open issue [llama.cpp #20934](https://github.com/ggml-org/llama.cpp/issues/20934) documents significantly lower token generation under ROCm than Vulkan on the 7900 XTX; [Phoronix's ROCm 7.1 vs RADV comparison](https://www.phoronix.com/review/rocm-71-llama-cpp-vulkan) confirms Vulkan leads on prompt processing and token gen for MoE models. Multiple users report "50% faster on Vulkan after Fedora 42" ([llm-tracker AMD guide](https://llm-tracker.info/howto/AMD-GPUs)).
- **rocWMMA regression:** Community bench on ROCm 7.2.1 / gfx1100 shows WMMA neutral at best, regression at worst ([llama.cpp discussion #15021](https://github.com/ggml-org/llama.cpp/discussions/15021)).
- **Idle GPU at 100%:** Known HIP-backend bug where the graphics pipeline pegs at 100% with a loaded model ([ROCm #2777](https://github.com/ROCm/ROCm/issues/2777), still open for RDNA4 in [#5706](https://github.com/ROCm/ROCm/issues/5706)). Power/thermal impact — relevant for a long-lived systemd unit.
- **Multi-GPU PCIe symmetry:** Both GPUs must be on CPU lanes, never chipset lanes, or tensor parallelism fails ([llama.cpp #15021](https://github.com/ggml-org/llama.cpp/discussions/15021)). Worth confirming on levine-positron before wiring in the 5700 XT.
- **gfx1010 (5700 XT):** No official ROCm math-library support; `HSA_OVERRIDE_GFX_VERSION=10.3.0` does not help post-torch 2.0 and segfaults on RDNA1 ([pytorch #106728](https://github.com/pytorch/pytorch/issues/106728), [ollama #2503](https://github.com/ollama/ollama/issues/2503)). llama.cpp Vulkan works reliably on gfx1010; ROCm is build-from-source and fragile.

### 3. Qwen3-Coder-30B-A3B community feedback

Reputation: strong sustained-reasoning model, better than GLM-4.6 on long-context refactors, worse on interactive speed ([Novita comparison](https://blogs.novita.ai/should-you-choose-glm-4-6-for-fast-coding-or-qwen3-coder-for-large-repos/)). Widely regarded as the best local coder at the ~24 GB tier. For 7900 XTX, community-reported throughput is in the 30–45 tok/s range on Q4/Q5 quants; one user specifically reports "30 t/s with Qwen3-Coder-Next on 7900 XTX" ([llama.cpp #20013](https://github.com/ggml-org/llama.cpp/discussions/20013)). Alternatives:
- **Qwen3-Coder-480B-A35B** — better quality, needs 200+ GB; not applicable to your hardware.
- **GLM-4.6 / GLM-4.7-Flash** — faster, more interactive, weaker at large-repo reasoning.
- **DeepSeek V4 / Gemma-4 coder variants** — not yet displacing Qwen3-Coder-30B in r/LocalLLaMA consensus as of April 2026.

### 4. Roo Code vs alternatives

Roo is still the local-first consensus in VS Code. Cline has more users total (5M+ installs) but less offline polish; Kilo Code has momentum ($8M seed, orchestrator mode, inline autocomplete) and many heavy users are drifting toward it ([ai505 comparison](https://ai505.com/kilo-code-vs-roo-code-vs-cline-the-2026-ai-coding-battle-nobody-saw-coming/), [morphllm Roo vs Cline](https://www.morphllm.com/comparisons/roo-code-vs-cline)). Roo's model-per-mode routing is the feature that keeps offline users loyal; if you want an orchestrator/sub-agent pattern natively, Kilo is the one to watch. Aider remains the terminal choice; Continue.dev has gone relatively quiet.

### 5. Embeddings + semantic retrieval

Qdrant is the default for Roo/Kilo users — it's the first-party option in Roo's docs ([Roo codebase indexing docs](https://docs.roocode.com/features/codebase-indexing)). Chroma and Weaviate see almost no mention in the Roo community. Embedding model picks in 2026:
- **Qwen3-Embedding 0.6B/4B/8B** — MTEB leader, programming-language-aware, fits a 5700 XT comfortably at 0.6B/4B ([Qwen3-Embedding](https://github.com/QwenLM/Qwen3-Embedding)).
- **Voyage code-3, Gemini Embedding 2** — higher MTEB-Code but cloud-only. Not relevant if privacy is the point.
- **Nomic Embed v2 / Jina Code v2** — still common; fine but generally behind Qwen3-Embedding on code.

Roo's built-in indexing is considered useful and "good enough" by most; few users wrap a bespoke RAG pipeline unless they need multi-repo search. Known failure mode: Qdrant connection errors and Ollama model-name mismatches ([Roo #4092](https://github.com/RooCodeInc/Roo-Code/issues/4092), [#10863](https://github.com/RooCodeInc/Roo-Code/issues/10863)).

**Recommendation:** Qwen3-Embedding-0.6B or 4B on the 5700 XT via llama.cpp Vulkan. Skip ROCm on gfx1010.

### 6. Context sizes in practice

Qwen3-Coder-30B-A3B is native 256K, YaRN-extendable to 1M, but:
- Qwen's own guidance: don't enable YaRN below 32K — it *degrades* quality ([HF model card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct)).
- Validation only goes to ~131K; above that is untested marketing surface.
- Practical r/LocalLLaMA reports: 32K is universally fine; 64K works with YaRN and noticeable KV-cache pressure; 128K+ shows quality drift and VRAM pain on 24 GB cards.

**Recommendation:** default `--ctx-size 32768` with YaRN off, offer a 64K mode with YaRN on for repo-wide tasks. Don't chase 128K+ on 24 GB.

### 7. Speculative decoding

Worth it — especially for code. Measured 4x speedup on high-draftability refactor prompts (RTX 5000 Ada, Qwen2.5-Coder-Q6 drafted by 0.6B-Q4), ~2x on Apple Silicon, only 1.0–1.3x on chat-style prompts ([llama.cpp #10466](https://github.com/ggml-org/llama.cpp/discussions/10466)). Current-best draft model for your target: **jukofyork/Qwen3-Coder-Instruct-DRAFT-0.75B-GGUF** ([HF link](https://huggingface.co/jukofyork/Qwen3-Coder-Instruct-DRAFT-0.75B-GGUF)), which was trained specifically to match Qwen3-Coder's distribution — a raw Qwen3-0.6B base is usable but its draft-acceptance rate is lower. EAGLE3 heads exist for Qwen3-Coder-30B-A3B ([SpecForge on HF](https://huggingface.co/lmsys/SGLang-EAGLE3-Qwen3-Coder-30B-A3B-Instruct-SpecForge)) but require SGLang/vLLM — not llama.cpp. Stick with the dedicated DRAFT GGUF.

### 8. Prompt-injection / agentic safety

No silver bullet exists. Recent academic work shows >85% attack success rates against state-of-the-art defenses when attackers adapt ([arxiv 2601.17548](https://arxiv.org/html/2601.17548v1)). Judge-model guardrails share the base model's vulnerabilities ([HiddenLayer](https://www.hiddenlayer.com/research/same-model-different-hat)). The community-consensus posture is **defense-in-depth, not a plugin**:
- Tool-level least privilege (don't give the agent shell unless it needs it; whitelist commands).
- No auto-approval for write/exec tools in untrusted repos.
- Run agents in a sandbox (container, firejail, or a dedicated user) — becoming standard advice after the December 2025 "30+ flaws in AI coding tools" disclosure ([The Hacker News](https://thehackernews.com/2025/12/researchers-uncover-30-flaws-in-ai.html)).
- Treat repo docs (README, CONTRIBUTING, issue bodies) as untrusted input.

Nothing to adopt wholesale. Worth writing an explicit threat-model note into your repo.

### 9. Lifecycle management

Long-lived llama-server behind a systemd user unit is the standard pattern among serious self-hosters ([DAWN project](https://github.com/The-OASIS-Project/dawn/blob/main/services/llama-server/README.md), [ServiceStack](https://servicestack.net/posts/hosting-llama-server)). Docker Compose is the other common answer for people who want reproducibility over simplicity. On-demand launch is rare outside of laptops. Your systemd-user-unit choice is mainstream. One known gotcha: llama-server as a systemd unit may require explicit `HF_HOME` / cache env vars ([llama.cpp #20952](https://github.com/ggml-org/llama.cpp/issues/20952)) — worth checking if your unit inherits a sane environment.

### 10. Things you may not have planned for

- **Idle-GPU power draw bug** on the 7900 XTX HIP backend (pegs at ~100% pipeline after a model loads). Consider `Restart=on-failure` plus `ExecStop` that fully unloads, or run on Vulkan.
- **KV-cache quantization** (`--cache-type-k q8_0 --cache-type-v q8_0`) — halves VRAM for the cache with small quality impact; standard practice on 24 GB cards.
- **rocWMMA off** for your build.
- **MCP server security.** If you add MCP servers (git, filesystem, shell), each one is a potential injection path — audit them.
- **Observability.** Almost no one has good telemetry on their local agent. `llama-server`'s Prometheus endpoint + basic request logs will put you ahead.
- **Repo-doc sanitization** before feeding to codebase indexing. Indexed prompt-injection payloads will hit the agent at `codebase_search` time.
- **Backup of your Qdrant collection.** Re-indexing a large monorepo is slow; snapshot it.

## Actionable recommendations

**Do before Phase 2:**
1. Benchmark Vulkan vs ROCm on your exact 7900 XTX / Qwen3-Coder-30B setup. If Vulkan is within 10% or better, switch. This likely also fixes the idle-GPU bug.
2. Rebuild llama.cpp with rocWMMA disabled (if currently on) and re-bench.
3. Switch draft model to `jukofyork/Qwen3-Coder-Instruct-DRAFT-0.75B-GGUF`.
4. Default context to 32K; expose a 64K "big-repo" mode with YaRN.
5. Decide: 5700 XT on Vulkan-only, or drop it and run Qwen3-Embedding-0.6B on the 7900 XTX alongside the coder. The latter is probably simpler and gives you back a PCIe slot.

**Research next:**
- Kilo Code's orchestrator mode against Roo's mode-routing — if you hit ceiling on Roo, Kilo is the obvious upgrade.
- EAGLE3 via SGLang as a Phase 4 track (requires leaving llama.cpp, but 2–3x speedups are real).
- Ingress sandboxing (firejail or systemd `ProtectHome=`/`ReadOnlyPaths=` for the agent's shell tool).

**Leave alone:**
- Editor choice (VSCodium + Roo) — mainstream, well-supported.
- Qdrant — mainstream, well-supported.
- Systemd user units — mainstream lifecycle pattern.
- Qwen3-Coder-30B-A3B as the primary coder — still the best 24 GB option in April 2026.

## Links

- [llama.cpp ROCm performance discussion #15021](https://github.com/ggml-org/llama.cpp/discussions/15021) — rocWMMA and gfx1100 notes, 2026
- [llama.cpp #20934 ROCm slower than Vulkan on 7900 XTX](https://github.com/ggml-org/llama.cpp/issues/20934) — 2026
- [Phoronix: ROCm 7.1 vs RADV Vulkan on llama.cpp](https://www.phoronix.com/review/rocm-71-llama-cpp-vulkan) — 2026
- [ROCm #2777 idle GPU at 100% on 7900 XTX](https://github.com/ROCm/ROCm/issues/2777)
- [llm-tracker AMD GPU guide](https://llm-tracker.info/howto/AMD-GPUs)
- [llama.cpp speculative decoding discussion #10466](https://github.com/ggml-org/llama.cpp/discussions/10466)
- [jukofyork/Qwen3-Coder-Instruct-DRAFT-0.75B-GGUF](https://huggingface.co/jukofyork/Qwen3-Coder-Instruct-DRAFT-0.75B-GGUF)
- [SpecForge EAGLE3 for Qwen3-Coder-30B-A3B](https://huggingface.co/lmsys/SGLang-EAGLE3-Qwen3-Coder-30B-A3B-Instruct-SpecForge)
- [Qwen3-Coder-30B-A3B HF model card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct) — YaRN / context guidance
- [Qwen3-Embedding](https://github.com/QwenLM/Qwen3-Embedding)
- [Roo Code Codebase Indexing docs](https://docs.roocode.com/features/codebase-indexing)
- [Roo Code #4092 Qdrant connection issues](https://github.com/RooCodeInc/Roo-Code/issues/4092)
- [Roo vs Cline vs Kilo — ai505](https://ai505.com/kilo-code-vs-roo-code-vs-cline-the-2026-ai-coding-battle-nobody-saw-coven-coming/)
- [Open-source AI coding agents 2026 — wetheflywheel](https://wetheflywheel.com/en/guides/open-source-ai-coding-agents-2026/)
- [Prompt injection on agentic coding assistants (arxiv 2601.17548)](https://arxiv.org/html/2601.17548v1) — 2026
- [The Hacker News: 30+ flaws in AI coding tools, Dec 2025](https://thehackernews.com/2025/12/researchers-uncover-30-flaws-in-ai.html)
- [GLM-4.6 vs Qwen3-Coder — Novita](https://blogs.novita.ai/should-you-choose-glm-4-6-for-fast-coding-or-qwen3-coder-for-large-repos/)
- [ServiceStack: self-host llama.cpp in production](https://servicestack.net/posts/hosting-llama-server)
- [pytorch #106728 RDNA1 HSA_OVERRIDE broken post-2.0](https://github.com/pytorch/pytorch/issues/106728)
