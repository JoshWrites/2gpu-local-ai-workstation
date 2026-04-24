# Session State Architectures for Multi-Model Collaboration: A Neutral Survey

**Date:** 2026-04-24
**Scope:** Systems where more than one LLM contributes to the same user-facing multi-turn session, and some mechanism carries state across turns and across model transitions. Excludes single-model sessions and purely stateless routers with no memory.

This is a literature survey, not a design document. No recommendation is made. Where a claim is an inference rather than a citation, it is labelled `[inference]`. URLs are primary sources (arxiv, project docs, engineering blogs) where possible.

---

## Phase 1 — Enumeration of Architectural Patterns

Six named patterns with distinct, published exemplars emerged from the literature. Each is confirmed by at least one peer-reviewed paper or widely-adopted framework; no pattern was listed without a concrete reference. The list is not padded — patterns that looked plausible but lacked distinct exemplars (e.g., "pure transcript replay with no summarisation" in a multi-model context) were folded into adjacent patterns rather than split out.

1. **Orchestrator-Owns-Thread (Supervisor + Subroutine Subagents).** One persistent agent holds the conversation and calls stateless specialist models as bounded sub-calls; only digested results return to the persistent thread. Exemplar: Anthropic's Research system — <https://www.anthropic.com/engineering/multi-agent-research-system>.

2. **State-Object Handoff (Baton).** A structured state blob (typed schema, scratchpad, or `Command` payload) is handed from one agent to the next; the receiving agent becomes the new owner of the session. Exemplar: LangGraph's `Command` + Swarm-style handoffs — <https://blog.langchain.com/command-a-new-tool-for-multi-agent-architectures-in-langgraph/>.

3. **Shared External Memory (Blackboard / Message Pool).** No agent holds session state in its own context; all agents read/write a shared store (blackboard, publish-subscribe pool, vector memory) and are selected per turn by what is posted. Exemplar: MetaGPT's shared message pool — <https://arxiv.org/abs/2308.00352>; Lu et al. 2025 LbMAS — <https://arxiv.org/abs/2510.01285>.

4. **Transcript-as-State (Full-Replay).** Every turn replays the entire prior transcript to whichever model answers next; the transcript is the canonical state. Exemplar: OpenAI Swarm routines/handoffs — <https://cookbook.openai.com/examples/orchestrating_agents>; AutoGen GroupChat — <https://microsoft.github.io/autogen/0.2/docs/Use-Cases/agent_chat/>.

5. **Planner + Worker with Plan-as-State.** A planning agent produces a written plan/SOP; worker agents consume and update that document rather than the raw dialogue. Exemplar: MetaGPT SOP artifacts (PRD → design → tasks → code) — <https://arxiv.org/abs/2308.00352>; LangGraph hierarchical agent teams — <https://langchain-ai.github.io/langgraph/tutorials/multi_agent/hierarchical_agent_teams/>.

6. **Tiered OS-Style Memory (Paged Context).** A single agent identity persists across turns but is backed by multiple memory tiers (core/recall/archival) that are paged in and out of context by tool calls; different model specialisations can attach to the same memory backend. Exemplar: MemGPT / Letta — <https://arxiv.org/abs/2310.08560>.

7. **Consensus / Debate Aggregation.** Multiple models answer the same turn; an aggregation step (vote, debate rounds, judge) produces the canonical answer, which becomes the state for the next turn. Exemplar: Du et al. multi-agent debate (ICML 2024) — <https://arxiv.org/abs/2305.14325>.

A candidate eighth pattern ("true mid-generation handoff," where one model is interrupted mid-response and another continues) was investigated and **not included** — the prior literature review in `/docs/research/2026-04-24-multi-model-handoff-prior-art.md` concluded no peer-reviewed exemplars exist; the closest work (speculative decoding, CALM early-exit) switches layers within one model, not between distinct models with different strengths.

---

## Phase 2 — Per-Pattern Investigation

Coverage is roughly equal across patterns. Where a pattern has few exemplars, that is noted explicitly rather than padded.

### Pattern 1 — Orchestrator-Owns-Thread

**Canonical description.** A lead model holds the persistent user-facing session. When subtasks arise, the lead spawns stateless subagents with a narrow objective and a fresh context. Subagents return structured results; only those results (not their scratch) re-enter the lead's context. The session state is the lead's transcript plus any digest it chose to retain.

**Exemplars.**
- Anthropic Research system (Claude Opus 4 lead + Sonnet 4 workers). <https://www.anthropic.com/engineering/multi-agent-research-system>
- LangGraph Supervisor pattern. <https://github.com/langchain-ai/langgraph-supervisor-py>
- Claude Code Agent Teams. <https://code.claude.com/docs/en/agent-teams>
- OpenAI Agents SDK (successor to Swarm, supervisor-capable). <https://cookbook.openai.com/examples/orchestrating_agents>

**Measured outcomes.**
- Anthropic reports their Opus-lead + Sonnet-subagents system outperformed single-agent Opus by **90.2%** on their internal research evaluation. <https://www.anthropic.com/engineering/multi-agent-research-system>
- Anthropic also reports multi-agent research used **~15× more tokens** than a single-turn chat for comparable tasks; they scope the pattern to tasks "where the value of the answer is high enough to pay for it." <https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them>

**Reported failure modes.**
- Context narrowing at handoff: sub-results are compressed summaries, so nuance in the subagent's reasoning is lost by the time it reaches the lead. MAST taxonomy (Cemri et al. 2025) logs this under "information withholding" and "task misalignment." <https://arxiv.org/abs/2503.13657>
- Coordination overhead: each level of hierarchy adds a full LLM round-trip to any decision. Documented as "accumulated latency" in multiple production write-ups. <https://galileo.ai/blog/architectures-for-multi-agent-systems>
- Lead-agent context window exhaustion when many subagents each return long reports; Anthropic notes they added explicit digest steps for this reason. <https://www.anthropic.com/engineering/multi-agent-research-system>

**Where it works well (cited).** Heavy-parallelisation tasks that exceed a single context window and need diverse tools — Anthropic explicitly scopes the pattern here. <https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them>

**Where it works badly (cited).** Coding and tightly coupled tasks where subagents make conflicting decisions in parallel; Anthropic recommends single-agent for those. <https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them>

---

### Pattern 2 — State-Object Handoff (Baton)

**Canonical description.** A typed state object (schema, not a transcript) is the unit of handoff. Agent A returns a `Command(update=..., goto=...)` or equivalent, which both mutates the shared state and names the next agent. Ownership of the session transfers; the new agent reads the state and continues.

**Exemplars.**
- LangGraph `Command` primitive. <https://blog.langchain.com/command-a-new-tool-for-multi-agent-architectures-in-langgraph/>
- LangGraph Swarm. <https://github.com/langchain-ai/langgraph-swarm-py>
- OpenAI Swarm (agents return other agents from tool calls). <https://github.com/openai/swarm>
- Microsoft Agent Framework (successor of AutoGen 0.4) "typed state transitions." <https://learn.microsoft.com/en-us/agent-framework/migration-guide/from-autogen/>

**Measured outcomes.** Very few published benchmark numbers — this pattern is documented mostly in framework docs and engineering blogs, not peer-reviewed comparisons. LangGraph docs claim reduced "handoff drift" versus transcript replay but provide no quantitative benchmark in the source material reviewed. [inference from absence] Most published numbers bundle this pattern with Pattern 1 or Pattern 3.

**Reported failure modes.**
- Schema brittleness: if two agents disagree about a field's meaning, state is silently corrupted. Multiple framework discussions describe this; Galileo's taxonomy lists it under "specification drift." <https://galileo.ai/blog/why-multi-agent-systems-fail>
- "Lost baton" during async or multi-step handoffs: the next agent starts before the previous agent finished its state write. Documented in AutoGen group-chat discussions. <https://github.com/microsoft/autogen/discussions/7144>
- Handoff loops: A → B → A → B with each pass adding cruft but no progress. Cemri et al. (MAST) log this as a measurable failure mode in ~7 frameworks. <https://arxiv.org/abs/2503.13657>

**Where it works well (cited).** Clear specialist boundaries and one-way handoffs, per OpenAI's routines-and-handoffs cookbook. <https://cookbook.openai.com/examples/orchestrating_agents>

**Where it works badly (cited).** Problems whose structure is not known in advance, so the state schema cannot be authored ahead of time. LangGraph docs recommend shared-memory or supervisor patterns in that case. <https://langchain-ai.github.io/langgraph/concepts/multi_agent/>

---

### Pattern 3 — Shared External Memory (Blackboard / Message Pool)

**Canonical description.** A single shared data structure (blackboard, publish-subscribe message pool, vector store, or structured DB) holds the session state. Agents subscribe to relevant content, post their outputs to the board, and the scheduler picks the next agent based on what is on the board. Derives from Hearsay-II (1970s) and BB1. No single agent "owns" the thread.

**Exemplars.**
- MetaGPT shared message pool + subscription. <https://arxiv.org/abs/2308.00352>
- LbMAS (LLM-based Multi-Agent Blackboard) — Lu et al. 2025. <https://arxiv.org/abs/2510.01285>
- Exploring Advanced LLM Multi-Agent Systems Based on Blackboard Architecture — Liu et al. 2025. <https://arxiv.org/abs/2507.01701>
- flock (open-source declarative blackboard MAS). <https://github.com/whiteducksoftware/flock>

**Measured outcomes.**
- LbMAS reports **13–57% relative improvement in end-to-end task success** and up to **9% F1 gain** on data-discovery tasks against master-slave baselines. <https://arxiv.org/abs/2510.01285>
- Liu et al. 2025 report competitive performance with state-of-the-art static/dynamic MAS "while spending fewer tokens" (quantitative table in paper). <https://arxiv.org/html/2507.01701v1>
- MetaGPT on HumanEval Pass@1: **85.9%**; MBPP: **87.7%**; SoftwareDev executability **3.75/4**. <https://arxiv.org/abs/2308.00352>

**Reported failure modes.**
- Agent selection collapse: if every agent thinks it is relevant, the board devolves into all-agents-speak-every-turn (quadratic cost). Liu et al. explicitly motivate their dynamic selection to address this. <https://arxiv.org/html/2507.01701v1>
- Write ordering / consistency: concurrent writes on the board lead to race conditions mirroring classic blackboard-system literature (Corkill). <http://mas.cs.umass.edu/Documents/Corkill/ai-expert.pdf>
- "Context collapse" when the board accumulates enough content to exceed any one agent's window; MetaGPT uses SOP artifacts to structure this, but free-form boards do not. <https://galileo.ai/blog/why-multi-agent-systems-fail>

**Where it works well (cited).** Open-ended problems whose workflow is not known in advance — Liu et al. frame this as the explicit motivation. <https://arxiv.org/html/2507.01701v1>

**Where it works badly (cited).** Tasks with clear linear dependencies where pipeline/state-object patterns are simpler; Liu et al. note blackboard adds overhead versus rigid workflows when the workflow is already well-specified. <https://arxiv.org/html/2507.01701v1>

---

### Pattern 4 — Transcript-as-State (Full Replay)

**Canonical description.** The canonical session state is the concatenated message transcript. Any model that answers next reconstructs its view by re-ingesting the full transcript. Specialisation is routing-only; no model holds hidden state between turns.

**Exemplars.**
- OpenAI Swarm (explicitly stateless; every run rebuilds from the message list). <https://github.com/openai/swarm>
- AutoGen GroupChat (all agents see the shared message list). <https://microsoft.github.io/autogen/0.2/docs/Use-Cases/agent_chat/>
- AgentRR record-and-replay (treats the trace itself as the retrievable memory). <https://arxiv.org/abs/2505.17716>
- Deterministic Projection Memory / stateless decision memory. <https://arxiv.org/html/2604.20158>

**Measured outcomes.**
- AutoGen on GAIA: multi-agent AutoGen with GroupChat was ranked #1 at submission (March 2024) on the GAIA benchmark — outperforming prior single-agent solutions. <https://github.com/microsoft/autogen/tree/gaia_multiagent_v01_march_1st>
- Swarm has no formal benchmark; it is labelled "educational." <https://github.com/openai/swarm>
- AgentRR reports task-success retention across replay; exact numbers in paper. <https://arxiv.org/html/2505.17716v1>

**Reported failure modes.**
- Context window saturation: transcripts grow unboundedly; once the next model cannot fit the full replay, either silent truncation happens or a summariser is inserted (moving the system toward Pattern 1 or 5). Documented by LoCoMo — even with 16K-context GPT-3.5-turbo, long conversations produce precision/recall drops of **3% and 8.7%** versus the 4K base variant due to hallucination and context dilution. <https://arxiv.org/abs/2402.17753>
- On LoCoMo (300 turns, 9K tokens, 35 sessions), best LLMs score QA F1 ~**32** vs. humans **~88**, with adversarial-QA F1 dropping to **12–22** even with long-context models. <https://snap-research.github.io/locomo/>
- Cost scales linearly with turns × models (every turn pays full prefill for every replayer).
- Role-flipping and deviation when all models share the same scratchpad — Li et al. CAMEL explicitly log "assistant taking control," "flake replies," "infinite loop of messages." <https://arxiv.org/abs/2303.17760>

**Where it works well (cited).** Short sessions, homogeneous specialists, and debuggable/replayable deployments where auditability is the load-bearing property; OpenAI's cookbook frames this as the canonical lightweight pattern. <https://cookbook.openai.com/examples/orchestrating_agents>

**Where it works badly (cited).** Long-running conversations; LoCoMo's numbers directly falsify "just use a bigger context" for multi-session dialogue. <https://arxiv.org/abs/2402.17753>

---

### Pattern 5 — Planner + Worker with Plan-as-State

**Canonical description.** A planner model produces an explicit written plan (PRD, task tree, SOP document). Workers read and update the plan rather than the raw conversation. The plan document, not the transcript, is the source of truth. Usually hierarchical: planner → supervisors → workers.

**Exemplars.**
- MetaGPT — PRD → design doc → task list → code, produced as explicit artifacts. <https://arxiv.org/abs/2308.00352>
- ChatDev — communicative agents with phase-scripted SOPs. <https://arxiv.org/abs/2307.07924>
- LangGraph hierarchical agent teams tutorial. <https://langchain-ai.github.io/langgraph/tutorials/multi_agent/hierarchical_agent_teams/>
- "Notebook" pattern in travel-planning MAS (structured information-sharing document). <https://www.preprints.org/manuscript/202512.2119>

**Measured outcomes.**
- MetaGPT HumanEval Pass@1: **85.9%**; MBPP: **87.7%**; SoftwareDev executability **3.75/4**. <https://arxiv.org/abs/2308.00352>
- ChatDev: <1 USD per end-to-end project and <7 minutes runtime (GPT-3.5-turbo-16k); **77.08%** win rate vs. GPT-Engineer on GPT-4 evaluation, **90.16%** on human evaluation. <https://arxiv.org/abs/2307.07924>
- MetaGPT ~**126 tokens/line** of code vs. ChatDev **~249 tokens/line** — Plan-as-state lowers per-LOC token cost in their comparison. <https://arxiv.org/abs/2308.00352>

**Reported failure modes.**
- Plan drift: workers silently diverge from the plan when the plan is wrong or incomplete. Cemri et al. identify "disobey task specification" and "fail to ask for clarification" as two of the 14 MAST modes. <https://arxiv.org/abs/2503.13657>
- Plan over-specification: SOP assumes a single canonical workflow; novel problems outside the SOP are forced into the wrong template. MetaGPT authors note the SOP is domain-specific. <https://arxiv.org/abs/2308.00352>
- Cascading errors: if the plan has a defect, every downstream worker amplifies it. <https://nimblebrain.ai/why-ai-fails/agent-governance/agent-failure-modes/>

**Where it works well (cited).** Domains with stable, repeatable workflows — MetaGPT explicitly motivates SOPs as "encoded human domain expertise"; ChatDev applies the same for software development. <https://arxiv.org/abs/2308.00352>

**Where it works badly (cited).** Unknown-unknowns and novel domains where no SOP exists; MetaGPT-derived frameworks require hand-authored SOPs per domain. <https://arxiv.org/abs/2308.00352>

---

### Pattern 6 — Tiered OS-Style Memory (Paged Context)

**Canonical description.** Session state lives in a hierarchical memory system (core = always in context; recall = searchable DB of past turns; archival = long-term vector store). The agent controls paging via function calls. Different model specialisations may attach to the same memory backend.

**Exemplars.**
- MemGPT / Letta. <https://arxiv.org/abs/2310.08560>, <https://docs.letta.com/concepts/memgpt/>
- A-Mem (Agentic Memory for LLM Agents). <https://arxiv.org/pdf/2502.12110>
- MemoryAgentBench and MemBench benchmarks measure this class. <https://github.com/Shichun-Liu/Agent-Memory-Paper-List>

**Measured outcomes.**
- MemGPT outperforms fixed-context baselines on document QA and nested-key-value retrieval beyond the base model's window size; specific numbers in the paper. <https://arxiv.org/pdf/2310.08560>
- MemoryAgentBench and LoCoMo provide measurement frameworks; LoCoMo shows best LLMs still **F1 ~32 vs. human ~88** even with memory-augmented agents. <https://snap-research.github.io/locomo/>
- Only two major published exemplars (MemGPT/Letta and A-Mem) were found that clearly fit the pattern definition; other "memory-augmented" work typically collapses to Pattern 3 or 4.

**Reported failure modes.**
- Archival-memory corruption in long conversations: Letta GitHub issues report the agent "refusing to acknowledge data present in pickle files" and fabricating archival content. <https://github.com/letta-ai/letta/discussions/502>
- Retrieval misses: semantic search returns wrong or stale data; the agent then confabulates on top. Also reported in the same discussions. <https://github.com/letta-ai/letta/issues/506>
- "Thinking forever" lockup when the memory-management function-call loop fails to converge. <https://github.com/letta-ai/letta/issues/506>
- The pattern is most-documented with a single-identity agent; generalising to multi-model/multi-specialist collaboration is under-studied [inference].

**Where it works well (cited).** Single-identity agents needing persistence across very long interactions (weeks/months). Letta docs cite personal assistants and document analysis. <https://research.memgpt.ai/>

**Where it works badly (cited).** Tasks requiring perfect recall or safety-critical consistency; retrieval is probabilistic and Letta/MemGPT does not guarantee deterministic access. <https://github.com/letta-ai/letta/discussions/502>

---

### Pattern 7 — Consensus / Debate Aggregation

**Canonical description.** Multiple models answer the same turn in parallel or in rounds; an aggregation operator (voting, judge-LLM, iterative debate with stability detection) produces the canonical answer. That answer becomes the state for the next turn.

**Exemplars.**
- Du et al. "Improving Factuality and Reasoning through Multiagent Debate" (ICML 2024). <https://arxiv.org/abs/2305.14325>
- LLM-Blender (ACL 2023) — PairRanker + GenFuser. <https://arxiv.org/abs/2306.02561>
- Adaptive Heterogeneous Multi-Agent Debate (A-HMAD, 2025). <https://link.springer.com/article/10.1007/s44443-025-00353-3>
- Free-MAD (consensus-free, single-round MAD). <https://arxiv.org/html/2509.11035v1>
- GroupDebate and S²-MAD (efficiency variants). <https://arxiv.org/html/2409.14051>, <https://arxiv.org/html/2502.04790v2>

**Measured outcomes.**
- Du et al.: on GSM8K, 3 agents × 2 rounds reach **85.0%** vs. single-agent **77.0%** (+8pp); MMLU, biographies, and chess show 5–10% absolute gains. <https://arxiv.org/abs/2305.14325>
- A-HMAD: **+4–6pp absolute** over standard debate on GSM8K/MMLU/arithmetic; **-30%+** factual errors on biography tasks. <https://link.springer.com/article/10.1007/s44443-025-00353-3>
- S²-MAD: up to **94.5% token-cost reduction** vs. baseline MAD with **<2% accuracy loss**. <https://arxiv.org/html/2502.04790v2>
- Accuracy plateaus at **2–3 rounds, 2–4 agents**; beyond that, cost climbs but accuracy does not. <https://hungleai.substack.com/p/agree-or-disagree-a-review-of-multi>

**Reported failure modes.**
- Quadratic (or worse) token cost in rounds × agents. Explicitly documented in every debate paper reviewed. <https://arxiv.org/html/2409.14051>
- Confident-wrong majority: if the majority of agents are wrong, debate amplifies the error — "The Consensus Trap" (2026). <https://arxiv.org/html/2604.17139>
- Session-state applicability is limited: debate papers mostly study single-turn QA, not multi-turn sessions. Carrying debate state across turns is under-studied — only Free-MAD and a few recent works consider longitudinal aggregation. <https://openreview.net/forum?id=46jbtZZWen>
- "Can LLM Agents Really Debate?" (2025 controlled study) questions whether the measured gains are debate-specific or just self-consistency. <https://arxiv.org/pdf/2511.07784>

**Where it works well (cited).** Factuality- and arithmetic-heavy single-turn tasks where errors are independent across agents; Du et al. and A-HMAD explicitly scope here. <https://arxiv.org/abs/2305.14325>

**Where it works badly (cited).** Interactive sessions where latency matters; tasks where all agents share the same bias (e.g., same base model). The Consensus Trap paper documents adversarial majorities collapsing the ensemble. <https://arxiv.org/html/2604.17139>

---

## Comparison Matrix

| Pattern | State carrier | Quality evidence | Top failure mode | Maturity | Best-fit task shape |
|---|---|---|---|---|---|
| 1. Orchestrator-Owns-Thread | Lead agent's context + digested subagent outputs | Anthropic: +90.2% on internal research eval; 15× token cost | Sub-result compression loses nuance; hierarchy latency | Production (Anthropic, Claude Code, LangGraph Supervisor) | Parallel research, multi-tool, high-value answers |
| 2. State-Object Handoff | Typed schema / Command payload | Few formal benchmarks; framework-documented | Schema drift; handoff loops; baton lost | Production frameworks, sparse papers | Linear specialist pipelines with stable schema |
| 3. Shared External Memory (Blackboard) | Central board / message pool | LbMAS +13–57% task success; MetaGPT HumanEval 85.9% | Agent-selection collapse; write-race; context collapse | Research + MetaGPT in production-adjacent use | Open-ended, workflow-unknown problems |
| 4. Transcript-as-State | Full message list replayed every turn | AutoGen #1 on GAIA (Mar 2024); LoCoMo best F1 32 vs human 88 | Window saturation; quadratic cost; role-flipping | Widely deployed (Swarm, AutoGen) | Short sessions, auditability-required deployments |
| 5. Planner + Worker (Plan-as-State) | Written plan / SOP artifact | MetaGPT 85.9% HumanEval; ChatDev <$1 & <7min/project | Plan drift; SOP over-fit to single workflow | Production (MetaGPT, ChatDev, LangGraph hierarchies) | Repeatable domains with stable process (SWE, PRD) |
| 6. Tiered OS-Style Memory | Core + recall + archival tiers | MemGPT beats fixed-context on long-doc QA; LoCoMo still F1 ~32 | Archival corruption; retrieval miss; think-forever lock | Research + small production (Letta) | Single-identity persistent assistants |
| 7. Consensus / Debate Aggregation | Aggregated answer of N parallel models | Du et al. +8pp GSM8K; A-HMAD +4–6pp; S²-MAD −94.5% tokens | Majority-is-wrong; round×agent cost; single-turn focus | Research-mature; limited production | Single-turn factuality / arithmetic QA |

---

## Gaps in the Literature

Several gaps emerged. These are areas where published evidence is thin; the user may find these worth their own investigation.

1. **Multi-turn extensions of debate/consensus.** Almost every Pattern 7 paper benchmarks single-turn QA (GSM8K, MMLU). How debate-produced state carries across turns of a user conversation is under-studied. Free-MAD and "Can LLM Agents Really Debate?" (2025) begin to question even the single-turn story. <https://arxiv.org/pdf/2511.07784>
2. **Cross-pattern hybrids.** Production systems (Anthropic Research, MetaGPT + Letta variants) mix patterns, but the literature tends to evaluate one pattern at a time. Which hybrids compose and which conflict is not systematically characterised. [inference from absence of such comparisons in MAST and other surveys]
3. **Mid-generation handoff.** No peer-reviewed exemplar of interrupting one model mid-response and having another model continue the same answer was found. Existing work (speculative decoding, CALM, early-exit) operates within a single model. This confirms the finding from <file:///home/levine/Documents/Repos/Workstation/second-opinion/docs/research/2026-04-24-multi-model-handoff-prior-art.md>.
4. **Memory consistency in multi-specialist settings.** MemGPT-style memory is almost always studied with a single agent identity; applying it across specialists (e.g., a coder and a reasoner sharing archival) has few exemplars. Letta's multi-agent support exists but is sparsely benchmarked. <https://docs.letta.com/guides/agents/memory/>
5. **Failure taxonomy is new.** The MAST taxonomy (Cemri et al. 2025) is the first empirically grounded catalogue of multi-agent failure modes (14 modes across 3 categories, κ=0.88 inter-annotator). It came out in 2025 and is still absorbing. <https://arxiv.org/abs/2503.13657>
6. **Session coherence metrics.** LoCoMo is the strongest measurement tool found (300 turns, 35 sessions) but is still QA-driven; a metric for "felt coherence" across model transitions in open-ended chat has no accepted benchmark. <https://arxiv.org/abs/2402.17753>

No recommendation is made. The choice of pattern depends on the task shape, latency budget, and whether the session's state is dominated by facts, artifacts, or unstructured dialogue — trade-offs the user is better positioned to weigh than this survey.

---

## Sources (consolidated)

- Anthropic — How we built our multi-agent research system. <https://www.anthropic.com/engineering/multi-agent-research-system>
- Anthropic — When to use multi-agent systems. <https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them>
- LangGraph Command blog. <https://blog.langchain.com/command-a-new-tool-for-multi-agent-architectures-in-langgraph/>
- LangGraph Swarm. <https://github.com/langchain-ai/langgraph-swarm-py>
- LangGraph Supervisor. <https://github.com/langchain-ai/langgraph-supervisor-py>
- LangGraph Hierarchical Agent Teams. <https://langchain-ai.github.io/langgraph/tutorials/multi_agent/hierarchical_agent_teams/>
- OpenAI Swarm. <https://github.com/openai/swarm>
- OpenAI Cookbook — Orchestrating Agents: Routines and Handoffs. <https://cookbook.openai.com/examples/orchestrating_agents>
- AutoGen multi-agent framework (arXiv 2308.08155). <https://arxiv.org/abs/2308.08155>
- AutoGen GroupChat docs. <https://microsoft.github.io/autogen/0.2/docs/Use-Cases/agent_chat/>
- AutoGen GAIA submission. <https://github.com/microsoft/autogen/tree/gaia_multiagent_v01_march_1st>
- MetaGPT (arXiv 2308.00352). <https://arxiv.org/abs/2308.00352>
- ChatDev (arXiv 2307.07924). <https://arxiv.org/abs/2307.07924>
- LbMAS (arXiv 2510.01285). <https://arxiv.org/abs/2510.01285>
- Liu et al. Blackboard MAS (arXiv 2507.01701). <https://arxiv.org/abs/2507.01701>
- Corkill — Blackboard Systems. <http://mas.cs.umass.edu/Documents/Corkill/ai-expert.pdf>
- MemGPT (arXiv 2310.08560). <https://arxiv.org/abs/2310.08560>
- Letta docs. <https://docs.letta.com/concepts/memgpt/>
- A-Mem (arXiv 2502.12110). <https://arxiv.org/pdf/2502.12110>
- LoCoMo (arXiv 2402.17753). <https://arxiv.org/abs/2402.17753>
- Du et al. Multi-Agent Debate (arXiv 2305.14325). <https://arxiv.org/abs/2305.14325>
- LLM-Blender (arXiv 2306.02561). <https://arxiv.org/abs/2306.02561>
- A-HMAD. <https://link.springer.com/article/10.1007/s44443-025-00353-3>
- Free-MAD. <https://arxiv.org/html/2509.11035v1>
- GroupDebate (arXiv 2409.14051). <https://arxiv.org/html/2409.14051>
- S²-MAD (arXiv 2502.04790). <https://arxiv.org/html/2502.04790v2>
- The Consensus Trap. <https://arxiv.org/html/2604.17139>
- Can LLM Agents Really Debate? <https://arxiv.org/pdf/2511.07784>
- AgentRR Record & Replay (arXiv 2505.17716). <https://arxiv.org/abs/2505.17716>
- Stateless Decision Memory (DPM). <https://arxiv.org/html/2604.20158>
- Why Do Multi-Agent LLM Systems Fail? / MAST (arXiv 2503.13657). <https://arxiv.org/abs/2503.13657>
- Galileo — Why multi-agent systems fail. <https://galileo.ai/blog/why-multi-agent-systems-fail>
- CAMEL (arXiv 2303.17760). <https://arxiv.org/abs/2303.17760>
- Memory-Augmented Agents survey / Agent-Memory-Paper-List. <https://github.com/Shichun-Liu/Agent-Memory-Paper-List>
