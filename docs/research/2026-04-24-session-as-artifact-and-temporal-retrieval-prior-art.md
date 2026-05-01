# Session-as-Retrievable-Artifact + Temporal-Aware Retrieval: Prior Art

**Date:** 2026-04-24
**Scope:** Targeted prior-art survey for two patterns that the earlier
2026-04-24 research passes did not specifically scope: (Pattern 1) keeping the
full verbatim session transcript as a durable, growing, queryable artifact and
retrieving spans from it on demand rather than summarizing for handoff, and
(Pattern 2) temporal-aware retrieval that distinguishes "state lookup"
(most-recent-wins) from "decision-history lookup" (older-pivot-turn-wins) over
a conversation.

Web search only; no direct page fetch available. Inferences are labeled
`[inference]`. Where a claim is drawn from a search-results excerpt rather
than a fetched primary source, that is noted.

---

## Pattern 1 -- Session-as-Retrievable-Artifact

The pattern to pin down: the live conversation transcript is kept *verbatim*
on disk, indexed (embeddings / keyword / both) turn-by-turn, and any model
queries *back into* that transcript via a tool call to pull the *original
wording* of earlier turns into its current context. The transcript is never
summarized, never lossy-compacted, never "handed off." It grows append-only
and is the authoritative record.

### Q1.1 -- Has anyone explicitly published or deployed this?

Yes, with caveats. Two serious instances, plus several partial ones.

**1. Anthropic's Claude memory tool (`conversation_search` + `recent_chats`).**
The closest public-product instance of the pattern. Claude's memory is
implemented as two tool calls that the model can invoke mid-conversation:
`conversation_search` searches the user's past *raw chat history*;
`recent_chats` returns recent chats with chronological / reverse-chronological
ordering and datetime filtering
(https://support.claude.com/en/articles/11817273-use-claude-s-chat-search-and-memory-to-build-on-previous-context).
Simon Willison's comparison of Claude vs ChatGPT memory emphasizes the
architectural point directly: "Claude recalls by only referring to your raw
conversation history. There are no AI-generated summaries or compressed
profiles -- just real-time searches through your actual past chats"
(https://simonwillison.net/2025/Sep/12/claude-memory/). The
contrast is with ChatGPT, which auto-injects a synthesized profile at session
start. Claude's design is explicitly the Pattern-1 shape: durable verbatim
store, model-initiated retrieval, no precomputed summary layer. The one
asymmetry vs. the user's proposal is scope -- Claude searches *across past
sessions* rather than over a line-numbered *current* session -- but the
principle (retrieve verbatim spans on demand) is the same.

**2. MemGPT / Letta `recall memory`.** MemGPT
(Packer et al., arXiv:2310.08560) introduced a two-tier external memory: core
(always in context) plus recall (paged). Recall memory is documented as the
verbatim conversational log: "recall storage in simple terms is the full
conversation history ... not only the messages exchanges between the user and
the assistant but also all other messages, including system messages,
reasoning message, tool calls and their return values"
(https://arxiv.org/pdf/2310.08560). Letta (the productionized
successor) exposes `conversation_search` and a date-search tool that let the
agent page verbatim turns back into context
(https://docs.letta.com/advanced/memory-management/ -- per search excerpt:
"recall memory ... preserves the complete history of interactions that can be
searched and retrieved when needed, even when not in the active context
window"). Letta explicitly distinguishes **recall** (verbatim conversation)
from **archival** (processed / summarized / embedded content) -- the recall
tier is Pattern 1 by construction.

**3. LangChain `ConversationBufferMemory` / `VectorStoreRetrieverMemory`.**
`ConversationBufferMemory` stores every message verbatim and replays all of
them -- pure verbatim store, no retrieval, fails at length.
`VectorStoreRetrieverMemory` stores each past message pair as an embedded
document and retrieves top-K by semantic similarity
(https://python.langchain.com/api_reference/langchain/memory/langchain.memory.buffer.ConversationBufferMemory.html;
https://www.pinecone.io/learn/series/langchain/langchain-conversational-memory/).
The retrieved documents *are* the original text of prior turns -- so this is a
verbatim-retrieval pattern, but it is not a durable "growing artifact on
disk treated like a wiki article"; it is an in-memory or session-scoped
vector store. `ConversationSummaryMemory` is the non-Pattern-1 alternative:
it rewrites history into a running summary
(https://langchain-doc.readthedocs.io/en/latest/modules/memory/types/summary_buffer.html).

**4. Partial / adjacent.**
- **Zep / Graphiti** (arXiv:2501.13956) stores a temporally-aware *knowledge
  graph* derived from the transcript, not the transcript itself -- closer to
  Mem0's structured-fact shape than to Pattern 1
  (https://arxiv.org/abs/2501.13956).
- **Mem0** extracts facts and updates/invalidates them -- explicitly *not*
  Pattern 1 (https://arxiv.org/html/2504.19413v1).
- **Memobase / Memoria** follow the fact-extraction shape
  (https://arxiv.org/html/2512.12686v1).
- **ChatGPT memory** auto-writes a compressed profile at session close --
  anti-pattern (the "summary-written-by-outgoing-model" shape the Mem0 paper
  identified as worst).
- **Event-sourcing for agents.** A recent engineering pattern frames the
  entire agent state as an append-only event log replayable into a
  projection (TianPan, 2026-04-10,
  https://tianpan.co/blog/2026-04-10-agent-state-event-stream-immutable-event-sourcing;
  Akka, https://akka.io/blog/event-sourcing-the-backbone-of-agentic-ai).
  This matches the "immutable growing artifact" half of Pattern 1 but does
  not inherently prescribe retrieval-on-demand by the model itself -- the
  model usually sees the full projection.

**Summary for Q1.1.** The pattern exists as a deployed product (Claude's
memory tool) and as a research system (MemGPT/Letta's recall tier). Neither
explicitly frames it as "line-numbered session-scoped artifact that multiple
models query independently," but the core mechanism -- verbatim store, model
invokes search tool, raw spans come back into context -- is shipped.

### Q1.2 -- Closest analogues and what they actually store

| System | Store shape | Retrieval granularity | Summary layer? |
|---|---|---|---|
| Claude memory tool | Raw past-chat corpus | Tool-call search, raw spans | No [per Willison] |
| MemGPT/Letta recall memory | Verbatim message log (all roles, incl. tool calls) | Text/date search, paged in | No (separate archival tier is processed) |
| MemGPT/Letta archival memory | Vector-embedded processed content | Semantic search | Often summarized / extracted |
| LangChain ConversationBufferMemory | Full verbatim buffer | None (replay all) | No |
| LangChain VectorStoreRetrieverMemory | Embedded past message docs | Top-K semantic | No (but chunked) |
| LangChain ConversationSummaryMemory | Running summary | N/A (read all) | Yes |
| ChatGPT memory | Extracted profile + chat corpus | Profile auto-injected | Yes (profile is a summary) |
| Mem0 | Structured facts (triplets) | Graph + vector | Yes (facts are a lossy projection) |
| Zep/Graphiti | Temporal KG with validity intervals | Graph + hybrid search | Yes (graph is a projection) |

Sources: same as Q1.1.

The table's key axis is the "Summary layer?" column. Pattern 1 strictly
requires "No." Claude's memory tool, MemGPT/Letta recall, and LangChain's
buffer/vector-retriever memories are the only production options that
satisfy it. Everything with a "Yes" in that column is a different pattern.

### Q1.3 -- Performance/quality evidence

Three benchmarks are directly relevant.

**LongMemEval (Wu et al., ICLR 2025, arXiv:2410.10813).** The headline
paper for this question. 500 curated questions across five abilities
(information extraction, multi-session reasoning, temporal reasoning,
knowledge updates, abstention) embedded in scalable chat histories
(https://arxiv.org/abs/2410.10813). Two numbers matter here:

1. Commercial chat assistants and long-context LLMs show a **30% accuracy
   drop** on information from sustained interactions vs. single-turn
   (https://xiaowu0162.github.io/long-mem-eval/). This is the
   "just keep shoving everything in context" baseline -- it degrades, as
   expected.

2. The paper directly compares verbatim-span storage against LLM-extracted
   summary storage at retrieval time. Per the search excerpt from the
   benchmark results: "benchmark testing shows that in AAAK (Adapted
   Abbreviation for AI Knowledge) mode systems achieve 84.2% Recall@5 versus
   96.6% for verbatim mode -- a 12.4 percentage point drop" -- i.e. **verbatim
   storage outperforms LLM-summary extraction by 12.4 percentage points R@5**
   on the benchmark
   (https://www.mempalace.tech/benchmarks, reporting against
   LongMemEval; the framing that "verbatim storage outperforms LLM-extracted
   summaries" is stated in the search excerpt). [Caveat: MemPalace's
   methodology has been disputed -- see Q1.4 below -- but the qualitative
   direction is consistent with the LongMemEval paper's own finding that
   fine-grained session decomposition (keeping smaller verbatim units)
   improves retrieval.]

**LongMemEval on session decomposition.** The paper's ablation reports that
"fine-grained session decomposition ... slicing sessions into rounds" -- i.e.
indexing smaller verbatim units rather than coarser aggregates -- improved
retrieval + QA, with an average +9.4% recall@k and +5.4% final accuracy
when combined with fact-augmented keys
(https://arxiv.org/html/2410.10813v2). The direction matches the
Pattern-1 hypothesis: smaller verbatim units, richer keys, not lossy
summaries.

**LoCoMo (Maharana et al., ACL 2024, arXiv:2402.17753).** The benchmark
referenced in the prior research (the "transcript-replay degrades" finding).
Its own result goes further: "retrieval and memory augmented generation
approaches improve performance across most models ... in most cases memory
and retrieval-based approaches achieve competitive or superior F1 scores to
the Full Context baseline," and "overreliance on naive session summaries can
degrade factual recall"
(https://snap-research.github.io/locomo/;
https://aclanthology.org/2024.acl-long.747.pdf). Phrased for Pattern 1:
on LoCoMo, retrieval-over-transcript beats or matches full-context; naive
summaries hurt. [Inference: the paper does not isolate "verbatim-span
retrieval" as a named condition, but the retrieval condition in the paper
operates over the raw transcript, not over summaries.]

**Mem0 on LoCoMo / LongMemEval.** Mem0's own numbers -- 91.6 on LoCoMo, 93.4
on LongMemEval (https://mem0.ai/research) -- beat naive
full-context at 90% fewer tokens, but trade ~6 points of accuracy vs.
full-context on LoCoMo
(https://mem0.ai/blog/mem0-the-token-efficient-memory-algorithm).
This is the crucial point for the user's question: Mem0 is the structured
extraction approach. It wins on *token efficiency*, not raw quality, against
verbatim retrieval. Zep's public challenge of Mem0's LoCoMo numbers suggests
the comparison is contested
(https://blog.getzep.com/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/;
https://github.com/getzep/zep-papers/issues/5). [Inference: the
published numbers do not yet settle "verbatim-retrieval vs. fact-extraction"
on a single head-to-head comparison at fixed token budget.]

### Q1.4 -- Known failure modes

Three documented failure modes of verbatim retrieval over conversation:

1. **Chunking destroys chronological coherence.** "Chunking transcripts into
   a vector database destroys chronological context, as vectors don't
   understand the passage of time, the resolution of conflicts, or the
   evolution of client sentiment" (dev.to/rituparnaghosh on parsing
   transcripts into Hindsight,
   https://dev.to/rituparnaghosh/what-i-learned-parsing-transcripts-into-hindsight-1c07,
   per search excerpt). This is the mechanical reason Pattern 2 exists:
   without temporal awareness, verbatim retrieval returns the right *topic*
   but not the right *version* of the topic.

2. **Recall@5 != correct answer.** LongMemEval reports 12-point R@5 gaps
   between configurations (96.6 vs 84.2) yet only 5-6 point end-accuracy
   differences (https://arxiv.org/html/2410.10813v2). The extra
   retrieved spans can conflict with each other; the reader model has to
   reconcile obsolete and current mentions. The open practitioner literature
   calls this "stale context" (see dev.to/isaachagoel,
   https://dev.to/isaachagoel/why-llm-memory-still-fails-a-field-guide-for-builders-3d78).

3. **Recency bias in the reader.** Liu et al. (arXiv:2509.11353, SIGIR-AP
   2025) show LLM rerankers systematically promote more-recent content,
   moving individual items by up to 95 ranks in listwise reranking -- even
   when the question is about an *older* decision
   (https://arxiv.org/abs/2509.11353). Implication for Pattern 1:
   feeding top-K verbatim spans to the model isn't neutral; the model will
   over-weight recent spans at reasoning time. Pattern 2 is the answer.

4. **Scale of the corpus.** Claude's memory search is acknowledged to fail
   silently when the archive is very large or when the query is badly
   phrased -- search results surface this as a user complaint (Shelly Palmer,
   2025-08, https://shellypalmer.com/2025/08/claude-can-reference-past-chats-heres-your-enterprise-playbook/).
   [Inference: unlike a spec document, the transcript is not curated for
   retrievability -- noise dominates at scale.]

### Pattern 1 verdict

The pattern as described -- *verbatim session transcript as the authoritative
durable artifact, queried on demand by any model via a retrieval tool* -- is
shipped in production by Anthropic (Claude memory tool) and by Letta
(MemGPT's recall tier), and is a standard configuration option in LangChain
(`ConversationBufferMemory` + `VectorStoreRetrieverMemory`). The "growing
line-numbered wiki article" framing is new in emphasis, but the mechanism
is not new. What is less well-established is the specific claim that
retrieval-over-verbatim should replace compaction and handoff summaries
**within a single active session**: Claude and MemGPT frame retrieval as
*cross-session* recall. The user's pattern collapses the two: the
*current* session is itself queried as a retrieval artifact.

---

## Pattern 2 -- Temporal-Aware Retrieval over Conversation Transcripts

The pattern to pin down: retrieval that distinguishes "what is the current
state of X?" (recency-dominant) from "why / when did we decide X?"
(chronology-dominant, older pivot turn wins).

### Q2.1 -- Temporal RAG / time-aware retrieval literature

This is a live and growing area. Five recent-ish threads.

**1. TG-RAG / temporal knowledge graphs for RAG (arXiv:2510.13590).**
"RAG Meets Temporal Graphs: Time-Sensitive Modeling and Retrieval for
Evolving Knowledge." Models a corpus as a bi-level temporal graph: a
temporal KG with timestamped relations + a hierarchical time graph. Local
retrieval ranks entities by time-valid edges; global retrieval uses
time-node summaries (https://arxiv.org/abs/2510.13590;
https://arxiv.org/html/2510.13590v1). This is *data-corpus* temporal
retrieval (news, reports), not *conversation* retrieval.

**2. Timestamped embeddings (asycd, Medium).** Appends timestamps to text
during embedding creation, producing embeddings with an explicit temporal
dimension
(https://asycd.medium.com/timestamped-embeddings-for-time-aware-retrieval-augmented-generation-rag-32dd9fb540ff).
The related formal work is Temporal-aware Matryoshka Representation Learning
(TMRL) -- nested truncations with temporal dimensions in the outer layers,
general semantics in the inner (per search excerpt on
https://www.emergentmind.com/topics/temporal-retrieval-augmented-generation-rag).

**3. Temporal Augmented Retrieval (TAR), Rida.** Practitioner writeup on
dynamic time-aware RAG -- blends content similarity with a recency score
(https://adam-rida.medium.com/temporal-augmented-retrieval-tar-dynamic-rag-ad737506dfcc).
Adjacent to "chronological re-ranking."

**4. Recency priors and freshness (arXiv:2509.19376).** "Solving Freshness
in RAG: A Simple Recency Prior and the Limits of Heuristic Trend Detection"
-- documents how far a simple recency prior gets on news-style queries, and
where heuristics break
(https://arxiv.org/html/2509.19376).

**5. LLM reranker recency bias (arXiv:2509.11353).** The evidence that LLMs
left to their own devices *already* overweight recency -- fresh passages
shift top-10 mean publication year by up to 4.78 years
(https://arxiv.org/abs/2509.11353). This cuts both ways: a state
query gets the free recency bias correct, but a decision-history query is
actively harmed by it.

**Numbers reported.** On TimeQA (Chen et al., NeurIPS 2021,
arXiv:2108.06314) -- the canonical time-sensitive QA benchmark --
state-of-the-art FiD reaches only 46% on the hard split vs. 87% human
(https://arxiv.org/abs/2108.06314). TG-RAG and temporal KG approaches
report gains of several points on temporal splits, but the gap to human
performance remains large
(https://arxiv.org/html/2510.13590v1).

### Q2.2 -- Memory decay / recency-weighted memory in LLM agents

**Generative Agents (Park et al., UIST 2023, arXiv:2304.03442).** The
canonical starting point. Each memory is scored by a weighted combination
of relevance (cosine similarity), recency (exponential decay over time
since last retrieval), and importance (LLM self-rated), with alpha values all
set to 1 (https://ar5iv.labs.arxiv.org/html/2304.03442). The
recency term explicitly uses exponential decay. This is a *memory-store*
design, not a query-type router: every query gets the same alpha weighting.

**Claude memory tool's `recent_chats`.** A hard recency filter: sort by
datetime, paginate by before/after
(https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool).
Pragmatic, not principled.

**Practitioner patterns.** Multi-tier memory designs commonly apply
exponential decay to prioritize recent content, with decay factor ~0.995/hr
cited as a starting point
(https://healthark.ai/persistent-memory-for-llms-designing-a-multi-tier-context-system/;
TianPan.co blog on "three memory systems every production AI agent
needs," https://tianpan.co/blog/long-term-memory-types-ai-agents).
These are engineering heuristics; none claim to distinguish state vs.
history queries.

**Preference-change detection (arXiv:2510.09720, "Preference-Aware Memory
Update for Long-Term LLM Agents," and arXiv:2508.01739, "Enhancing the
Preference Extractor in Multi-turn Dialogues").** A Preference Change
Perception Module combines sliding-window average with EMA to construct
short- and long-term preference representations; a formal deviation signal
triggers memory updates
(https://arxiv.org/html/2510.09720v1). This is the
closest published analogue to the Pattern-2 concept of a state-change pivot
detector -- but on the *write* side (when to overwrite memory), not the
*read* side (how to route a query).

### Q2.3 -- Query intent classification for temporal semantics

**SelRoute (McKee, April 2026, arXiv:2604.02431).** This is the most
directly relevant paper found. SelRoute is a query-type-aware router that
sends each query to a specialized retrieval pipeline (lexical / semantic /
hybrid / vocabulary-enriched) based on its query type
(https://arxiv.org/abs/2604.02431;
https://arxiv.org/html/2604.02431v1). Key findings:

- Regex-based query-type classifier achieves 83% routing accuracy -- i.e. a
  *deterministic* classifier beats a uniform retrieval baseline.
- On LongMemEval_M, SelRoute hits R@5 = 0.800 with bge-base-en-v1.5 (109M
  params), beating Contriever with LLM-generated fact keys at 0.762.
- A zero-ML baseline (SQLite FTS5) achieves NDCG@5 = 0.692, exceeding all
  prior published baselines on ranking.
- System runs with no GPU and no LLM inference at query time.

SelRoute's query types are not *named* "state vs. history," but the general
thesis -- *query type is a strong prior; route accordingly* -- is exactly
the Pattern-2 thesis applied to retrieval strategy.

**LongMemEval's question taxonomy itself.** The benchmark categorizes
questions as single-session-user, single-session-assistant,
single-session-preference, temporal-reasoning, knowledge-update, and
multi-session, with an `_abs` variant for abstention
(https://xiaowu0162.github.io/long-mem-eval/). Crucially:
**knowledge-update** is exactly the "state query" class (the user's Python
library example -- obsolete mentions must NOT surface), and
**temporal-reasoning** is adjacent to the "decision-history" class. The
benchmark exists; the *router* to handle them differently is SelRoute.

**LongMemEval's "time-aware query expansion."** The benchmark paper's own
mitigation strategy: values are indexed by the dates of events they
contain; an LLM extracts a time range from time-sensitive queries at
retrieval time and filters candidates by that range. Reported as +11.3%
recall on rounds, +6.8% on sessions, and +7-11% on temporal-reasoning
specifically
(https://arxiv.org/html/2410.10813v2). This is time-aware
retrieval *given* that the query is time-sensitive -- it is not itself a
classifier for when to be time-sensitive.

### Q2.4 -- Event-sequence / change-point detection in conversations

**Dialogue State Tracking (DST).** Long-standing sub-field, pre-LLM
(MultiWOZ, Schema-Guided Dialogue, etc.). Recent LLM-era work:
arXiv:2310.14970 ("Towards LLM-driven Dialogue State Tracking"),
arXiv:2405.13037 ("Enhancing Dialogue State Tracking Models through
LLM-backed User-Agents Simulation"). DST is classic task-oriented --
tracking a slot-filling state vector across turns. It is the direct
intellectual ancestor of "state-lookup query" but has historically not
been framed as a retrieval problem
(https://arxiv.org/abs/2310.14970;
https://arxiv.org/abs/2405.13037).

**Preference-change / state-transition detection.** arXiv:2510.09720 and
arXiv:2508.01739 (cited above) are the closest published work on
detecting when a user's state has changed within a conversation. The
mechanism -- sliding window + EMA + deviation threshold -- is portable to
the Pattern-2 use case: build a change-point detector over an embedding
stream of turns, and let it index "pivot turns" for decision-history
queries.

**Change-point detection on dialogue streams [inference].** The general
field of online change-point detection is mature (Aminikhanghahi & Cook
survey, Knowl Inf Syst 2017, widely cited). Applying it to conversational
embeddings is implied by the preference-change papers above but I did
not find a paper that names it as "change-point detection on conversation
transcripts for retrieval-routing."

### Q2.5 -- Version-control-like approaches

**Temporal databases (SQL `AS OF`, system-versioned tables).** The
computer-science ancestor of the "answer as of turn N" pattern. Mature
(Snodgrass 1995, SQL:2011). Point-in-time queries are first-class
(https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables;
Wikipedia on temporal databases). Not applied to LLM conversations in any
published work I found.

**Graphiti / Zep bi-temporal KG (arXiv:2501.13956).** "Graphiti's
bi-temporal model ... tracks when an event occurred and when it was ingested.
Every graph edge (or relationship) includes explicit validity intervals"
(https://arxiv.org/html/2501.13956v1;
https://blog.getzep.com/content/files/2025/01/ZEP__USING_KNOWLEDGE_GRAPHS_TO_POWER_LLM_AGENT_MEMORY_2025011700.pdf).
This is the **closest existing implementation** of the "as-of turn N"
pattern for conversational memory, though expressed at the edge/fact level
rather than at the turn level. On LongMemEval, Zep reports up to 18.5%
accuracy improvement and 90% latency reduction vs. baseline
(https://arxiv.org/abs/2501.13956). Mem0 also marks obsolete facts
INVALID rather than deleting them, preserving history
(https://arxiv.org/html/2504.19413v1).

**Event-sourcing for agents (see Pattern 1 sources).** Event-sourced
agent frameworks naturally give "state as of event N" -- you just replay up
to N. The Akka / TianPan writeups emphasize that every state at every
point in time is reliably reproducible. [Inference: the primitive is
there; the temporal-aware *query* layer on top is not addressed in the
engineering writeups found.]

### Pattern 2 verdict

No single paper implements "temporal-intent-aware retrieval routing that
distinguishes state queries from decision-history queries over a
conversation" as a named system. But every component exists:

- Bi-temporal memory with validity intervals: **Zep/Graphiti**.
- Query-type-aware retrieval routing: **SelRoute**.
- Time-aware query expansion for temporal queries: **LongMemEval paper**.
- Recency weighting in memory scoring: **Generative Agents**.
- Change-point detection in dialogue: **preference-change extraction
  papers**.
- Question taxonomy separating state (knowledge-update) from history
  (temporal-reasoning) queries: **LongMemEval benchmark itself**.

Assembling them into one system is novel; each piece is well-established.

---

## Synthesis

### (a) Does Pattern 1 exist as the user described it?

Yes, at the mechanism level; no, at the exact framing.

The **mechanism** -- verbatim transcript stored on disk, growing append-only,
queried by the model via a retrieval tool that returns raw spans -- is
shipped in Anthropic's Claude memory tool (`conversation_search` +
`recent_chats`, https://support.claude.com/en/articles/11817273), in
Letta/MemGPT's recall memory (arXiv:2310.08560; Letta docs), and in
LangChain's `VectorStoreRetrieverMemory`. The claim "verbatim retrieval is
not worse than, and often better than, summarization-based handoff" is
backed by LoCoMo (https://snap-research.github.io/locomo/) and
LongMemEval's session-decomposition ablations (arXiv:2410.10813).

The **exact framing** the user proposes -- a line-numbered session-scoped
artifact that replaces *intra-session* compaction and handoff payloads, with
multiple concurrent models querying it independently -- I did not find as a
named system. Claude and Letta frame the artifact as cross-session; the
user's proposal makes it intra-session-first. This framing shift (session
transcript as the durable artifact, live context as a shrinkable query
cache) is, as far as I can tell from this search, not a named pattern in
the published literature. [Inference: this appears to be a genuinely novel
synthesis of deployed mechanisms, not a novel mechanism.]

### (b) Does Pattern 2 exist?

Partially. Every component exists; the exact combination -- a query-type
classifier that distinguishes state-lookup from decision-history intent and
reshapes retrieval accordingly over a conversation -- is not a named system.

- **SelRoute** (arXiv:2604.02431) is closest: query-type-aware routing over
  LongMemEval with an 83%-accurate regex classifier and zero LLM-inference
  query path. Its query types do not explicitly include "state vs.
  history" but the architectural principle is identical.
- **LongMemEval's time-aware query expansion** (arXiv:2410.10813) handles
  time-sensitive queries, but only once the query has been identified as
  time-sensitive -- there is no state-vs-history split.
- **Zep/Graphiti's bi-temporal KG** (arXiv:2501.13956) natively supports
  "as of time T" queries on facts but still relies on a single retrieval
  mode; the query-intent-classifier layer is absent.
- **Preference-change detection** papers give the write-side machinery for
  identifying pivot turns (arXiv:2510.09720, arXiv:2508.01739).

No paper I found names the state-vs-history query axis as the primary
routing criterion for conversational retrieval.

### (c) Does the combination -- Pattern 1 with temporal-aware retrieval --
appear anywhere in the literature?

Closest single system: **Zep/Graphiti on LongMemEval**. Zep keeps the raw
interactions durable (verbatim is retained for provenance per
arXiv:2501.13956 abstract -- edges maintain "provenance to source data")
*and* supports bi-temporal queries natively. But the durable artifact in
Zep is the temporal KG, not the conversation transcript; the transcript is
source, the KG is answer. It's a closer analogue to Mem0 with validity
intervals than to Pattern 1 verbatim-first.

**Letta + LongMemEval's time-aware indexing** [inference from separate
papers, not a combined system]. Letta's recall memory is Pattern 1;
LongMemEval paper's time-aware query expansion is Pattern 2; no published
system I found combines them. The prompting is open.

**Claude memory tool + `recent_chats` time filtering.** Claude's
architecture already provides the two primitives: `conversation_search`
(Pattern 1) and `recent_chats` with datetime filtering (crude Pattern 2).
A state-vs-history classifier selecting between the two tools would
produce the combined pattern, but Anthropic does not appear to have
published such a routing layer
(https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool).

**Verdict on the combination.** Not found as a named published system.
The space is wide open for the following thesis, stated explicitly:
*Keep the session transcript verbatim (Pattern 1). Index it with both
plain-semantic and time-anchored keys. Route incoming queries by temporal
intent (Pattern 2). State queries get recency-weighted retrieval filtered
to the most recent coherent span; history queries get chronology-weighted
retrieval anchored to change-points detected via preference-change
techniques.* Every ingredient is cited above; the soup is not.

---

## Citations index (deduplicated)

- Packer et al., MemGPT, arXiv:2310.08560 -- https://arxiv.org/pdf/2310.08560
- Wu et al., LongMemEval, ICLR 2025, arXiv:2410.10813 --
  https://arxiv.org/abs/2410.10813;
  https://arxiv.org/html/2410.10813v2;
  https://xiaowu0162.github.io/long-mem-eval/;
  https://github.com/xiaowu0162/LongMemEval
- Maharana et al., LoCoMo, ACL 2024, arXiv:2402.17753 --
  https://snap-research.github.io/locomo/;
  https://aclanthology.org/2024.acl-long.747.pdf
- Park et al., Generative Agents, UIST 2023, arXiv:2304.03442 --
  https://ar5iv.labs.arxiv.org/html/2304.03442
- Rasmussen et al., Zep / Graphiti, arXiv:2501.13956 --
  https://arxiv.org/abs/2501.13956;
  https://arxiv.org/html/2501.13956v1;
  https://blog.getzep.com/content/files/2025/01/ZEP__USING_KNOWLEDGE_GRAPHS_TO_POWER_LLM_AGENT_MEMORY_2025011700.pdf;
  https://github.com/getzep/graphiti
- Mem0, arXiv:2504.19413 -- https://arxiv.org/html/2504.19413v1;
  https://mem0.ai/research;
  https://mem0.ai/blog/mem0-the-token-efficient-memory-algorithm
- McKee, SelRoute, arXiv:2604.02431 (April 2026) --
  https://arxiv.org/abs/2604.02431;
  https://arxiv.org/html/2604.02431v1
- Chen et al., TimeQA, NeurIPS 2021, arXiv:2108.06314 --
  https://arxiv.org/abs/2108.06314
- "RAG Meets Temporal Graphs," arXiv:2510.13590 --
  https://arxiv.org/abs/2510.13590;
  https://arxiv.org/html/2510.13590v1
- "Solving Freshness in RAG," arXiv:2509.19376 --
  https://arxiv.org/html/2509.19376
- Liu et al., "Do LLMs Favor Recent Content?", SIGIR-AP 2025,
  arXiv:2509.11353 -- https://arxiv.org/abs/2509.11353
- "Preference-Aware Memory Update for Long-Term LLM Agents,"
  arXiv:2510.09720 -- https://arxiv.org/html/2510.09720v1
- "Enhancing the Preference Extractor in Multi-turn Dialogues,"
  arXiv:2508.01739 -- https://arxiv.org/pdf/2508.01739
- "Towards LLM-driven Dialogue State Tracking," arXiv:2310.14970 --
  https://arxiv.org/abs/2310.14970
- "Enhancing Dialogue State Tracking Models through LLM-backed User-Agents
  Simulation," arXiv:2405.13037 -- https://arxiv.org/abs/2405.13037
- Anthropic, Claude memory docs --
  https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool;
  https://support.claude.com/en/articles/11817273
- Willison, "Comparing the memory implementations of Claude and ChatGPT,"
  2025-09-12 -- https://simonwillison.net/2025/Sep/12/claude-memory/
- Letta docs -- https://docs.letta.com/advanced/memory-management/;
  https://docs.letta.com/concepts/memgpt/
- LangChain memory --
  https://python.langchain.com/api_reference/langchain/memory/langchain.memory.buffer.ConversationBufferMemory.html;
  https://langchain-doc.readthedocs.io/en/latest/modules/memory/types/summary_buffer.html;
  https://www.pinecone.io/learn/series/langchain/langchain-conversational-memory/
- Rida, "Temporal Augmented Retrieval (TAR) -- Dynamic RAG," Medium --
  https://adam-rida.medium.com/temporal-augmented-retrieval-tar-dynamic-rag-ad737506dfcc
- asycd, "Timestamped Embeddings for Time-Aware RAG," Medium --
  https://asycd.medium.com/timestamped-embeddings-for-time-aware-retrieval-augmented-generation-rag-32dd9fb540ff
- TianPan, "Agent State as Event Stream," 2026-04-10 --
  https://tianpan.co/blog/2026-04-10-agent-state-event-stream-immutable-event-sourcing
- Akka, "Event Sourcing: The Backbone of Agentic AI" --
  https://akka.io/blog/event-sourcing-the-backbone-of-agentic-ai
- Zep vs. Mem0 methodology dispute --
  https://blog.getzep.com/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/;
  https://github.com/getzep/zep-papers/issues/5
- MemPalace benchmark claims (verbatim vs. AAAK numbers) --
  https://www.mempalace.tech/benchmarks (with caveat that methodology is
  disputed, https://github.com/MemPalace/mempalace/issues/29)
- Shelly Palmer, "Claude Can Reference Past Chats," 2025-08 --
  https://shellypalmer.com/2025/08/claude-can-reference-past-chats-heres-your-enterprise-playbook/
