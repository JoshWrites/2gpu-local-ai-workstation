# Multi-Model Handoff and Dispatcher Prior Art

**Date:** 2026-04-24
**Scope:** Research on prior art for a three-part architecture in which (a) primary models with distinct skills swap on/off a large GPU, (b) a small always-resident coordinator on a secondary GPU orchestrates handoffs, and (c) primaries can self-report when they're out of their depth and request a swap.

This is a literature and field survey, not a design document. Where a claim is an inference rather than a citation, it is labelled `[inference]`.

---

## 1. Router / Dispatcher Architectures

### RouteLLM (Ong et al., 2024)
RouteLLM is the closest large-scale academic study of pre-call routing. The authors train binary or multi-class routers (similarity-weighted ranking, matrix factorisation, BERT classifier, causal LLM classifier) using human pairwise preferences from Chatbot Arena, and route each query to either a strong model (GPT-4) or a weak one (Mixtral-8x7B). The router never observes the strong model's output during the decision -- it is **purely pre-call routing**.

Reported numbers (MT-Bench, MMLU, GSM8K):
- 95% of GPT-4 quality at ~26% GPT-4 calls on MT-Bench -> ~85% cost reduction vs. always-GPT-4.
- 95% of GPT-4 quality at ~54% GPT-4 calls on MMLU -> ~14% cheaper than random.
- Routers trained for one (strong, weak) pair generalise to other pairs without retraining.

Sources:
- arXiv 2406.18665 -- https://arxiv.org/abs/2406.18665
- LMSYS blog -- https://www.lmsys.org/blog/2024-07-01-routellm/
- Code -- https://github.com/lm-sys/RouteLLM

### HybridLLM (Ding et al., ICLR 2024)
A BERT-style query difficulty classifier routes to a small edge model or a large cloud model. A continuous quality-knob parameter lets operators trade quality for cost at test time. Up to ~40% fewer large-model calls with no measurable drop in response quality.

Sources:
- arXiv 2404.14618 -- https://arxiv.org/abs/2404.14618
- ICLR 2024 -- https://openreview.net/forum?id=02f3mUtqnM

### Cascade Routing (Dekoninck et al., ETH Zurich, 2024)
A unified theoretical framework that proves cascading and routing are special cases of one Bayesian decision problem; provides the optimal stopping rule when both routing-then-cascade and cascade-then-route are allowed. On RouterBench the unified approach Pareto-dominates pure routing and pure cascading across the entire cost-quality frontier.

Sources:
- arXiv 2410.10347 -- https://arxiv.org/abs/2410.10347
- Code -- https://github.com/eth-sri/cascade-routing

### LLM-Blender (Jiang, Ren, Lin, ACL 2023)
Not a router -- an ensembler. PairRanker scores all candidate outputs from N models pairwise; GenFuser synthesises a final answer from the top-K. Pays the cost of running every model on every query.

Sources:
- arXiv 2306.02561 -- https://arxiv.org/abs/2306.02561
- Code -- https://github.com/yuchenlin/LLM-Blender

### Pre-call vs. mid-call distinction
All systems above are **pre-call** for routers and **post-attempt** for cascades. None perform a true mid-generation handoff in which the primary is interrupted, state is captured, and a different model continues the same response. That pattern is essentially absent from peer-reviewed work -- the closest the literature gets is speculative decoding (Section 5) and CALM/early-exit (Section 6), both of which switch *layers within one model* rather than between models.

---

## 2. Model Cascades and Deferral

### FrugalGPT (Chen, Zaharia, Zou, 2023)
The seminal cascade paper. A query goes through a chain of progressively more expensive LLMs. After each model answers, a separately trained DistilBERT scoring head rates the response; if the score exceeds a threshold the cascade halts. Reported: 98% cost reduction matching GPT-4 on HEADLINES and OVERRULING; +4% accuracy at equal cost on AGNEWS.

Critical detail: the "I can't do this" signal is **externally judged by a separate scorer, not self-reported by the model**. The authors tried verbalised confidence and found it noisy enough to require a learned external scorer.

Source: arXiv 2305.05176 -- https://arxiv.org/abs/2305.05176

### AutoMix (Aggarwal, Madaan et al., NeurIPS 2024)
AutoMix uses few-shot self-verification: the small model is prompted "is the above answer correct?" and the yes/no logit is treated as a noisy confidence. Because verification is unreliable, a POMDP-based meta-router decides whether to trust the small model's answer, escalate to a medium model for verification, or escalate to a large model. Across five datasets and five models, AutoMix-POMDP "yields positive gains across all configurations" with >50% cost reduction at parity.

This is the closest published instance of a model self-assessing then escalating. The paper concedes self-verification is too noisy to act on directly -- a meta-policy on top of the verification signal is required.

Sources:
- arXiv 2310.12963 -- https://arxiv.org/abs/2310.12963
- NeurIPS PDF -- https://proceedings.neurips.cc/paper_files/paper/2024/file/ecda225cb187b40ea8edc1f46b03ffda-Paper-Conference.pdf
- Code -- https://github.com/automix-llm/automix

### Gatekeeper (2025) and "Revisiting Cascaded Ensembles" (2024)
Gatekeeper trains a confidence-tuning head that outperforms raw verbalised confidence. "Revisiting Cascaded Ensembles" shows simple top-K ensembling beats single-stage cascades when the small model's calibration is weak -- i.e., **if your small model can't reliably say "I don't know," you're better off ignoring it and just running the big model**.

Sources:
- Gatekeeper -- https://arxiv.org/html/2502.19335
- Revisiting Cascaded Ensembles -- https://arxiv.org/html/2407.02348v2

### Takeaway for the user's pattern
Every credible cascade paper found that **self-reported confidence alone is insufficient** and added either a separately trained scorer or a POMDP meta-policy. Cost reductions of 50-98% are achievable, but only when the deferral signal is treated as noisy and filtered through an external mechanism.

---

## 3. Mixture-of-Agents and Orchestration Frameworks

### Mixture-of-Agents (Wang et al., Together AI, 2024)
Layered architecture: N agents per layer, each agent in layer k+1 sees all outputs from layer k. 65.1% AlpacaEval 2.0 LC win rate using only open-source models, beating GPT-4-Omni's 57.5%. Cost is several-x of single-model inference.

Source: arXiv 2406.04692 -- https://arxiv.org/abs/2406.04692

### Rethinking MoA / Self-MoA (Li et al., 2025)
A serious challenge to MoA. Mixing different LLMs often lowers ensemble quality. Self-MoA -- multiple samples from the single best model -- beats MoA by 6.6% on AlpacaEval 2.0 and 3.8% averaged across MMLU/CRUX/MATH. Heterogeneous primaries are not automatically better.

Sources:
- arXiv 2502.00674 -- https://arxiv.org/abs/2502.00674
- Code -- https://github.com/wenzhe-li/Self-MoA

### AutoGen (Microsoft, 2023)
General multi-agent conversation framework. Coordination is done by either round-robin/FSM logic in Python, or a "GroupChatManager" agent which is itself a full-size LLM. No built-in pattern for a small dedicated coordinator.

Sources:
- arXiv 2308.08155 -- https://arxiv.org/abs/2308.08155
- GitHub -- https://github.com/microsoft/autogen

### OpenAI Swarm and OpenAI Agents SDK
Swarm popularised "handoff" terminology. A handoff is implemented as a tool call -- when an agent invokes `transfer_to_<other_agent>`, the framework swaps the active system prompt and tool list but keeps the conversation history.

The handoff is initiated by the agent's tool call. The model **decides for itself** that it should hand off. This is the clearest mainstream implementation of "self-aware agent requests handoff" -- and it relies on the orchestrator being **the same powerful LLM**, not a small dedicated coordinator. The framework's logic is just `if tool_call.name.startswith("transfer_to_"): swap_agent()`.

Sources:
- Swarm repo -- https://github.com/openai/swarm
- OpenAI Cookbook -- https://cookbook.openai.com/examples/orchestrating_agents
- VentureBeat -- https://venturebeat.com/ai/openais-swarm-ai-agent-framework-routines-and-handoffs

### CrewAI vs. LangGraph
- CrewAI: role-driven crews with shared memory. Hierarchical mode uses a "manager LLM" -- typically a large model.
- LangGraph: explicit state-machine over typed channels. Routing decisions can be deterministic (Python edges) or LLM-driven (a "supervisor" node that is again a full LLM).

Neither framework ships a "small dedicated coordinator" pattern. In all common templates the orchestrator is itself a large model.

Sources:
- Arize -- https://arize.com/blog/orchestrator-worker-agents-a-practical-comparison-of-common-agent-frameworks/
- Particula -- https://particula.tech/blog/langgraph-vs-crewai-vs-openai-agents-sdk-2026

### MetaGPT (Hong et al., ICLR 2024)
Encodes Standardised Operating Procedures into role prompts. Coordination is document-driven -- agents read and write structured artifacts. No small-coordinator pattern.

Source: arXiv 2308.00352 -- https://arxiv.org/abs/2308.00352

### NVIDIA Orchestrator-8B (Nov 2025)
The most direct industrial precedent for a small dedicated coordinator. Orchestrator-8B is an RL-trained 8B controller that decides at each step whether to call a tool, dispatch to a larger model, or answer itself. ~30% the dollar cost and ~2.5x faster than GPT-5 on the same agent benchmarks while matching or beating accuracy. Note: Orchestrator-8B was trained specifically as an orchestrator; you cannot drop in a generic 8B model and expect this behaviour.

Sources:
- NVIDIA blog -- https://developer.nvidia.com/blog/train-small-orchestration-agents-to-solve-big-problems/
- MarkTechPost -- https://www.marktechpost.com/2025/11/28/nvidia-ai-releases-orchestrator-8b-a-reinforcement-learning-trained-controller-for-efficient-tool-and-model-selection/

### NVIDIA LLM Router Blueprint
Production router: Qwen-1.7B for intent classification or CLIP-embedding + small NN for auto-routing. Pre-call only.

Source: GitHub -- https://github.com/NVIDIA-AI-Blueprints/llm-router

---

## 4. Self-Aware / Metacognitive Handoff

This is the load-bearing assumption in the user's design and the area where the empirical evidence is bleakest.

### AbstentionBench (Meta FAIR, NeurIPS 2025)
The largest holistic study of LLM abstention. 20 datasets covering unknowable answers, underspecified questions, false premises, subjective items, and stale facts; 20 frontier LLMs evaluated.

Headline findings:
- "Abstention is an unsolved problem, and one where scaling models is of little use."
- **Reasoning fine-tuning degrades abstention by ~24% on average**, even on math/science domains the reasoning models were trained on. So o1/R1-style models are *worse* at knowing what they don't know than their non-reasoning siblings.
- Carefully crafted system prompts help in practice but do not fix the fundamental inability to reason about uncertainty.

This is the single most important result for the user's design. If the production reasoning model in your stack is *less* able to recognise its own competence boundary than a smaller non-reasoning model, then the "primary requests handoff" mechanism is operating against the gradient of capability.

Sources:
- arXiv 2506.09038 -- https://arxiv.org/abs/2506.09038
- Code -- https://github.com/facebookresearch/AbstentionBench

### Verbalised Confidence (Xiong et al., ICLR 2024)
Empirical evaluation of "tell me your confidence as a number" prompting. Findings:
- LLMs are systematically overconfident when verbalising.
- Calibration improves with model scale but doesn't reach reliability.
- White-box (logit-based) methods only marginally beat verbalised methods (AUROC 0.522 -> 0.605).
- No tested method consistently outperforms others; all struggle on professional-knowledge tasks.

Source: arXiv 2306.13063 -- https://arxiv.org/abs/2306.13063

### Dunning-Kruger in LLMs (2026)
24,000 trials on Claude Haiku 4.5, Gemini 2.5 Pro/Flash, Kimi K2:
- Kimi K2: ECE 0.726, accuracy 23.3% -- **catastrophically overconfident**.
- Claude Haiku 4.5: ECE 0.122, accuracy 75.4% -- well-calibrated.
- The pattern matches human Dunning-Kruger: weaker models are more overconfident.

Implication: a weaker domain-expert primary may be the *least* likely to recognise it has hit its boundary.

Sources:
- arXiv 2603.09985 -- https://arxiv.org/html/2603.09985v1
- CMU Dietrich -- https://www.cmu.edu/dietrich/news/news-stories/2025/july/trent-cash-ai-overconfidence.html

### Know Your Limits survey (TACL 2025)
Survey of 100+ abstention papers. Two main signal families: intrinsic (self-reported, logit-based) -- cheap but noisy; extrinsic (separate verifier, ensemble disagreement) -- costlier but more reliable. The recommendation: combine families; nobody trusts intrinsic signals in isolation in production.

Sources:
- arXiv 2407.18418 -- https://arxiv.org/abs/2407.18418
- TACL -- https://aclanthology.org/2025.tacl-1.26.pdf

### Verdict for the user's pattern
The "self-aware primary requests handoff" pattern is **partially supported but with important caveats**. Models can produce a usable hint that they are out of their depth, but:
1. The hint is too noisy to act on directly without a meta-policy or external verifier.
2. The hint gets *worse* in modern reasoning-tuned models.
3. The hint quality varies by an order of magnitude across models, with weaker models being more overconfident.

A workable design treats the primary's handoff request as **one input among several** to the coordinator's decision, not a hard trigger.

---

## 5. Speculative Decoding and Relatives

### Speculative Decoding (Leviathan, Kalman, Matias, ICML 2023)
The mature two-model collaboration pattern. A small **draft model** proposes K tokens autoregressively; the large **target model** verifies them in a single parallel forward pass. Output distribution is identical to the target alone. 2-3x speedup on T5-XXL with no quality loss.

Mechanical analogy to the user's pattern: small model always-on, large model occasional. **But the roles are reversed** -- in spec decoding the small model does the speaking, the large model does the verifying. In the user's design, the small model coordinates and the large model speaks.

Sources:
- arXiv 2211.17192 -- https://arxiv.org/abs/2211.17192
- Google retrospective -- https://research.google/blog/looking-back-at-speculative-decoding/
- vLLM blog -- https://blog.vllm.ai/2024/10/17/spec-decode.html

### Big-Little Decoder (Kim et al., NeurIPS 2023)
BiLD makes the small/large split adaptive: the small model decodes autoregressively until its confidence drops below a threshold or for K steps, then the large model is invoked non-autoregressively to verify and correct. ~2x speedup. The decision to hand control is **driven by the small model's per-token confidence** -- the closest mechanical analog in the speedup literature to the user's "primary requests handoff" pattern, again with reversed roles.

Sources:
- arXiv 2302.07863 -- https://arxiv.org/abs/2302.07863
- Code -- https://github.com/kssteven418/BigLittleDecoder

### Tandem Transformers (Google DeepMind, ICML 2024)
A large model processes a block of tokens once, exposing its richer representations to a small autoregressive model. PaLM2-Bison + PaLM2-Gecko: 3.3% absolute next-token accuracy gain over standalone Gecko, 1.16x speedup vs. PaLM2-Otter at comparable downstream quality. Plus 1.14x more in SPEED framework.

Source: arXiv 2402.08644 -- https://arxiv.org/abs/2402.08644

### Acceptance rates in practice
- Theoretical 2-3x speedup at alpha >= 0.6, gamma >= 5.
- Real ShareGPT runs: ~1.5x with draft-model spec decode, up to 2.8x with prompt-lookup decoding on summarisation.
- "In practice the speedup was lower than expected" -- alpha typically 0.6-0.8.

Sources:
- vLLM docs -- https://docs.vllm.ai/en/latest/features/spec_decode/
- BentoML -- https://bentoml.com/llm/inference-optimization/speculative-decoding
- Snowflake Arctic -- https://www.snowflake.com/en/engineering-blog/fast-speculative-decoding-vllm-arctic/

### Takeaway
Spec decoding shows the always-resident-small + episodic-large pattern is mechanically real. But it's a *latency* optimisation operating at the token level, not a *capability* router operating at the task level. Spec decoding's "state" is just the KV-cache and a few tokens; a capability handoff has to transfer in-flight reasoning, possibly mid-tool-call.

---

## 6. Big-Little / Edge-Cloud Collaboration

### CALM -- Confident Adaptive Language Modeling (Schuster et al., NeurIPS 2022)
Per-token early exit from a transformer's depth: emit the prediction from layer L if the layer-L confidence exceeds a calibrated threshold; otherwise continue. ~3x speedup with bounded global quality degradation. Within a single model, this is the cleanest implementation of "do the cheap thing first, escalate if not confident."

Sources:
- arXiv 2207.07061 -- https://arxiv.org/abs/2207.07061
- Google blog -- https://research.google/blog/accelerating-text-generation-with-confident-adaptive-language-modeling-calm/

### Hybrid SLM + LLM for Edge-Cloud (EdgeFM workshop, ACM 2024)
Practical edge-cloud cascade: small model on phone classifies query difficulty; hard queries are offloaded to the cloud LLM. Decision made by a tiny classifier head, not the SLM itself. Significant token-cost reductions at <5% quality loss.

Source: ACM workshop -- https://dl.acm.org/doi/10.1145/3662006.3662067

### Survey: Collaborative Inference between Edge SLMs and Cloud LLMs (2025)
Three patterns: task-assignment (router), task-division (decompose-then-merge), and mixture (token-level interleaving). The survey notes that **most production systems use static task-assignment with a separately trained classifier** -- not dynamic mid-request handoff and not LLM-driven routing.

Source: arXiv 2507.16731 -- https://arxiv.org/html/2507.16731v1

### Verdict
Edge-cloud research is the closest published architectural cousin to the user's pattern, but: small model is typically a classifier (not a generator); decisions are pre-call (not mid-call); "handoff state" is just the prompt (nothing in-flight is preserved).

---

## 7. Homelab / Hobbyist Implementations

### llama-swap (mostlygeek)
The de facto local model orchestrator. A Go proxy that exposes one OpenAI-compatible endpoint and dynamically loads/unloads upstream llama.cpp / vLLM processes based on the `model` field. Supports concurrent models via a "swap matrix" DSL when VRAM allows.

What it doesn't do: routing decisions, confidence-based handoff, or in-flight state transfer. It is **purely an infrastructure layer**, exactly the substrate you would build the user's coordinator on top of.

Sources:
- GitHub -- https://github.com/mostlygeek/llama-swap
- KDnuggets -- https://www.kdnuggets.com/how-to-run-multiple-llms-locally-using-llama-swap-on-a-single-server
- Banandre on llama.cpp router mode -- https://www.banandre.com/blog/router-mode-in-llamacpp-a-game-changer-for-local-llm-deployment

### llama.cpp router mode
Recently-added `--model-dir` flag: start `llama-server` once, it loads/unloads on demand from a directory of GGUFs. Native alternative to llama-swap; same semantic limitations.

Source: Level1Techs -- https://forum.level1techs.com/t/today-i-discovered-llama-cpp-router-mode/244060

### "Model Router" blog post (Hannecke, Medium)
A first-person account of running a small classifier model on Apple Silicon that sub-300-ms-classifies incoming requests and dispatches to one of several specialist 7-13B models. Works for that use case but **does not preserve in-flight state** -- every request is fresh.

Source: https://medium.com/@michael.hannecke/the-model-router-running-a-team-of-local-llms-instead-of-one-big-one-fd75eeec9d39

### Aider's Architect/Editor mode
The most widely deployed two-model production handoff in the local LLM world. The "architect" model produces a high-level plan; the "editor" model translates that plan into concrete edits. GPT-4o + DeepSeek-Coder as editor beats GPT-4o solo on the Aider benchmark. Handoff is **deterministic and pre-defined** (always architect -> editor), not dynamic.

Sources:
- Aider docs -- https://aider.chat/docs/usage/modes.html
- Aider blog -- https://aider.chat/2024/09/26/architect.html

### Cursor 2.0 Composer
Up to 8 model agents on the same problem, pick the best result. Composer is Cursor's in-house model. Ensemble, not handoff; routing logic closed-source.

Source: https://www.cometapi.com/cursor-2-0-what-changed-and-why-it-matters/

### r/LocalLLaMA / Hacker News patterns
The dominant DIY pattern is **client-driven model selection**: the user (or a harness like Continue / Roo / aider) picks the model per request, and llama-swap or `--model-dir` materialises it. There is no widely-discussed homelab implementation of (a) a small coordinator running on a separate GPU, (b) preserving state across model swaps, or (c) primaries requesting their own swap. The closest is the "small classifier dispatches to specialist" pattern in the Hannecke blog post.

`[inference]` -- Reddit and HN threads on dual-7900-XTX or 3090+3060 setups overwhelmingly discuss either tensor-parallel splitting of one big model across cards, or simply running two different models concurrently. The "small coordinator on the secondary card watching the primary's stream" pattern does not appear to have a public DIY exemplar as of 2026-04.

---

## 8. Failure Modes (cited)

### MAST: 14 failure modes (Cemri et al., NeurIPS 2025)
UC Berkeley study of 7 popular MAS frameworks (AutoGen, CrewAI, MetaGPT, AG2, ChatDev, etc.) across 200+ tasks with 1,600+ annotated traces. 14 failure modes in 3 categories:
1. **Specification & system design issues** -- agents disobey role specs, conversation reset, step repetition, unclear termination conditions.
2. **Inter-agent misalignment** -- conversation drift, task derailment, information hoarding, ignoring other agents' input.
3. **Task verification & termination** -- premature termination, no verification, weak verification, false positive on a wrong answer.

Cohen's kappa = 0.88. Headline finding: **"performance gains on popular benchmarks often remain minimal compared with single-agent frameworks"** -- adding agents doesn't reliably help and adds substantial new failure surfaces.

Sources:
- arXiv 2503.13657 -- https://arxiv.org/abs/2503.13657
- Code & dataset -- https://github.com/multi-agent-systems-failure-taxonomy/MAST

### Cascade error compounding
The most-cited failure mode in industry post-mortems: a small misread early in the chain ("10.5K units" -> "105K units") propagates through downstream agents that take it on trust.

Sources:
- Galileo -- https://galileo.ai/blog/multi-agent-llm-systems-fail
- Hakuna Matata -- https://www.hakunamatatatech.com/our-resources/blog/why-do-multi-agent-llm-systems-fail
- MarkTechPost -- https://www.marktechpost.com/2025/03/25/understanding-and-mitigating-failure-modes-in-llm-based-multi-agent-systems/

### Context loss across model handoffs
When a multi-model coding agent (e.g. JetBrains Junie CLI) switches from Claude to GPT-4 mid-task, **the new model inherits the conversation history but none of the implicit working state** -- patterns the previous model had inferred about the codebase, the working hypothesis, the things it had decided not to try. The author calls this "context evaporation."

Source: MemU -- https://memu.pro/blog/junie-cli-model-agnostic-coding-memory

### Mid-stream interruption is hard
"Can you really interrupt an LLM?" (Sara Zan, 2025) catalogues practical difficulties: tokens already in the streaming pipeline, partial tool calls, KV-cache invalidation, partial-JSON parser state. Conclusion: clean mid-generation interruption requires either explicit checkpoints in the protocol or a willingness to discard partial output and restart.

Source: https://www.zansara.dev/posts/2025-06-02-can-you-really-interrupt-an-llm/

### Self-MoA's negative result
Heterogeneous mixing degrades quality. If the coordinator dispatches to the wrong primary, you get a *worse* answer than always-using-the-best-single-primary. The user's pattern is structurally vulnerable to this.

Source: https://arxiv.org/abs/2502.00674

### Reasoning-model abstention regression
AbstentionBench shows reasoning fine-tuning degrades abstention by ~24%. If your most capable primary is a reasoning model, it is also your *least* trustworthy source of "I'm out of my depth" signals.

Source: https://arxiv.org/abs/2506.09038

---

## 9. Synthesis vs. the User's Pattern

### Closest published architectures
Ranked by structural similarity to the described system:

1. **NVIDIA Orchestrator-8B + tool/model dispatch** -- small dedicated coordinator routing across larger workers, RL-trained for the role. Closest match for the "small coordinator" axis. Lacks in-flight state handoff and self-requested swap.
2. **AutoMix (POMDP variant)** -- confidence-driven escalation between size tiers, with explicit meta-policy filtering noisy self-verification. Closest match for the "self-aware request" axis. Lacks GPU swapping.
3. **OpenAI Swarm / Agents SDK handoff pattern** -- agents request handoff via tool calls; framework swaps the active agent. Closest match for the "primary calls a swap" mechanic. Coordinator is an LLM but typically not a small dedicated one.
4. **llama-swap + a custom dispatcher** -- the substrate everyone uses on consumer hardware for the GPU-swapping mechanics. Orchestration policy on top is whatever you build.
5. **Big-Little Decoder / CALM** -- confidence-driven handoff between fast and slow processors, but at the token level inside one inference, not at the task level across separate models.

### Is "self-aware primary requests handoff" supported by evidence?
**Partially. Conditionally. Not as a sole trigger.** The empirical record is consistent: models produce a usable but noisy signal about their own competence. That signal is too noisy to act on directly without a meta-policy or external verifier; it degrades on reasoning-tuned models; it varies by an order of magnitude across models.

A workable design treats the primary's handoff request as evidence to weigh, not a command to execute. The coordinator should also have an **independent signal** -- output classifier, semantic drift detector, or retrieval-grounded check -- and act on the combination.

### Is "small dedicated coordinator model" supported?
**Yes, but rare and recent.** Almost every production multi-agent system surveyed uses either:
- (a) Code-based deterministic routing (RouteLLM, FrugalGPT, HybridLLM, llama-swap, Aider Architect/Editor, MetaGPT SOPs), or
- (b) A large LLM as orchestrator (AutoGen GroupChatManager, CrewAI hierarchical mode, LangGraph supervisor, OpenAI Swarm agent-to-agent).

NVIDIA Orchestrator-8B (Nov 2025) is the strongest existing precedent for a **purpose-trained small coordinator** -- beats prompt-based GPT-5 orchestration on cost (~30%) and latency (~2.5x). But it was RL-trained for the role; an off-the-shelf small model doing this with prompting would likely underperform `[inference, supported by Orchestrator-8B's RL training being central to their reported gains]`.

### Top 3 things that have broken

1. **Cascade error propagation across handoffs.** MAST (https://arxiv.org/abs/2503.13657) documents this as the dominant inter-agent failure. One agent misreads a value, downstream agents accept it uncritically. In a swap-based design this is worse: the new primary sees only the conversation history, not the previous primary's *internal hypothesis*, and re-derives a wrong-but-plausible explanation. See also the JetBrains Junie "context evaporation" writeup (https://memu.pro/blog/junie-cli-model-agnostic-coding-memory).

2. **Confidence is unreliable, especially on reasoning models.** AbstentionBench (https://arxiv.org/abs/2506.09038) shows reasoning fine-tuning *degrades* abstention by ~24%. Dunning-Kruger (https://arxiv.org/html/2603.09985v1) shows weaker models are more overconfident -- meaning your domain-specialist primary is potentially the *worst* available judge of "this is outside my domain."

3. **Mixing heterogeneous models often degrades quality.** Self-MoA / Rethinking-MoA (https://arxiv.org/abs/2502.00674) shows running multiple different LLMs and aggregating their outputs is *worse* than running multiple samples from the single best model -- by 6.6% on AlpacaEval 2.0. For the user's design every wrong-routing event is not just a latency cost but a potential quality regression. The design needs a bias toward "stay with the current primary unless the evidence to swap is strong."

### Architectural recommendations [inference, derived from the synthesis]
- Treat the coordinator as a *gatekeeper* of swap requests, not an active decision-maker. Combine three signals: (1) primary's verbalised request, (2) coordinator's classification of the in-flight output's domain, (3) an independent confidence proxy like response perplexity from the primary's logits.
- Keep an explicit "current-primary handoff cost budget" and require evidence above threshold to spend a swap. The MAST and AutoMix evidence both point to over-eager swapping as a failure mode.
- Treat any state passed across a swap as **untrusted**. The new primary should be re-grounded with the original problem statement plus a *summary* of what the previous primary tried, not just the raw transcript.
- The "always-resident small coordinator on a separate GPU" mechanical pattern is well-precedented. The novel part of the user's design is the *combination* of (small coordinator) + (skill-based primary swap) + (in-flight state preservation) + (self-requested handoff). Each axis has prior art individually; the combined system does not appear to have a public exemplar as of 2026-04.
