# Prior Art: Dispatcher-In-Front and Dispatcher-In-The-Passenger-Seat

**Date:** 2026-04-24
**Scope:** two of three coordination patterns under consideration for the homelab two-GPU setup. The "catch-and-swap" / dispatcher-behind variant is covered in the sibling document `2026-04-24-multi-model-handoff-prior-art.md`.

## Pattern A -- Dispatcher-in-Front

### A.1 Supervisor / Manager-Worker Frameworks

**LangGraph supervisor.** Central LLM orchestrator receives every operator message, routes to a specialist, gets control back. The DEV.to comparison is unusually candid on the tradeoff: "the supervisor is more accurate because routing is its only job, a dedicated LLM call with a focused prompt. The swarm is faster because it skips the intermediary." Supervisor adds one LLM hop per turn. (https://github.com/langchain-ai/langgraph-supervisor-py , https://dev.to/focused_dot_io/multi-agent-orchestration-in-langgraph-supervisor-vs-swarm-tradeoffs-and-architecture-1b7e)

**AutoGen GroupChatManager.** Documented failures:
- Function calling silently breaks under group chat: "None is not of type 'array' - 'messages.2.tool_calls'" -- works in 1:1, fails under supervisor (https://github.com/microsoft/autogen/issues/1440 , https://github.com/microsoft/autogen/issues/960).
- Speaker selection returns nothing when the model treats the latest system message as already complete (https://github.com/microsoft/autogen/issues/1659).
- Role bleed -- agents start producing multi-speaker text (https://github.com/microsoft/autogen/discussions/2943).

These are canonical small-supervisor failure modes: the supervisor's prompt context is heterogeneous (mixed system, partial tool calls, multiple personas) and small models lose track. *Inference:* this would hit hard on an 8 GB-resident sidecar at the typical 4-8k working context an operator session needs.

**CrewAI hierarchical process.** Most negative empirical evidence in the literature. From Towards Data Science: "CrewAI executes all tasks sequentially, causing incorrect agent invocation, overwritten outputs, and inflated latency/token usage" (https://towardsdatascience.com/why-crewais-manager-worker-architecture-fails-and-how-to-fix-it/). Bug #4783 confirms: with `allow_delegation=True`, manager agents still cannot delegate -- "manager agents only execute tasks using their own tools" (https://github.com/crewAIInc/crewAI/issues/4783). Community thread "Does hierarchical process even work?" is dominated by users reporting fallback to sequential (https://community.crewai.com/t/does-hierarchical-process-even-work-your-experience-is-highly-appreciated/2690).

**Microsoft Magentic-One.** Most heavily benchmarked supervisor system. Orchestrator runs two loops: outer "task ledger" (facts, guesses, plan), inner "progress ledger" (current step, agent assignments). Coordinates WebSurfer, FileSurfer, Coder, ComputerTerminal. With GPT-4o or o1 orchestrator: GAIA 38%, AssistantBench 27.7%, WebArena 32.8% -- "statistically competitive with state-of-the-art" (https://arxiv.org/html/2411.04468v1 , https://www.microsoft.com/en-us/research/articles/magentic-one-a-generalist-multi-agent-system-for-solving-complex-tasks/). The paper does *not* publish small-orchestrator ablations; the ledger structure assumes frontier capability.

**MetaGPT.** Encodes Standard Operating Procedures as prompts with named roles (Product Manager, Architect, Engineer). 85.9% Pass@1 on HumanEval, 87.7% on MBPP (https://arxiv.org/html/2308.00352v6). Adding executable feedback as a critic role added +4.2% on HumanEval -- gains come from process supervision, not just role-play. Uses GPT-4 throughout.

**Anthropic's research multi-agent system.** Most candid first-person engineering writeup. Architecture: Opus 4 lead, Sonnet 4 subagents in parallel. Result: outperforms a single Opus agent by >90% on internal research evals (https://www.anthropic.com/engineering/multi-agent-research-system). Key admissions:
- Token cost ~15x normal chat.
- Early failures: orchestrator spawned 50 subagents for trivial queries, scoured the web for non-existent sources, distracted itself with subagent updates.
- "Teach the orchestrator how to delegate" became its own engineering principle.
- The orchestrator is itself a *top-tier* LLM. Anthropic does not run a small-model orchestrator over large workers -- the inverse.

This is the load-bearing data point for Pattern A: the team most aggressively shipping the supervisor pattern uses a large supervisor.

### A.2 Task Decomposition / Planner-Executor

**Plan-and-Execute (LangChain).** LangChain's own blog admits: "a lot of these improvements are largely theoretical, or at the very least not benchmarked" (https://blog.langchain.com/plan-and-execute-agents/).

**HuggingGPT / JARVIS.** ChatGPT planner + Hugging Face executors. 130-prompt eval shows GPT-3.5 dramatically outperforms Alpaca-13B and Vicuna-13B as the controller "by a large margin across different stages, from task planning to response generation" (https://arxiv.org/abs/2303.17580). Direct paper conclusion: "the necessity of a powerful LLM as a controller". Strongest empirical statement against using a small model as planner/dispatcher.

**PEAR (Planner-Executor Agent Robustness Benchmark, 2025).** Most directly relevant new benchmark (https://arxiv.org/abs/2510.07505):
- "A weak planner degrades overall clean task performance more severely than a weak executor."
- Memory module is essential for the planner; not for the executor.
- Planner-targeted attacks succeed at 82-88%; errors propagate downstream.
- "Weak planners are the most critical bottleneck."

Strongest published evidence that the dispatcher-in-front role is *not* a safe place for the weakest model.

### A.3 Routing-as-Orchestration

**RouteLLM (LMSYS).** Trained binary routers strong/weak. 85% cost reduction on MT-Bench, 95% of GPT-4 quality. Matrix-factorization router reaches 95% of GPT-4 with only 26% of calls; best causal-LLM router needs 54% (https://www.lmsys.org/blog/2024-07-01-routellm/ , https://arxiv.org/abs/2406.18665). Trained routers significantly beat zero-shot.

**RouterBench.** Oracle Router (perfect routing) reaches ~0.96 mean performance -- gap between practical routers and theoretical optimum is small in aggregate, but per-prompt the right model is often *not* the most expensive (https://arxiv.org/abs/2403.12031 , https://withmartian.com/post/introducing-routerbench).

**RouterEval (2025).** Confirms model-level scaling-up of routing pools (https://arxiv.org/abs/2503.10657).

Routing is *the* well-validated place for a small model to make decisions, **but** routing is much narrower than full orchestration -- it picks the next-turn model, doesn't decompose tasks or integrate outputs.

### A.4 Production-Adjacent Notes

**OpenAI Swarm / Agents SDK.** Swarm's "triage agent" pattern is the canonical front-door supervisor in tutorial form. Swarm explicitly deprecated for production in favor of Agents SDK (https://github.com/openai/swarm , https://cookbook.openai.com/examples/orchestrating_agents). Telling design quote: "every handoff must include all context the next agent needs--no hidden variables, no magical memory."

**Cursor / Copilot.** Cursor 2.0 trained their own in-house "Composer" model rather than putting a small dispatcher in front of a large one -- they collapsed the pattern (https://qubittool.com/blog/ai-agent-framework-comparison-2026 , https://mrmaheshrajput.medium.com/i-reverse-engineered-how-cursor-copilot-actually-work-ce0a6a7f1838). NVIDIA's llm-router and the open-source kcolemangt/llm-router target the cost-routing case (https://github.com/NVIDIA-AI-Blueprints/llm-router , https://github.com/kcolemangt/llm-router), not full orchestration. *Inference:* in commercial code assistants, full small-model-in-front orchestration is conspicuously absent.

---

## Pattern B -- Dispatcher-in-the-Passenger-Seat

### B.1 Critic-Actor / Generator-Critic Loops

**Self-Refine (2023).** Same model, different prompts for generator/critic/refiner. GPT-4 dialogue preference 25.4% -> 74.6%, +8.7 code optimization, +13.9 code readability (https://arxiv.org/abs/2303.17651 , https://selfrefine.info/). Same-model design is a constraint, not a result.

**Reflexion (NeurIPS 2023).** Three components -- Actor, Evaluator, Self-Reflection -- Evaluator can be external. +22% decision tasks, +20% reasoning, +11% Python coding over 12 iterations (https://arxiv.org/abs/2303.11366). HumanEval: 91% pass@1 vs. GPT-4's 80% baseline (https://klu.ai/glossary/humaneval-benchmark). Closest published cousin to "small advisor next to large actor".

**"LLMs Cannot Self-Correct Reasoning Yet" (Huang et al., DeepMind, ICLR 2024).** Key counter to same-model critique: "LLMs have trouble reliably evaluating the correctness of their own responses, and they rarely identify flaws in initial reasoning" (https://arxiv.org/abs/2310.01798). Self-correction succeeds *only* with external feedback. The empirical backbone for any Pattern B argument: outside-critic value isn't "another opinion", it's *any* opinion at all.

**Tyen et al., ACL 2024.** Locating an error and fixing one are different skills. A small advisor is well-suited to *flagging* without producing the corrected reasoning (https://aclanthology.org/2024.findings-acl.826/).

**CritiqueLLM (2024).** Direct external-vs-self comparison. ChatGPT critiquing itself "has a negative impact on the overall quality"; CritiqueLLM-66B critique "even larger than that from GPT-4's critiques" (https://arxiv.org/abs/2311.18702). Confirms separate-critic > self-critic, and the critic does not need to be larger than the generator.

**CRITIC (2024).** External-tool "Verify => Correct => Verify". ChatGPT + CRITIC: +7.7 F1 QA, +7.0% math, -79.2% toxicity (https://arxiv.org/abs/2305.11738).

**Critique-Guided Improvement / CGI (2025).** A trained Llama-3-8B critic outperforms GPT-4-as-critic by +29.16%; action-refinement adds another +26.74% over SOTA (https://arxiv.org/html/2503.16024v2). Strongest single result for "small critic, big actor" -- *if* the critic is trained for the role.

**Constitutional AI / RLAIF.** Original CAI samples critique and revision from the same model. Subsequent direct-RLAIF (Lee et al. 2024) beats distilled RLAIF 60% of the time, AI labeler can be the same size as the policy (https://arxiv.org/html/2309.00267v3 , https://arxiv.org/abs/2212.08073). What matters is the critic having a clear, stable rubric, not its size.

### B.2 Real-Time Advisory / Sidecar Watching

This is the sparsest part of the literature. Speculative decoding (small drafter + large verifier, e.g. SemanticSpec at https://arxiv.org/html/2602.03708 , vLLM speculators at https://github.com/vllm-project/speculators) is mechanical token-level work, not semantic advice.

The closest semantic-advisor systems:
- **Cognitive Companion** (industrial batch processing case study, MDPI 2025): Primary Agent + "Companion Observer" + "Intervention Handler" inject guidance when degradation detected. Effectiveness task-type dependent (https://www.mdpi.com/2673-2688/7/2/51).
- **Reliable Weak-to-Strong Monitoring of LLM Agents** (https://arxiv.org/abs/2508.19461 , 2025). Most relevant recent paper. Studies whether *small* monitors can reliably oversee *large* agents. Finding: standalone weak monitors are unreliable; "a hybrid system combining both sequential and hierarchical monitoring can empower weak models to monitor strong LLMs much more reliably."
- **Conversation-based assessment "Watcher"** (https://link.springer.com/chapter/10.1007/978-3-031-98417-4_9). Notable that the Watcher itself is intentionally *not* an LLM -- they put the brittle decision logic outside the model.

*Inference:* there is very little published work on a sidecar LLM that watches another LLM's output stream and contributes mid-generation in a *semantic* (not token-prediction) way. The closest deployed analogues are safety / red-team monitors. The user's homelab use case may genuinely be ahead of the literature.

### B.3 Memory / Context-Augmentation Sidecars

**MemGPT / Letta.** Canonical sidecar-as-memory pattern. Two-tier hierarchy (in-context core / external archival). The agent uses tool calls to page memory in/out -- memory is *queried by* the generator, not pushed (https://docs.letta.com/concepts/memgpt/ , https://research.memgpt.ai/). The Letta v1 retrospective is candid: their original ReAct-style memory loop had to be redesigned closer to Claude Code's pattern, with explicit memory blocks editable by other agents (https://www.letta.com/blog/letta-v1-agent). Production confirmation that *push* from a memory sidecar back into the primary's context is hard to schedule reliably -- pull-based memory is what shipped.

### B.4 Process Supervision / Monitoring

**Process Reward Models (PRMs).** Originally training-time. Inference uses include best-of-N and stepwise greedy search (https://www.stephendiehl.com/posts/process_reward/ , https://www.emergentmind.com/topics/process-reward-models-prms). Documented limitation: state-of-the-art PRMs systematically *overestimate* success probability, especially on hard / OOD problems. This is the calibration failure mode to expect from any small monitor.

**MASPRM (2025).** Extends PRMs to multi-agent settings, explicitly intended for inference-time scoring of in-flight agent trajectories (https://arxiv.org/html/2510.24803).

**R-PRM (2025).** Monitor produces explicit reasoning before scoring; addresses calibration in older PRMs (https://arxiv.org/abs/2503.21295).

The pattern is moving from training to inference but is not yet standard production tooling.

### B.5 The User's Watcher Pattern Specifically

The user's existing system: small model reads transcripts, flags issues to the *operator*. Very little prior art for the variant where the flag goes back to the generator instead:
- Reflexion's Evaluator routes verbal feedback back to the Actor in the next trial -- but between trials, not mid-generation.
- Cognitive Companion injects guidance into the primary mid-task with task-dependent effectiveness.
- CGI trains the actor to *receive* critique -- strong implication that primaries that haven't been trained to listen will tend to ignore advisor signals.

*Inference:* the operator-flagging variant the user already runs is conservative but well-aligned with the literature's most reliable finding (external critique beats self-critique, but only if the receiver acts on it). Routing the flag back to the primary without primary-side training to use it is plausibly *worse* than the current design.

---

## Synthesis

### Comparison Matrix

| Dimension | A: Front (small dispatcher) | B: Passenger (small advisor) | C: Behind / catch-and-swap |
|---|---|---|---|
| Who talks to operator | Small model | Primary (large) | Primary; endpoint hides swaps |
| Initiative | Coordinator | Primary | Primary requests handoff; coordinator executes |
| Failure if small model is weak | Severe -- decomposition wrong, errors propagate (PEAR) | Moderate -- primary can ignore bad advice | Moderate -- handoff misses, no decomposition damage |
| Token cost | +1 small-model hop per turn | +1 small-model hop per turn (parallelizable) | Coordinator runs at swap boundaries only |
| Best-fit task | Routing, narrow triage | Memory, critique, error flagging | Long sessions where model identity is fluid |
| Research maturity | High | Mixed -- critic mature, real-time advisor sparse | Low -- under-published as a discrete pattern |

### What the evidence says about quality

- **Front pattern.** Small-as-supervisor is *not* well supported. PEAR shows weak planners are the dominant failure point. HuggingGPT explicitly concludes a "powerful LLM as controller" is necessary. Anthropic uses Opus 4 -- their largest model -- as the orchestrator. Where small models *do* succeed in front-position, the role is narrowed to routing (RouteLLM: 95% of GPT-4 quality at 26% of GPT-4 calls; RouterBench Oracle bound 0.96), not full orchestration.
- **Passenger pattern.** Separate-model critique consistently beats self-critique (Huang DeepMind 2024; CritiqueLLM; CRITIC). A trained small critic can outperform GPT-4 as critic (CGI: +29% over GPT-4). Quality wins are most reliable when the critic has a stable rubric and the actor is structured to receive feedback.

### Top failure modes

**Front pattern:**
1. Decomposition errors propagate. PEAR: planner-targeted attacks 82-88% success, errors flow downstream (https://arxiv.org/abs/2510.07505).
2. Supervisor framework primitives silently fall back to sequential. CrewAI in practice: "manager agents only execute tasks using their own tools" (https://github.com/crewAIInc/crewAI/issues/4783). AutoGen GroupChatManager loses tool-call structure (https://github.com/microsoft/autogen/issues/1440).
3. Token cost balloon when the supervisor over-spawns. Anthropic: ~15x chat baseline with documented "50 subagents for trivial query" failures.

**Passenger pattern:**
1. Primary ignores advisor input when not trained to consume it. Implied by CGI's actor fine-tuning requirement; consistent with the user's choice to route flags to the operator.
2. Calibration drift in the monitor. PRMs systematically overestimate success on hard / OOD problems.
3. Push-vs-pull contention for context. MemGPT/Letta converged on pull-based memory because push-based mid-turn injection is hard to time -- no clean blueprint exists for sidecar interruption protocols.

### Operator UX implications

- **Front pattern.** The operator talks to a smaller, less capable model first. No controlled UX study found in the literature; closest analogue is customer-support triage chatbots (Swarm's example), which historically frustrate users when triage misroutes. *Inference:* in a personal homelab with an expert operator, the friction of explaining intent to a small front-door model is the dominant pain point. Swarm's instruction to its triage agent -- "make your questions subtle and natural" -- is a tell.
- **Passenger pattern.** Operator interacts with the large primary directly; advisor is invisible by default. The user's existing watcher (flag to operator, not back to primary) is well-supported by the structural finding that primaries don't reliably act on unsolicited advice. Cost: operator now consumes two streams (primary output + advisor flags), which needs UI affordance.

### Where each pattern is the right answer

- **Front pattern wins when** the small model's only job is *routing* among well-typed services (RouteLLM-class problem) or *triage* with hard handoff to a deterministic backend, and the operator's intent is short and stereotyped. Trained routers achieve 95% of frontier quality at <30% of frontier cost. It loses when the small model has to *decompose* a complex multi-step request -- PEAR / HuggingGPT / Anthropic's choice of Opus orchestrator all point the same way.
- **Passenger pattern wins when** the contribution is *narrow and asynchronous* -- error spotting, memory recall, "you forgot X". Separate-model critique beats self-critique (Huang 2024; CritiqueLLM); pull-based memory shipped in production (Letta v1). It loses when the contribution requires *interrupting* the primary mid-generation in real time -- no robust blueprint, and Letta deliberately backed off to pull-based.
- **Behind / catch-and-swap (sibling document's pattern) wins when** the operator wants a single seamless conversation but the underlying model identity should change based on context (long session, evolving topic). Advantage over A: operator never speaks to the small model directly. Advantage over B: small model has actual swap authority, not advisory authority. Cost: mis-swap is hard to recover gracefully; operator can't tell which model is currently driving without instrumentation.

### Recommendation framework for the user's homelab

Given the 24 GB primary + 8 GB always-resident secondary:
- For the operator-facing surface, evidence weighs against putting the 8 GB sidecar in front. PEAR and HuggingGPT directly argue against weak planners. If the front-door role is unavoidable, narrow it to *routing* (RouteLLM-style) where small models are well-validated.
- For the passenger-seat advisor, evidence supports the user's existing design. Two well-supported extensions:
  - Add a memory-block role (MemGPT-style) the primary can *query*, not be pushed.
  - Add a single-token "should the operator look at this?" classifier, the empirically reliable form of process supervision (R-PRM, MASPRM).
- The catch-and-swap pattern is the under-explored option in the literature -- less prior art to lean on but also less crowded design space. The natural place for the small model is as a *swap coordinator at session boundaries*: combines the strengths of the passenger-seat advisor (no operator-facing cost) with the swap mechanics (no decomposition burden on the small model).

---

## Sources (consolidated)

Pattern A:
- LangGraph supervisor: https://github.com/langchain-ai/langgraph-supervisor-py , https://dev.to/focused_dot_io/multi-agent-orchestration-in-langgraph-supervisor-vs-swarm-tradeoffs-and-architecture-1b7e
- AutoGen failures: https://github.com/microsoft/autogen/issues/1440 , https://github.com/microsoft/autogen/issues/960 , https://github.com/microsoft/autogen/issues/1659 , https://github.com/microsoft/autogen/discussions/2943
- CrewAI failures: https://github.com/crewAIInc/crewAI/issues/4783 , https://towardsdatascience.com/why-crewais-manager-worker-architecture-fails-and-how-to-fix-it/ , https://community.crewai.com/t/does-hierarchical-process-even-work-your-experience-is-highly-appreciated/2690
- Magentic-One: https://arxiv.org/html/2411.04468v1 , https://www.microsoft.com/en-us/research/articles/magentic-one-a-generalist-multi-agent-system-for-solving-complex-tasks/
- MetaGPT: https://arxiv.org/html/2308.00352v6
- Anthropic multi-agent research: https://www.anthropic.com/engineering/multi-agent-research-system
- Plan-and-Execute: https://blog.langchain.com/plan-and-execute-agents/
- HuggingGPT: https://arxiv.org/abs/2303.17580
- PEAR: https://arxiv.org/abs/2510.07505
- RouteLLM: https://www.lmsys.org/blog/2024-07-01-routellm/ , https://arxiv.org/abs/2406.18665
- RouterBench: https://arxiv.org/abs/2403.12031 , https://withmartian.com/post/introducing-routerbench
- RouterEval: https://arxiv.org/abs/2503.10657
- OpenAI Swarm / Agents SDK: https://github.com/openai/swarm , https://cookbook.openai.com/examples/orchestrating_agents
- Production routers: https://github.com/NVIDIA-AI-Blueprints/llm-router , https://github.com/kcolemangt/llm-router
- Cursor 2.0 / Composer: https://qubittool.com/blog/ai-agent-framework-comparison-2026

Pattern B:
- Self-Refine: https://arxiv.org/abs/2303.17651 , https://selfrefine.info/
- Reflexion: https://arxiv.org/abs/2303.11366 , https://github.com/noahshinn/reflexion , https://klu.ai/glossary/humaneval-benchmark
- LLMs Cannot Self-Correct Reasoning Yet (Huang/DeepMind): https://arxiv.org/abs/2310.01798
- LLMs Cannot Find Reasoning Errors (Tyen et al., ACL 2024): https://aclanthology.org/2024.findings-acl.826/
- CritiqueLLM: https://arxiv.org/abs/2311.18702
- CRITIC: https://arxiv.org/abs/2305.11738
- Critique-Guided Improvement (CGI): https://arxiv.org/html/2503.16024v2
- Constitutional AI: https://arxiv.org/abs/2212.08073 , https://www.anthropic.com/research/constitutional-ai-harmlessness-from-ai-feedback
- RLAIF (direct vs distilled): https://arxiv.org/html/2309.00267v3
- MemGPT / Letta: https://research.memgpt.ai/ , https://docs.letta.com/concepts/memgpt/ , https://www.letta.com/blog/letta-v1-agent
- Process Reward Models: https://www.stephendiehl.com/posts/process_reward/ , https://www.emergentmind.com/topics/process-reward-models-prms
- MASPRM: https://arxiv.org/html/2510.24803
- R-PRM: https://arxiv.org/abs/2503.21295
- Weak-to-Strong Monitoring of LLM Agents: https://arxiv.org/abs/2508.19461
- Cognitive Companion / hybrid intervention: https://www.mdpi.com/2673-2688/7/2/51
- Conversation-based Watcher: https://link.springer.com/chapter/10.1007/978-3-031-98417-4_9
- Speculative decoding (mechanical contrast): https://arxiv.org/html/2602.03708 , https://github.com/vllm-project/speculators
- Anthropic scalable oversight: https://www.anthropic.com/research/automated-alignment-researchers
