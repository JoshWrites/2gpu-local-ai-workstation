# Research Sources

Index of external sources cited in `docs/research/2026-04-2[45]-*.md`. Going forward, when you cite something new in a research doc, add it here in the same commit.

## How to read this file

- **Status legend**:
  - **read** -- primary source has been opened in conversation context (paper PDF read, repo source skimmed, docs page fetched verbatim).
  - **skimmed** -- opened, partial read, or only via web-fetch summary.
  - **cited-via-secondary** -- known only through a research agent's writeup; primary source not directly verified.
  - **unverified** -- citation appears in our docs but link/claim has not been independently checked.

  Default for retroactive entries is **cited-via-secondary**. Flip to **read** once verified.

- **Why it matters**: one sentence on what role the source plays in our research, not what the source itself is about.
- **Caveats**: only present when our existing docs explicitly note a dispute or limitation.

## Coverage statistics (initial population)

- **332 unique canonical sources** (deduped -- same paper cited via abs/pdf/html collapsed)
- **99 papers**, **68 GitHub repos**, **8 Hugging Face**, **157 web** (docs / blogs / writeups)
- **3 sources** verified as **read** (LCM paper, Hermes-LCM repo, SillyTavern Chat Vectorization docs)
- **29 sources** cited in >=2 research files -- annotated below
- **303 sources** cited in exactly one file -- listed flat in [Long tail](#long-tail) section with first-cited filename only

The long-tail entries are deliberately un-annotated. Annotating 300+ sources we read only via secondary agent summaries would invent context that isn't there. Promote individual entries to the annotated section when they become load-bearing.

---

## Curated: load-bearing sources (annotated)

Sources cited in >=2 research files OR discussed by name in working sessions today (2026-04-25). Sorted by topical cluster, not alphabetical, to make scanning useful.

### Verbatim-retrieval-vs-summary memory benchmarks

#### LongMemEval (Wu et al., ICLR 2025)
- **Citation:** `arXiv:2410.10813`
- **URL:** https://arxiv.org/abs/2410.10813
- **Project page:** https://xiaowu0162.github.io/long-mem-eval/
- **Repo:** https://github.com/xiaowu0162/LongMemEval
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`; also discussed in session-notes-full and conversation-notes
- **Status:** cited-via-secondary
- **Why it matters:** The load-bearing benchmark for our "verbatim wins" thesis -- the paper's ablation shows fine-grained verbatim session decomposition improves retrieval (+9.4% R@k, +5.4% accuracy with fact-augmented keys); also defines the state-vs-history query split that motivates V2 temporal routing.
- **Caveats:** The +12.4 R@5 verbatim-vs-summary headline is reported via MemPalace, whose methodology has been disputed; the qualitative direction is consistent with the LongMemEval paper's own ablations.

#### LoCoMo (Maharana et al., ACL 2024)
- **Citation:** `arXiv:2402.17753`
- **URL:** https://arxiv.org/abs/2402.17753
- **Project page:** https://snap-research.github.io/locomo/
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`; also session-state-architectures-survey, hobbyist-and-academic
- **Status:** cited-via-secondary
- **Why it matters:** Long-conversation benchmark used to compare retrieval-over-transcript against full-context and naive summaries; their result that "naive session summaries degrade factual recall" supports Pattern 1.
- **Caveats:** Mem0's reported 91.6 LoCoMo score is publicly disputed by Zep; the published numbers do not yet settle "verbatim-retrieval vs. fact-extraction" head-to-head at fixed token budget.

#### Mem0 research page
- **URL:** https://mem0.ai/research
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Production summary-extraction memory; their LoCoMo and LongMemEval numbers (91.6 / 93.4) are the comparator in every "is verbatim actually better?" argument we make.
- **Caveats:** Numbers contested -- see Zep "Lies, Damn Lies, Statistics" rebuttal.

#### Zep "Lies, Damn Lies, Statistics" rebuttal of Mem0
- **URL:** https://blog.getzep.com/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/
- **Companion issue:** https://github.com/getzep/zep-papers/issues/5
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** The reason we treat Mem0's LoCoMo numbers as contested rather than canonical.

### Verbatim-retrieval reference implementations

#### LCM paper (Ehrlich & Blackman, Voltropy, Feb 2026)
- **URL:** https://papers.voltropy.com/LCM
- **First cited:** discussed today (2026-04-25), not yet referenced in committed research files
- **Status:** **read** (PDF opened and read end-to-end on 2026-04-25)
- **Why it matters:** Strongest existing reference architecture for transcript+index. Defines deterministic engine-managed context management as a counter-paradigm to Zhang et al.'s RLM. Volt+LCM beats Claude Code v2.1.4 on OOLONG by +4.5 avg, gap widens at long context (+18.5 at 256K, +4.3 at 1M). DAG of summaries over verbatim leaves; three-level escalation guarantees compaction convergence; LLM-Map/Agentic-Map operator-level recursion replaces model-written loops. Section 2.1 explicitly flags embedding-index-over-summaries as unimplemented -- that's our wedge.
- **Caveats:** Benchmark is OOLONG aggregation, not memory recall; +29.2 over raw Opus 4.6 doesn't transfer cleanly to our supersession/state-vs-history use case.

#### Hermes-LCM repo (stephenschoettler/hermes-lcm)
- **Citation:** `gh:stephenschoettler/hermes-lcm`
- **URL:** https://github.com/stephenschoettler/hermes-lcm
- **Project landing:** https://hermesatlas.com/projects/stephenschoettler/hermes-lcm
- **Sibling impl:** https://github.com/martian-engineering/lossless-claw (OpenClaw equivalent)
- **First cited:** `04-25/hobbyist-and-academic-transcript-index-prior-art`
- **Status:** **read** (README and partial source review on 2026-04-25 -- tools.py, dag.py headers, store.py headers)
- **Why it matters:** Reference implementation of the LCM architecture as a Hermes Agent plugin. ~6300 lines Python, MIT, no external deps. Exposes `lcm_grep`/`lcm_describe`/`lcm_expand`/`lcm_expand_query` as model-callable tools mid-conversation. SQLite-backed FTS5; no embedding layer; single-card. The closest existing implementation of our reframings 9 + 10, but missing reframing 10's cross-card disposable-context piece.
- **Caveats:** Tied to Hermes Agent + PR #7464 pluggable-context-engine slot; we'd port the design rather than drop in code if we're staying llama.cpp-native.

#### MemGPT / Letta paper (Packer et al., 2023)
- **Citation:** `arXiv:2310.08560`
- **URL:** https://arxiv.org/abs/2310.08560
- **Productionized docs:** https://docs.letta.com/concepts/memgpt/, https://docs.letta.com/advanced/memory-management/
- **Repo:** https://github.com/letta-ai/letta
- **Research site:** https://research.memgpt.ai/
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`; also front-and-passenger-dispatcher, multi-model-handoff
- **Status:** cited-via-secondary
- **Why it matters:** The original "OS-style virtual context" memory paper; Letta's recall tier is the canonical production verbatim store with paged retrieval. Together with Claude memory tool, sets the prior art ceiling for cross-session verbatim -- but neither frames *current* session as the retrieval artifact (the scope shift our work tries to claim).

### Session-as-artifact / agent memory architectures

#### Generative Agents (Park et al., 2023)
- **Citation:** `arXiv:2304.03442`
- **URL:** https://arxiv.org/abs/2304.03442
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`; also hobbyist-and-academic
- **Status:** cited-via-secondary
- **Why it matters:** Full memory-stream + recency/relevance/importance retrieval scoring + reflection loop. Closest academic precedent for "verbatim store with structured retrieval." Applied to NPC simulation, not assistants -- the *form* is reusable, the *frame* is different.

#### A-MEM (Xu et al., 2025)
- **Citation:** `arXiv:2502.12110`
- **URL:** https://arxiv.org/abs/2502.12110
- **Repo:** https://github.com/agiresearch/A-mem
- **First cited:** `04-24/session-state-architectures-survey`; also hobbyist-and-academic
- **Status:** cited-via-secondary
- **Why it matters:** Agentic memory with eager LLM-enrichment per memory entry -- the "rich-immediately" extreme of the indexing-tier spectrum. Useful as a contrast to V0's "cheap-inline + rich-at-compaction" plan.

### Discourse / dialogue-act parsers (V2 indexer candidates)

#### DMRST (Liu et al., EMNLP-CODI 2021)
- **Repo:** https://github.com/seq-to-mind/DMRST_Parser
- **First cited:** `04-24/discourse-parser-survey`
- **Status:** cited-via-secondary
- **Why it matters:** Top-tier multilingual RST parser candidate; XLM-RoBERTa-base fits card 2 at FP16. Likely default candidate if we go with full RST.

#### IsaNLP RST (tchewik)
- **Repo:** https://github.com/tchewik/isanlp_rst
- **First cited:** `04-24/discourse-parser-survey`
- **Status:** cited-via-secondary
- **Why it matters:** Lowest-friction RST parser surveyed (Docker-first, MIT, multilingual, active in 2025-11). Best fit for "always-resident on card 2 or CPU."

#### Llamipa SDRT parser
- **Citation:** `arXiv:2406.18665`
- **URL:** https://arxiv.org/abs/2406.18665
- **First cited:** `04-24/discourse-parser-survey`
- **Status:** cited-via-secondary
- **Why it matters:** SDRT-trained dialogue parser -- better structural match for LLM-conversation indexing than RST parsers; integration bumpier.

#### MIDAS dialogue-act scheme
- **Citation:** `arXiv:1908.10023`
- **Repo:** https://github.com/DianDYu/MIDAS_dialog_act
- **First cited:** `04-24/discourse-parser-survey`
- **Status:** cited-via-secondary
- **Why it matters:** Best taxonomic match to our target tags -- explicitly designed for human-machine dialogue, includes correction / negative-answer leaves that map to `reversal` / `supersession`.

### Recency / temporal retrieval

#### Listwise reranker recency bias (Liu et al., SIGIR-AP 2025)
- **Citation:** `arXiv:2509.11353`
- **URL:** https://arxiv.org/abs/2509.11353
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** LLM rerankers systematically promote more-recent content (up to 95-rank shifts) even when the question is about an older decision -- the mechanical reason naive verbatim retrieval fails on supersession-sensitive queries. Direct motivation for V2 temporal routing.

#### TG-RAG (temporal knowledge graphs for RAG)
- **Citation:** `arXiv:2510.13590`
- **URL:** https://arxiv.org/abs/2510.13590
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Temporal-KG retrieval (timestamped relations + hierarchical time graph) -- the data-corpus analog of what we want for conversation; cited as evidence the ingredients for temporal routing exist separately.

### SillyTavern reference (hobbyist commodity layer)

#### SillyTavern Chat Vectorization docs
- **URL:** https://docs.sillytavern.app/extensions/chat-vectorization/
- **First cited:** `04-25/hobbyist-and-academic-transcript-index-prior-art`
- **Status:** **read** (WebFetch on 2026-04-25)
- **Why it matters:** Default-on, automatic per-message embedding of the *current chat* with verbatim spans injected at generation time. Means "verbatim in-session retrieval" is already commodity at the hobbyist layer -- pre-dates the commercial memory products. Forces us to drop the "industry overlooked verbatim" framing.

#### SillyTavern (root repo)
- **Repo:** https://github.com/SillyTavern/SillyTavern
- **First cited:** `04-25/hobbyist-and-academic-transcript-index-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** ~17k stars, AGPL-3.0, the dominant homelab front-end for local conversational LLMs and the host for the Chat Vectorization mechanism above.

### Multi-agent / dispatcher prior art (yesterday's reframing 3)

#### microsoft/autogen
- **Repo:** https://github.com/microsoft/autogen
- **First cited:** `04-24/front-and-passenger-dispatcher-prior-art`; 3 docs
- **Status:** cited-via-secondary
- **Why it matters:** Dispatcher-in-front reference implementation; also the basis for AutoGen -> MS Agent Framework migration discussed in compaction docs.

#### openai/swarm
- **Repo:** https://github.com/openai/swarm
- **First cited:** `04-24/front-and-passenger-dispatcher-prior-art`; 3 docs
- **Status:** cited-via-secondary
- **Why it matters:** OpenAI's reference handoff orchestration pattern; companion to the orchestrating-agents cookbook.

#### OpenAI orchestrating-agents cookbook
- **URL:** https://cookbook.openai.com/examples/orchestrating_agents
- **First cited:** `04-24/front-and-passenger-dispatcher-prior-art`; 4 docs (most-cited web source)
- **Status:** cited-via-secondary
- **Why it matters:** Canonical example of dispatcher-in-front + handoff pattern; the recipe most production multi-agent systems clone.

#### LLM-Blender (Jiang et al., ACL 2023)
- **Citation:** `arXiv:2306.02561`
- **URL:** https://arxiv.org/abs/2306.02561
- **Repo:** https://github.com/yuchenlin/LLM-Blender
- **First cited:** `04-24/multi-model-handoff-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Reference for ranked-ensemble multi-model output combination -- comes up whenever someone asks "why not just run all the models and pick the best."

#### MetaGPT (Hong et al., 2023)
- **Citation:** `arXiv:2308.00352`
- **URL:** https://arxiv.org/abs/2308.00352
- **First cited:** `04-24/front-and-passenger-dispatcher-prior-art`; 3 docs
- **Status:** cited-via-secondary
- **Why it matters:** Standard dispatcher-with-roles citation in agent-orchestration literature.

#### AutoGen (Wu et al., 2023)
- **Citation:** `arXiv:2308.08155`
- **URL:** https://arxiv.org/abs/2308.08155
- **First cited:** `04-24/multi-model-handoff-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Original AutoGen paper -- pairs with the autogen repo above.

#### NVIDIA Orchestrator-8B small-model paper
- **Citation:** `arXiv:2403.12031`
- **URL:** https://arxiv.org/abs/2403.12031
- **First cited:** `04-24/front-and-passenger-dispatcher-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** The one production system in our survey that *did* RL-train a model to be the orchestrator. Cited as the exception that confirms "every other surveyed system is Python+LLM-subroutines."

#### LLM-Router (NVIDIA Blueprint)
- **Repo:** https://github.com/NVIDIA-AI-Blueprints/llm-router
- **First cited:** `04-24/front-and-passenger-dispatcher-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Reference best-fit-routing implementation; sample design we contrasted against the curation-not-runtime framing in reframing 6.

#### RouteLLM (Ong et al.)
- **Citation:** `arXiv:2503.13657`
- **URL:** https://arxiv.org/abs/2503.13657
- **Repo:** https://github.com/lm-sys/RouteLLM
- **Blog:** https://www.lmsys.org/blog/2024-07-01-routellm/
- **First cited:** `04-24/multi-model-handoff-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Cost-quality routing via classifier -- the model-side mirror of our quarterly admin-curation approach.

#### langgraph-supervisor-py
- **Repo:** https://github.com/langchain-ai/langgraph-supervisor-py
- **First cited:** `04-24/front-and-passenger-dispatcher-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** LangGraph supervisor pattern -- dispatcher-in-front with hierarchical agent teams.

#### Anthropic multi-agent research-system writeup
- **URL:** https://www.anthropic.com/engineering/multi-agent-research-system
- **First cited:** `04-24/front-and-passenger-dispatcher-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** First-party Anthropic engineering account of how the research-system feature is structured -- concrete reference for production multi-agent at scale.

### Persistence / serving infrastructure (yesterday's swap-cost research)

#### llama.cpp
- **Repo:** https://github.com/ggml-org/llama.cpp
- **First cited:** `04-24/session-persistence-and-reassembly-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** The runtime we're actually building on. Slot save/restore behavior, llama-server router quirks, and embedding-model GGUF support all flow from this repo.

#### Hermes Agent (NousResearch)
- **Repo:** https://github.com/NousResearch/hermes-agent
- **First cited:** `04-24/session-persistence-and-reassembly-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** The host runtime Hermes-LCM plugs into; PR #7464 introduces the pluggable-context-engine slot LCM uses.

### Late-arriving sources discussed today

#### Junie CLI (JetBrains coding agent)
- **URL:** https://memu.pro/blog/junie-cli-model-agnostic-coding-memory
- **First cited:** `04-24/multi-model-handoff-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Engineering writeup on a model-agnostic coding agent -- surfaced in handoff research as a non-academic example of the pattern.

#### MemoryLLM (arXiv:2504.19413)
- **URL:** https://arxiv.org/abs/2504.19413
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Self-updatable memory in transformer parameters -- the "memory-in-weights" extreme on the spectrum.

#### Listwise/temporal-RAG follow-up (arXiv:2510.09720)
- **URL:** https://arxiv.org/abs/2510.09720
- **First cited:** `04-24/discourse-parser-survey`
- **Status:** cited-via-secondary
- **Why it matters:** Mentioned across the parser and retrieval surveys; specific role unclear from secondary context -- promote with annotation when first read.

#### Recent temporal-retrieval paper (arXiv:2512.12686)
- **URL:** https://arxiv.org/abs/2512.12686
- **First cited:** `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- **Status:** cited-via-secondary
- **Why it matters:** Cited twice in the temporal-retrieval prior-art doc; specific role unclear from secondary context -- promote with annotation when first read.

---

## Long tail

303 sources cited in exactly one research file. Listed flat; promote individual entries to the curated section above when they become load-bearing. First-cited filename only -- no annotation, since these have not been independently verified.

### Papers (83 entries, single-citation tail)

- [`acl:2024.acl-long.747.pdf`](https://aclanthology.org/2024.acl-long.747.pdf) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`acl:2024.findings-acl.826`](https://aclanthology.org/2024.findings-acl.826/) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`acl:2024.lrec-main.11`](https://aclanthology.org/2024.lrec-main.11/) -- `04-24/discourse-parser-survey`
- [`acl:2025.disrpt-1.pdf`](https://aclanthology.org/2025.disrpt-1.pdf) -- `04-24/discourse-parser-survey`
- [`acl:2025.emnlp-main.1657.pdf`](https://aclanthology.org/2025.emnlp-main.1657.pdf) -- `04-24/discourse-parser-survey`
- [`acl:2025.tacl-1.26.pdf`](https://aclanthology.org/2025.tacl-1.26.pdf) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:1908.10023`](https://arxiv.org/abs/1908.10023) -- `04-24/discourse-parser-survey`
- [`arXiv:2108.06314`](https://arxiv.org/abs/2108.06314) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`arXiv:2207.07061`](https://arxiv.org/abs/2207.07061) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2211.17192`](https://arxiv.org/abs/2211.17192) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2212.08073`](https://arxiv.org/abs/2212.08073) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2302.07863`](https://arxiv.org/abs/2302.07863) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2303.11366`](https://arxiv.org/abs/2303.11366) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2303.17580`](https://arxiv.org/abs/2303.17580) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2303.17651`](https://arxiv.org/abs/2303.17651) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2303.17760`](https://arxiv.org/abs/2303.17760) -- `04-24/session-state-architectures-survey`
- [`arXiv:2304.13343`](https://arxiv.org/abs/2304.13343) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2305.05176`](https://arxiv.org/abs/2305.05176) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2305.10250`](https://arxiv.org/abs/2305.10250) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2305.11738`](https://arxiv.org/abs/2305.11738) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2305.14322`](https://arxiv.org/abs/2305.14322) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2305.14325`](https://arxiv.org/abs/2305.14325) -- `04-24/session-state-architectures-survey`
- [`arXiv:2306.13063`](https://arxiv.org/abs/2306.13063) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2307.07924`](https://arxiv.org/abs/2307.07924) -- `04-24/session-state-architectures-survey`
- [`arXiv:2308.08239`](https://arxiv.org/abs/2308.08239) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2309.00267`](https://arxiv.org/abs/2309.00267) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2309.06180`](https://arxiv.org/abs/2309.06180) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2310.01798`](https://arxiv.org/abs/2310.01798) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2310.05736`](https://arxiv.org/abs/2310.05736) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2310.12963`](https://arxiv.org/abs/2310.12963) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2310.14970`](https://arxiv.org/abs/2310.14970) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`arXiv:2311.09144`](https://arxiv.org/abs/2311.09144) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2311.18702`](https://arxiv.org/abs/2311.18702) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2312.07104`](https://arxiv.org/abs/2312.07104) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2402.08644`](https://arxiv.org/abs/2402.08644) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2402.10962`](https://arxiv.org/abs/2402.10962) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2403.05065`](https://arxiv.org/abs/2403.05065) -- `04-24/discourse-parser-survey`
- [`arXiv:2404.11672`](https://arxiv.org/abs/2404.11672) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2404.14618`](https://arxiv.org/abs/2404.14618) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2405.13037`](https://arxiv.org/abs/2405.13037) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`arXiv:2405.14831`](https://arxiv.org/abs/2405.14831) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2406.04692`](https://arxiv.org/abs/2406.04692) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2406.18256`](https://arxiv.org/abs/2406.18256) -- `04-24/discourse-parser-survey`
- [`arXiv:2407.02348`](https://arxiv.org/abs/2407.02348) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2407.18418`](https://arxiv.org/abs/2407.18418) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2409.14051`](https://arxiv.org/abs/2409.14051) -- `04-24/session-state-architectures-survey`
- [`arXiv:2410.10347`](https://arxiv.org/abs/2410.10347) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2411.00491`](https://arxiv.org/abs/2411.00491) -- `04-24/discourse-parser-survey`
- [`arXiv:2411.04468`](https://arxiv.org/abs/2411.04468) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2411.15287`](https://arxiv.org/abs/2411.15287) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2501.13956`](https://arxiv.org/abs/2501.13956) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`arXiv:2501.14312`](https://arxiv.org/abs/2501.14312) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2502.00674`](https://arxiv.org/abs/2502.00674) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2502.04790`](https://arxiv.org/abs/2502.04790) -- `04-24/session-state-architectures-survey`
- [`arXiv:2502.19335`](https://arxiv.org/abs/2502.19335) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2503.10657`](https://arxiv.org/abs/2503.10657) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2503.16024`](https://arxiv.org/abs/2503.16024) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2503.21295`](https://arxiv.org/abs/2503.21295) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2505.06120`](https://arxiv.org/abs/2505.06120) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2505.17716`](https://arxiv.org/abs/2505.17716) -- `04-24/session-state-architectures-survey`
- [`arXiv:2506.09038`](https://arxiv.org/abs/2506.09038) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2506.16383`](https://arxiv.org/abs/2506.16383) -- `04-24/discourse-parser-survey`
- [`arXiv:2507.01701`](https://arxiv.org/abs/2507.01701) -- `04-24/session-state-architectures-survey`
- [`arXiv:2507.16731`](https://arxiv.org/abs/2507.16731) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2507.22925`](https://arxiv.org/abs/2507.22925) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2508.01739`](https://arxiv.org/abs/2508.01739) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`arXiv:2508.19461`](https://arxiv.org/abs/2508.19461) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2509.11035`](https://arxiv.org/abs/2509.11035) -- `04-24/session-state-architectures-survey`
- [`arXiv:2509.16903`](https://arxiv.org/abs/2509.16903) -- `04-24/discourse-parser-survey`
- [`arXiv:2509.19376`](https://arxiv.org/abs/2509.19376) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`arXiv:2510.00615`](https://arxiv.org/abs/2510.00615) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`arXiv:2510.01285`](https://arxiv.org/abs/2510.01285) -- `04-24/session-state-architectures-survey`
- [`arXiv:2510.03437`](https://arxiv.org/abs/2510.03437) -- `04-24/discourse-parser-survey`
- [`arXiv:2510.07505`](https://arxiv.org/abs/2510.07505) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2510.24803`](https://arxiv.org/abs/2510.24803) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2511.07784`](https://arxiv.org/abs/2511.07784) -- `04-24/session-state-architectures-survey`
- [`arXiv:2511.17208`](https://arxiv.org/abs/2511.17208) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2601.03236`](https://arxiv.org/abs/2601.03236) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`arXiv:2602.03708`](https://arxiv.org/abs/2602.03708) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`arXiv:2603.09985`](https://arxiv.org/abs/2603.09985) -- `04-24/multi-model-handoff-prior-art`
- [`arXiv:2604.02431`](https://arxiv.org/abs/2604.02431) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`arXiv:2604.17139`](https://arxiv.org/abs/2604.17139) -- `04-24/session-state-architectures-survey`
- [`arXiv:2604.20158`](https://arxiv.org/abs/2604.20158) -- `04-24/session-state-architectures-survey`

### Repositories (49 entries, single-citation tail)

- [`gh:Coneja-Chibi/TunnelVision`](https://github.com/Coneja-Chibi/TunnelVision) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:DianDYu/MIDAS_dialog_act`](https://github.com/DianDYu/MIDAS_dialog_act) -- `04-24/discourse-parser-survey`
- [`gh:IAAR-Shanghai/Awesome-AI-Memory`](https://github.com/IAAR-Shanghai/Awesome-AI-Memory) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:InspectorCaracal/SillyTavern-ReMemory`](https://github.com/InspectorCaracal/SillyTavern-ReMemory) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:KoboldAI/KoboldAI-Client`](https://github.com/KoboldAI/KoboldAI-Client) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:LMCache/LMCache`](https://github.com/LMCache/LMCache) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`gh:LostRuins/koboldcpp`](https://github.com/LostRuins/koboldcpp) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:MemPalace/mempalace`](https://github.com/MemPalace/mempalace) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`gh:Mintplex-Labs/anything-llm`](https://github.com/Mintplex-Labs/anything-llm) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:Shichun-Liu/Agent-Memory-Paper-List`](https://github.com/Shichun-Liu/Agent-Memory-Paper-List) -- `04-24/session-state-architectures-survey`
- [`gh:SillyTavern/SillyTavern-Extras`](https://github.com/SillyTavern/SillyTavern-Extras) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:YenRaven/annoy_ltm`](https://github.com/YenRaven/annoy_ltm) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:aikohanasaki/SillyTavern-MemoryBooks`](https://github.com/aikohanasaki/SillyTavern-MemoryBooks) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:aistairc/conversational-grounding-llm`](https://github.com/aistairc/conversational-grounding-llm) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`gh:automix-llm/automix`](https://github.com/automix-llm/automix) -- `04-24/multi-model-handoff-prior-art`
- [`gh:bal-spec/sillytavern-character-memory`](https://github.com/bal-spec/sillytavern-character-memory) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:crewAIInc/crewAI`](https://github.com/crewAIInc/crewAI) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`gh:deadbranch-forks/TunnelVision-sillytavernyp`](https://github.com/deadbranch-forks/TunnelVision-sillytavernyp) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:dottxt-ai/outlines`](https://github.com/dottxt-ai/outlines) -- `04-24/discourse-parser-survey`
- [`gh:eth-sri/cascade-routing`](https://github.com/eth-sri/cascade-routing) -- `04-24/multi-model-handoff-prior-art`
- [`gh:facebookresearch/AbstentionBench`](https://github.com/facebookresearch/AbstentionBench) -- `04-24/multi-model-handoff-prior-art`
- [`gh:google-gemini/gemini-cli`](https://github.com/google-gemini/gemini-cli) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`gh:huggingface/text-embeddings-inference`](https://github.com/huggingface/text-embeddings-inference) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:kcolemangt/llm-router`](https://github.com/kcolemangt/llm-router) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`gh:kissg96/arkhon_memory_st_archive`](https://github.com/kissg96/arkhon_memory_st_archive) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:kssteven418/BigLittleDecoder`](https://github.com/kssteven418/BigLittleDecoder) -- `04-24/multi-model-handoff-prior-art`
- [`gh:langchain-ai/langgraph-swarm-py`](https://github.com/langchain-ai/langgraph-swarm-py) -- `04-24/session-state-architectures-survey`
- [`gh:likenneth/persona_drift`](https://github.com/likenneth/persona_drift) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`gh:mostlygeek/llama-swap`](https://github.com/mostlygeek/llama-swap) -- `04-24/multi-model-handoff-prior-art`
- [`gh:multi-agent-systems-failure-taxonomy/MAST`](https://github.com/multi-agent-systems-failure-taxonomy/MAST) -- `04-24/multi-model-handoff-prior-art`
- [`gh:noahshinn/reflexion`](https://github.com/noahshinn/reflexion) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`gh:nttcslab-nlp/RSTParser_EACL24`](https://github.com/nttcslab-nlp/RSTParser_EACL24) -- `04-24/discourse-parser-survey`
- [`gh:nttcslab-nlp/Top-Down-RST-Parser`](https://github.com/nttcslab-nlp/Top-Down-RST-Parser) -- `04-24/discourse-parser-survey`
- [`gh:ollama/ollama`](https://github.com/ollama/ollama) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:oobabooga/text-generation-webui`](https://github.com/oobabooga/text-generation-webui) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:open-webui/open-webui`](https://github.com/open-webui/open-webui) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:raine/claude-history`](https://github.com/raine/claude-history) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:sebastianruder/NLP-progress`](https://github.com/sebastianruder/NLP-progress) -- `04-24/discourse-parser-survey`
- [`gh:seq-to-mind/DDP_parsing`](https://github.com/seq-to-mind/DDP_parsing) -- `04-24/discourse-parser-survey`
- [`gh:seq-to-mind/DMRST_Parser`](https://github.com/seq-to-mind/DMRST_Parser) -- `04-24/discourse-parser-survey`
- [`gh:tchewik/isanlp_rst`](https://github.com/tchewik/isanlp_rst) -- `04-24/discourse-parser-survey`
- [`gh:theubie/complex_memory`](https://github.com/theubie/complex_memory) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:topics/discourse-parsing`](https://github.com/topics/discourse-parsing) -- `04-24/discourse-parser-survey`
- [`gh:underlines/awesome-ml`](https://github.com/underlines/awesome-ml) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:vllm-project/speculators`](https://github.com/vllm-project/speculators) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`gh:wawawario2/long_term_memory`](https://github.com/wawawario2/long_term_memory) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`gh:wenzhe-li/Self-MoA`](https://github.com/wenzhe-li/Self-MoA) -- `04-24/multi-model-handoff-prior-art`
- [`gh:whiteducksoftware/flock`](https://github.com/whiteducksoftware/flock) -- `04-24/session-state-architectures-survey`
- [`gh:yuchenlin/LLM-Blender`](https://github.com/yuchenlin/LLM-Blender) -- `04-24/multi-model-handoff-prior-art`

### Hugging Face (8 entries, single-citation tail)

- [`hf:Qwen/Qwen2.5-7B-Instruct-GGUF`](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF) -- `04-24/discourse-parser-survey`
- [`hf:aisingapore/RST-pointer`](https://huggingface.co/aisingapore/RST-pointer) -- `04-24/discourse-parser-survey`
- [`hf:blog/continuous_batching`](https://huggingface.co/blog/continuous_batching) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`hf:datasets/silicone`](https://huggingface.co/datasets/silicone) -- `04-24/discourse-parser-survey`
- [`hf:datasets/swda`](https://huggingface.co/datasets/swda) -- `04-24/discourse-parser-survey`
- [`hf:docs/text-embeddings-inference/index`](https://huggingface.co/docs/text-embeddings-inference/index) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`hf:docs/text-generation-inference/en/conceptual/paged_attention`](https://huggingface.co/docs/text-generation-inference/en/conceptual/paged_attention) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`hf:docs/transformers/kv_cache`](https://huggingface.co/docs/transformers/kv_cache) -- `04-24/session-persistence-and-reassembly-prior-art`

### Web (docs / blogs / writeups) (139 entries, single-citation tail)

- [`http://mas.cs.umass.edu/Documents/Corkill/ai-expert.pdf`](http://mas.cs.umass.edu/Documents/Corkill/ai-expert.pdf) -- `04-24/session-state-architectures-survey`
- [`https://adam-rida.medium.com/temporal-augmented-retrieval-tar-dynamic-rag-ad737506dfcc`](https://adam-rida.medium.com/temporal-augmented-retrieval-tar-dynamic-rag-ad737506dfcc) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://aider.chat/2024/09/26/architect.html`](https://aider.chat/2024/09/26/architect.html) -- `04-24/multi-model-handoff-prior-art`
- [`https://aider.chat/docs/usage/modes.html`](https://aider.chat/docs/usage/modes.html) -- `04-24/multi-model-handoff-prior-art`
- [`https://akka.io/blog/event-sourcing-the-backbone-of-agentic-ai`](https://akka.io/blog/event-sourcing-the-backbone-of-agentic-ai) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://arize.com/blog/orchestrator-worker-agents-a-practical-comparison-of-common-agent-frameworks/`](https://arize.com/blog/orchestrator-worker-agents-a-practical-comparison-of-common-agent-frameworks/) -- `04-24/multi-model-handoff-prior-art`
- [`https://asycd.medium.com/timestamped-embeddings-for-time-aware-retrieval-augmented-generation-rag-32dd9fb540ff`](https://asycd.medium.com/timestamped-embeddings-for-time-aware-retrieval-augmented-generation-rag-32dd9fb540ff) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://bentoml.com/llm/inference-optimization/kv-cache-offloading`](https://bentoml.com/llm/inference-optimization/kv-cache-offloading) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://bentoml.com/llm/inference-optimization/speculative-decoding`](https://bentoml.com/llm/inference-optimization/speculative-decoding) -- `04-24/multi-model-handoff-prior-art`
- [`https://blog.getzep.com/content/files/2025/01/ZEP__USING_KNOWLEDGE_GRAPHS_TO_POWER_LLM_AGENT_MEMORY_2025011700.pdf`](https://blog.getzep.com/content/files/2025/01/ZEP__USING_KNOWLEDGE_GRAPHS_TO_POWER_LLM_AGENT_MEMORY_2025011700.pdf) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://blog.jetbrains.com/junie/2026/03/junie-cli-the-llm-agnostic-coding-agent-is-now-in-beta/`](https://blog.jetbrains.com/junie/2026/03/junie-cli-the-llm-agnostic-coding-agent-is-now-in-beta/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://blog.langchain.com/command-a-new-tool-for-multi-agent-architectures-in-langgraph/`](https://blog.langchain.com/command-a-new-tool-for-multi-agent-architectures-in-langgraph/) -- `04-24/session-state-architectures-survey`
- [`https://blog.langchain.com/plan-and-execute-agents/`](https://blog.langchain.com/plan-and-execute-agents/) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://blog.lmcache.ai/2025-01-21-stack-release/`](https://blog.lmcache.ai/2025-01-21-stack-release/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://blog.vllm.ai/2024/10/17/spec-decode.html`](https://blog.vllm.ai/2024/10/17/spec-decode.html) -- `04-24/multi-model-handoff-prior-art`
- [`https://ceph.io/en/news/blog/2025/vllm-kv-caching/`](https://ceph.io/en/news/blog/2025/vllm-kv-caching/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://chaochunhsu.github.io/patterns/blogs/tei_qdrant_cache/`](https://chaochunhsu.github.io/patterns/blogs/tei_qdrant_cache/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them`](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them) -- `04-24/session-state-architectures-survey`
- [`https://claudefa.st/blog/guide/mechanics/session-memory`](https://claudefa.st/blog/guide/mechanics/session-memory) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://code.claude.com/docs/en/agent-teams`](https://code.claude.com/docs/en/agent-teams) -- `04-24/session-state-architectures-survey`
- [`https://community.crewai.com/t/does-hierarchical-process-even-work-your-experience-is-highly-appreciated/2690`](https://community.crewai.com/t/does-hierarchical-process-even-work-your-experience-is-highly-appreciated/2690) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://convokit.cornell.edu/documentation/switchboard.html`](https://convokit.cornell.edu/documentation/switchboard.html) -- `04-24/discourse-parser-survey`
- [`https://deepwiki.com/SillyTavern/SillyTavern/6-context-and-memory-systems`](https://deepwiki.com/SillyTavern/SillyTavern/6-context-and-memory-systems) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://deepwiki.com/SillyTavern/SillyTavern/6.3-vector-storage-and-rag-system`](https://deepwiki.com/SillyTavern/SillyTavern/6.3-vector-storage-and-rag-system) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://deepwiki.com/lmstudio-ai/docs/8.3-retrieval-augmented-generation-(rag`](https://deepwiki.com/lmstudio-ai/docs/8.3-retrieval-augmented-generation-(rag) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://deepwiki.com/open-webui/open-webui/5.4-hybrid-retrieval-strategies`](https://deepwiki.com/open-webui/open-webui/5.4-hybrid-retrieval-strategies) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://deepwiki.com/open-webui/open-webui/6.4-memory-and-context-management`](https://deepwiki.com/open-webui/open-webui/6.4-memory-and-context-management) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://dev.to/focused_dot_io/multi-agent-orchestration-in-langgraph-supervisor-vs-swarm-tradeoffs-and-architecture-1b7e`](https://dev.to/focused_dot_io/multi-agent-orchestration-in-langgraph-supervisor-vs-swarm-tradeoffs-and-architecture-1b7e) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://dev.to/isaachagoel/why-llm-memory-still-fails-a-field-guide-for-builders-3d78`](https://dev.to/isaachagoel/why-llm-memory-still-fails-a-field-guide-for-builders-3d78) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://dev.to/rituparnaghosh/what-i-learned-parsing-transcripts-into-hindsight-1c07`](https://dev.to/rituparnaghosh/what-i-learned-parsing-transcripts-into-hindsight-1c07) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://dev.to/rushichaudhari/training-llms-on-mixed-gpus-my-experiments-and-what-i-learnt-1k7n`](https://dev.to/rushichaudhari/training-llms-on-mixed-gpus-my-experiments-and-what-i-learnt-1k7n) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://developer.nvidia.com/blog/introducing-new-kv-cache-reuse-optimizations-in-nvidia-tensorrt-llm/`](https://developer.nvidia.com/blog/introducing-new-kv-cache-reuse-optimizations-in-nvidia-tensorrt-llm/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://developer.nvidia.com/blog/optimizing-inference-for-long-context-and-large-batch-sizes-with-nvfp4-kv-cache/`](https://developer.nvidia.com/blog/optimizing-inference-for-long-context-and-large-batch-sizes-with-nvfp4-kv-cache/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://developer.nvidia.com/blog/train-small-orchestration-agents-to-solve-big-problems/`](https://developer.nvidia.com/blog/train-small-orchestration-agents-to-solve-big-problems/) -- `04-24/multi-model-handoff-prior-art`
- [`https://developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/`](https://developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://developers.redhat.com/articles/2025/10/07/master-kv-cache-aware-routing-llm-d-efficient-ai-inference`](https://developers.redhat.com/articles/2025/10/07/master-kv-cache-aware-routing-llm-d-efficient-ai-inference) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://dl.acm.org/doi/10.1145/3662006.3662067`](https://dl.acm.org/doi/10.1145/3662006.3662067) -- `04-24/multi-model-handoff-prior-art`
- [`https://docs.letta.com/advanced/memory-management/`](https://docs.letta.com/advanced/memory-management/) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://docs.letta.com/guides/agents/memory/`](https://docs.letta.com/guides/agents/memory/) -- `04-24/session-state-architectures-survey`
- [`https://docs.msty.studio/features/knowledge-stacks/next-gen`](https://docs.msty.studio/features/knowledge-stacks/next-gen) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://docs.msty.studio/features/knowledge-stacks/overview`](https://docs.msty.studio/features/knowledge-stacks/overview) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://docs.openwebui.com/features/chat-conversations/memory/`](https://docs.openwebui.com/features/chat-conversations/memory/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://docs.openwebui.com/features/chat-conversations/rag/`](https://docs.openwebui.com/features/chat-conversations/rag/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://docs.sglang.io/docs/advanced_features/hicache_design`](https://docs.sglang.io/docs/advanced_features/hicache_design) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://docs.sillytavern.app/extensions/summarize/`](https://docs.sillytavern.app/extensions/summarize/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://docs.vllm.ai/en/latest/features/spec_decode/`](https://docs.vllm.ai/en/latest/features/spec_decode/) -- `04-24/multi-model-handoff-prior-art`
- [`https://docs.vllm.ai/en/stable/design/prefix_caching/`](https://docs.vllm.ai/en/stable/design/prefix_caching/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://docs.vllm.ai/en/v0.8.2/features/structured_outputs.html`](https://docs.vllm.ai/en/v0.8.2/features/structured_outputs.html) -- `04-24/discourse-parser-survey`
- [`https://forum.level1techs.com/t/dual-gpu-7900xtx-vfio-ollama-llm-bad-scaling/229768`](https://forum.level1techs.com/t/dual-gpu-7900xtx-vfio-ollama-llm-bad-scaling/229768) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://forum.level1techs.com/t/today-i-discovered-llama-cpp-router-mode/244060`](https://forum.level1techs.com/t/today-i-discovered-llama-cpp-router-mode/244060) -- `04-24/multi-model-handoff-prior-art`
- [`https://forums.developer.nvidia.com/t/triton-tensorrt-llm-llama-3-1-8b-feasibility-of-stateful-serving-kv-cache-reuse-priority-caching/343960`](https://forums.developer.nvidia.com/t/triton-tensorrt-llm-llama-3-1-8b-feasibility-of-stateful-serving-kv-cache-reuse-priority-caching/343960) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://galileo.ai/blog/architectures-for-multi-agent-systems`](https://galileo.ai/blog/architectures-for-multi-agent-systems) -- `04-24/session-state-architectures-survey`
- [`https://galileo.ai/blog/multi-agent-llm-systems-fail`](https://galileo.ai/blog/multi-agent-llm-systems-fail) -- `04-24/multi-model-handoff-prior-art`
- [`https://galileo.ai/blog/why-multi-agent-systems-fail`](https://galileo.ai/blog/why-multi-agent-systems-fail) -- `04-24/session-state-architectures-survey`
- [`https://github.com/ggml-org/llama.cpp/discussions/15396`](https://github.com/ggml-org/llama.cpp/discussions/15396) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://github.com/ggml-org/llama.cpp/discussions/22411`](https://github.com/ggml-org/llama.cpp/discussions/22411) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://github.com/ggml-org/llama.cpp/issues/15120`](https://github.com/ggml-org/llama.cpp/issues/15120) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://github.com/ggml-org/llama.cpp/issues/17527`](https://github.com/ggml-org/llama.cpp/issues/17527) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://github.com/ggml-org/llama.cpp/pull/15293`](https://github.com/ggml-org/llama.cpp/pull/15293) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://healthark.ai/persistent-memory-for-llms-designing-a-multi-tier-context-system/`](https://healthark.ai/persistent-memory-for-llms-designing-a-multi-tier-context-system/) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide`](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://hungleai.substack.com/p/agree-or-disagree-a-review-of-multi`](https://hungleai.substack.com/p/agree-or-disagree-a-review-of-multi) -- `04-24/session-state-architectures-survey`
- [`https://junie.jetbrains.com/docs/guidelines-and-memory.html`](https://junie.jetbrains.com/docs/guidelines-and-memory.html) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://klu.ai/glossary/humaneval-benchmark`](https://klu.ai/glossary/humaneval-benchmark) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://langchain-ai.github.io/langgraph/concepts/multi_agent/`](https://langchain-ai.github.io/langgraph/concepts/multi_agent/) -- `04-24/session-state-architectures-survey`
- [`https://langchain-ai.github.io/langgraph/tutorials/multi_agent/hierarchical_agent_teams/`](https://langchain-ai.github.io/langgraph/tutorials/multi_agent/hierarchical_agent_teams/) -- `04-24/session-state-architectures-survey`
- [`https://langchain-doc.readthedocs.io/en/latest/modules/memory/types/summary_buffer.html`](https://langchain-doc.readthedocs.io/en/latest/modules/memory/types/summary_buffer.html) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://learn.microsoft.com/en-us/agent-framework/migration-guide/from-autogen/`](https://learn.microsoft.com/en-us/agent-framework/migration-guide/from-autogen/) -- `04-24/session-state-architectures-survey`
- [`https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables`](https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://link.springer.com/article/10.1007/s44443-025-00353-3`](https://link.springer.com/article/10.1007/s44443-025-00353-3) -- `04-24/session-state-architectures-survey`
- [`https://link.springer.com/chapter/10.1007/978-3-031-98417-4_9`](https://link.springer.com/chapter/10.1007/978-3-031-98417-4_9) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://llm-d.ai/blog/kvcache-wins-you-can-see`](https://llm-d.ai/blog/kvcache-wins-you-can-see) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://lmcache.ai/tech_report.pdf`](https://lmcache.ai/tech_report.pdf) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://lmstudio.ai/docs/app/basics/rag`](https://lmstudio.ai/docs/app/basics/rag) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://medium.com/@michael.hannecke/the-model-router-running-a-team-of-local-llms-instead-of-one-big-one-fd75eeec9d39`](https://medium.com/@michael.hannecke/the-model-router-running-a-team-of-local-llms-instead-of-one-big-one-fd75eeec9d39) -- `04-24/multi-model-handoff-prior-art`
- [`https://mem0.ai/blog/mem0-the-token-efficient-memory-algorithm`](https://mem0.ai/blog/mem0-the-token-efficient-memory-algorithm) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://microsoft.github.io/autogen/0.2/docs/Use-Cases/agent_chat/`](https://microsoft.github.io/autogen/0.2/docs/Use-Cases/agent_chat/) -- `04-24/session-state-architectures-survey`
- [`https://minihf.com/posts/2025-07-22-on-chatgpt-psychosis-and-llm-sycophancy/`](https://minihf.com/posts/2025-07-22-on-chatgpt-psychosis-and-llm-sycophancy/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://mrmaheshrajput.medium.com/i-reverse-engineered-how-cursor-copilot-actually-work-ce0a6a7f1838`](https://mrmaheshrajput.medium.com/i-reverse-engineered-how-cursor-copilot-actually-work-ce0a6a7f1838) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://news.ycombinator.com/item?id=35944203`](https://news.ycombinator.com/item?id=35944203) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://news.ycombinator.com/item?id=46252809`](https://news.ycombinator.com/item?id=46252809) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://nimblebrain.ai/why-ai-fails/agent-governance/agent-failure-modes/`](https://nimblebrain.ai/why-ai-fails/agent-governance/agent-failure-modes/) -- `04-24/session-state-architectures-survey`
- [`https://nvidia.github.io/TensorRT-LLM/advanced/kv-cache-reuse.html`](https://nvidia.github.io/TensorRT-LLM/advanced/kv-cache-reuse.html) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://ojs.aaai.org/index.php/AAAI/article/view/29946`](https://ojs.aaai.org/index.php/AAAI/article/view/29946) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://olav.ninja/adding-ai-to-my-homelab-with-an-egpu`](https://olav.ninja/adding-ai-to-my-homelab-with-an-egpu) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://open-webui.com/open-webui-adaptive-memory/`](https://open-webui.com/open-webui-adaptive-memory/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://openai.github.io/openai-agents-python/context/`](https://openai.github.io/openai-agents-python/context/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://openai.github.io/openai-agents-python/handoffs/`](https://openai.github.io/openai-agents-python/handoffs/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://openreview.net/forum?id=02f3mUtqnM`](https://openreview.net/forum?id=02f3mUtqnM) -- `04-24/multi-model-handoff-prior-art`
- [`https://openreview.net/forum?id=46jbtZZWen`](https://openreview.net/forum?id=46jbtZZWen) -- `04-24/session-state-architectures-survey`
- [`https://openreview.net/pdf/109c600393cc962e64028e8425eca62778f40ee9.pdf`](https://openreview.net/pdf/109c600393cc962e64028e8425eca62778f40ee9.pdf) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://particula.tech/blog/langgraph-vs-crewai-vs-openai-agents-sdk-2026`](https://particula.tech/blog/langgraph-vs-crewai-vs-openai-agents-sdk-2026) -- `04-24/multi-model-handoff-prior-art`
- [`https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool`](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://proceedings.neurips.cc/paper_files/paper/2024/file/ecda225cb187b40ea8edc1f46b03ffda-Paper-Conference.pdf`](https://proceedings.neurips.cc/paper_files/paper/2024/file/ecda225cb187b40ea8edc1f46b03ffda-Paper-Conference.pdf) -- `04-24/multi-model-handoff-prior-art`
- [`https://pypi.org/project/discoursegraphs/`](https://pypi.org/project/discoursegraphs/) -- `04-24/discourse-parser-survey`
- [`https://python.langchain.com/api_reference/langchain/memory/langchain.memory.buffer.ConversationBufferMemory.html`](https://python.langchain.com/api_reference/langchain/memory/langchain.memory.buffer.ConversationBufferMemory.html) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://python.useinstructor.com/`](https://python.useinstructor.com/) -- `04-24/discourse-parser-survey`
- [`https://qubittool.com/blog/ai-agent-framework-comparison-2026`](https://qubittool.com/blog/ai-agent-framework-comparison-2026) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://research.google/blog/accelerating-text-generation-with-confident-adaptive-language-modeling-calm/`](https://research.google/blog/accelerating-text-generation-with-confident-adaptive-language-modeling-calm/) -- `04-24/multi-model-handoff-prior-art`
- [`https://research.google/blog/looking-back-at-speculative-decoding/`](https://research.google/blog/looking-back-at-speculative-decoding/) -- `04-24/multi-model-handoff-prior-art`
- [`https://rocm.blogs.amd.com/ecosystems-and-partners/llama-cpp-oct2025/README.html`](https://rocm.blogs.amd.com/ecosystems-and-partners/llama-cpp-oct2025/README.html) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://rocm.docs.amd.com/en/latest/how-to/rocm-for-ai/fine-tuning/multi-gpu-fine-tuning-and-inference.html`](https://rocm.docs.amd.com/en/latest/how-to/rocm-for-ai/fine-tuning/multi-gpu-fine-tuning-and-inference.html) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://rpwithai.com/how-to-manage-long-chats-on-sillytavern/`](https://rpwithai.com/how-to-manage-long-chats-on-sillytavern/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://selfrefine.info/`](https://selfrefine.info/) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://shellypalmer.com/2025/08/claude-can-reference-past-chats-heres-your-enterprise-playbook/`](https://shellypalmer.com/2025/08/claude-can-reference-past-chats-heres-your-enterprise-playbook/) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://simonwillison.net/2025/Sep/12/claude-memory/`](https://simonwillison.net/2025/Sep/12/claude-memory/) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://support.claude.com/en/articles/11817273`](https://support.claude.com/en/articles/11817273) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://support.claude.com/en/articles/11817273-use-claude-s-chat-search-and-memory-to-build-on-previous-context`](https://support.claude.com/en/articles/11817273-use-claude-s-chat-search-and-memory-to-build-on-previous-context) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://tianpan.co/blog/2026-04-10-agent-state-event-stream-immutable-event-sourcing`](https://tianpan.co/blog/2026-04-10-agent-state-event-stream-immutable-event-sourcing) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://tianpan.co/blog/long-term-memory-types-ai-agents`](https://tianpan.co/blog/long-term-memory-types-ai-agents) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://towardsdatascience.com/why-crewais-manager-worker-architecture-fails-and-how-to-fix-it/`](https://towardsdatascience.com/why-crewais-manager-worker-architecture-fails-and-how-to-fix-it/) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://venturebeat.com/ai/openais-swarm-ai-agent-framework-routines-and-handoffs`](https://venturebeat.com/ai/openais-swarm-ai-agent-framework-routines-and-handoffs) -- `04-24/multi-model-handoff-prior-art`
- [`https://withmartian.com/post/introducing-routerbench`](https://withmartian.com/post/introducing-routerbench) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://www.amd.com/en/blogs/2025/how-to-run-openai-gpt-oss-20b-120b-models-on-amd-ryzen-ai-radeon.html`](https://www.amd.com/en/blogs/2025/how-to-run-openai-gpt-oss-20b-120b-models-on-amd-ryzen-ai-radeon.html) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://www.anthropic.com/research/automated-alignment-researchers`](https://www.anthropic.com/research/automated-alignment-researchers) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://www.anthropic.com/research/constitutional-ai-harmlessness-from-ai-feedback`](https://www.anthropic.com/research/constitutional-ai-harmlessness-from-ai-feedback) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://www.arsturn.com/blog/sillytavernai-lorebooks-with-gemini-2-5-a-complete-guide`](https://www.arsturn.com/blog/sillytavernai-lorebooks-with-gemini-2-5-a-complete-guide) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://www.banandre.com/blog/router-mode-in-llamacpp-a-game-changer-for-local-llm-deployment`](https://www.banandre.com/blog/router-mode-in-llamacpp-a-game-changer-for-local-llm-deployment) -- `04-24/multi-model-handoff-prior-art`
- [`https://www.braintrust.dev/articles/llm-evaluation-guide`](https://www.braintrust.dev/articles/llm-evaluation-guide) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://www.cmu.edu/dietrich/news/news-stories/2025/july/trent-cash-ai-overconfidence.html`](https://www.cmu.edu/dietrich/news/news-stories/2025/july/trent-cash-ai-overconfidence.html) -- `04-24/multi-model-handoff-prior-art`
- [`https://www.cometapi.com/cursor-2-0-what-changed-and-why-it-matters/`](https://www.cometapi.com/cursor-2-0-what-changed-and-why-it-matters/) -- `04-24/multi-model-handoff-prior-art`
- [`https://www.confident-ai.com/blog/multi-turn-llm-evaluation-in-2026`](https://www.confident-ai.com/blog/multi-turn-llm-evaluation-in-2026) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://www.emergentmind.com/topics/persona-drift`](https://www.emergentmind.com/topics/persona-drift) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://www.emergentmind.com/topics/process-reward-models-prms`](https://www.emergentmind.com/topics/process-reward-models-prms) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://www.emergentmind.com/topics/recallm`](https://www.emergentmind.com/topics/recallm) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://www.emergentmind.com/topics/temporal-retrieval-augmented-generation-rag`](https://www.emergentmind.com/topics/temporal-retrieval-augmented-generation-rag) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://www.hakunamatatatech.com/our-resources/blog/why-do-multi-agent-llm-systems-fail`](https://www.hakunamatatatech.com/our-resources/blog/why-do-multi-agent-llm-systems-fail) -- `04-24/multi-model-handoff-prior-art`
- [`https://www.jan.ai/docs`](https://www.jan.ai/docs) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://www.kdnuggets.com/how-to-run-multiple-llms-locally-using-llama-swap-on-a-single-server`](https://www.kdnuggets.com/how-to-run-multiple-llms-locally-using-llama-swap-on-a-single-server) -- `04-24/multi-model-handoff-prior-art`
- [`https://www.knightli.com/en/2026/04/19/ollama-multiple-gpu-notes/`](https://www.knightli.com/en/2026/04/19/ollama-multiple-gpu-notes/) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://www.letta.com/blog/letta-v1-agent`](https://www.letta.com/blog/letta-v1-agent) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://www.lmsys.org/blog/2024-01-17-sglang/`](https://www.lmsys.org/blog/2024-01-17-sglang/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://www.marktechpost.com/2025/03/25/understanding-and-mitigating-failure-modes-in-llm-based-multi-agent-systems/`](https://www.marktechpost.com/2025/03/25/understanding-and-mitigating-failure-modes-in-llm-based-multi-agent-systems/) -- `04-24/multi-model-handoff-prior-art`
- [`https://www.marktechpost.com/2025/11/28/nvidia-ai-releases-orchestrator-8b-a-reinforcement-learning-trained-controller-for-efficient-tool-and-model-selection/`](https://www.marktechpost.com/2025/11/28/nvidia-ai-releases-orchestrator-8b-a-reinforcement-learning-trained-controller-for-efficient-tool-and-model-selection/) -- `04-24/multi-model-handoff-prior-art`
- [`https://www.mdpi.com/2673-2688/7/2/51`](https://www.mdpi.com/2673-2688/7/2/51) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://www.mempalace.tech/benchmarks`](https://www.mempalace.tech/benchmarks) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://www.microsoft.com/en-us/research/articles/magentic-one-a-generalist-multi-agent-system-for-solving-complex-tasks/`](https://www.microsoft.com/en-us/research/articles/magentic-one-a-generalist-multi-agent-system-for-solving-complex-tasks/) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://www.microsoft.com/en-us/research/blog/llmlingua-innovating-llm-efficiency-with-prompt-compression/`](https://www.microsoft.com/en-us/research/blog/llmlingua-innovating-llm-efficiency-with-prompt-compression/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://www.philschmid.de/context-engineering-part-2`](https://www.philschmid.de/context-engineering-part-2) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://www.pinecone.io/learn/series/langchain/langchain-conversational-memory/`](https://www.pinecone.io/learn/series/langchain/langchain-conversational-memory/) -- `04-24/session-as-artifact-and-temporal-retrieval-prior-art`
- [`https://www.preprints.org/manuscript/202512.2119`](https://www.preprints.org/manuscript/202512.2119) -- `04-24/session-state-architectures-survey`
- [`https://www.researchgate.net/publication/394273065_The_Open_Argument_Mining_Framework`](https://www.researchgate.net/publication/394273065_The_Open_Argument_Mining_Framework) -- `04-24/discourse-parser-survey`
- [`https://www.runpod.io/blog/how-to-work-with-long-term-memory-in-oobabooga-and-text-generation`](https://www.runpod.io/blog/how-to-work-with-long-term-memory-in-oobabooga-and-text-generation) -- `04-25/hobbyist-and-academic-transcript-index-prior-art`
- [`https://www.snowflake.com/en/engineering-blog/fast-speculative-decoding-vllm-arctic/`](https://www.snowflake.com/en/engineering-blog/fast-speculative-decoding-vllm-arctic/) -- `04-24/multi-model-handoff-prior-art`
- [`https://www.spheron.network/blog/sglang-production-deployment-guide/`](https://www.spheron.network/blog/sglang-production-deployment-guide/) -- `04-24/session-persistence-and-reassembly-prior-art`
- [`https://www.stephendiehl.com/posts/process_reward/`](https://www.stephendiehl.com/posts/process_reward/) -- `04-24/front-and-passenger-dispatcher-prior-art`
- [`https://www.theregister.com/2025/08/24/llama_cpp_hands_on/`](https://www.theregister.com/2025/08/24/llama_cpp_hands_on/) -- `05-03/from-one-model-to-an-agentic-stack`
- [`https://www.zansara.dev/posts/2025-06-02-can-you-really-interrupt-an-llm/`](https://www.zansara.dev/posts/2025-06-02-can-you-really-interrupt-an-llm/) -- `04-24/multi-model-handoff-prior-art`

