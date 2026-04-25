# Hobbyist & Academic Prior Art for Verbatim Transcript Indexing,
# Tiered Indexing, and Cross-Card Disposable-Context Retrieval

**Date:** 2026-04-25
**Scope:** A focused prior-art sweep across the homelab/hobbyist and academic
layers that yesterday's research
(`2026-04-24-session-as-artifact-and-temporal-retrieval-prior-art.md`)
explicitly did not cover. Yesterday's pass concentrated on production memory
systems (Claude memory tool, ChatGPT memory, Mem0, Zep, Letta, LangChain).
The hypothesis to stress-test here is whether the *non-production* layers —
SillyTavern/Oobabooga/KoboldAI extensions, Open-WebUI/AnythingLLM/LM
Studio/Msty/Jan, and the academic memory-system literature beyond the
LongMemEval/LoCoMo/Mem0 baseline — have already shipped the V0 pattern the
user is proposing, in part or in whole.

The V0 pattern under test (recapped from
`2026-04-24-session-notes-full.md` lines 14-71):

1. **Verbatim line-numbered transcript** of the *current active session* on
   disk, never summarized.
2. **Tiered index** of that transcript: cheap inline per-turn (embedding
   plus basic tags), richer at compaction time.
3. **Disposable-context retrieval**: a small resident model on a *separate
   GPU* whose KV cache is reset between queries; primary calls
   `recall(query)` and gets back verbatim line spans.
4. **In-session scope**: retrieval substitutes for compaction *during the
   same conversation*, not just cross-session.
5. **Temporal-aware routing** (state vs. history) layered on top — V2.

The four sub-questions below are answered in turn. Negative findings are
called out; "nobody is doing X" is a finding when it is true.

Web search only. Where a claim is drawn from a search-results excerpt
rather than a fetched primary source, that is noted. Inferences are
labeled `[inference]`.

---

## Q1 — Hobbyist / homelab tooling

### Q1.1 — SillyTavern

SillyTavern is the most relevant single project: it is the largest and most
active hobbyist front-end for local conversational LLMs, and has the
densest memory-extension ecosystem.

**Vector Storage (built-in, "Chat Vectorization").** This is the closest
SillyTavern equivalent to V0's Tier-1 indexing. Per the official docs
(https://docs.sillytavern.app/extensions/chat-vectorization/) and DeepWiki
mirror (https://deepwiki.com/SillyTavern/SillyTavern/6.3-vector-storage-and-rag-system),
the mechanism is:

- A vector is calculated for **each message** and stored. Vectorizing
  occurs in the background whenever the user sends or receives a message
  ("vectorizing occurs in the background, whenever you send or receive a
  message"). Each message is stored individually and can be retrieved
  individually.
- At generation time, the most recent N messages (default 2) are used as a
  query vector. Past messages with relevance ≥ 25% are candidates; the top
  3 are "shuffled" into the chat history — i.e. *temporarily moved within
  the prompt* so the model sees them.
- "If a vector search matches the vector of a summarized message, the
  original message is retrieved from chat history and shuffled into
  context" — i.e. the **verbatim** message is what gets injected, not the
  summary, even when summarization is layered on top.
- Storage backend is `vectra` (in-process JSON index on the Node server
  side) by default. Embeddings can come from OpenAI, the locally-hosted
  Extras module, koboldcpp's `--embeddingsmodel` endpoint, etc.
- Items stored carry the vector plus metadata; messages are split if
  `message_chunk_size` is set.

This is in-session AND cross-session by design — the index is per-chat-file
and grows as the chat grows. **Verbatim retrieval over the current session
is shipped, on by default once enabled, with embeddings produced
automatically per-turn.** This is the closest existing implementation of
V0's Tier-1 inline indexing path.

What it *does not* do:

- No tiered indexing — there is no "rich features at compaction" pass.
  Tags like speaker / contains-code / contains-citation are not surfaced;
  metadata is the embedding plus a hash and chunk index.
- Retrieval is "shuffle into prompt," not a tool call. The model does not
  decide when to retrieve; the front-end injects unconditionally on every
  generation.
- No multi-card disposability: the embedder runs wherever the user
  configured it (local Extras module, llama.cpp endpoint, or remote API),
  and is single-shot per request anyway, so KV management is trivial.
- License: AGPL-3.0. Active project (https://github.com/SillyTavern/SillyTavern,
  ~17k stars, very active in 2024-2026).

**Smart Context (deprecated).** The earlier version of the same pattern,
backed by ChromaDB. Per the issue tracker
(https://github.com/SillyTavern/SillyTavern/issues/2625) and the
SillyTavern-Extras repo (https://github.com/SillyTavern/SillyTavern-Extras
— now marked OBSOLETE), Smart Context "is deprecated since data bank and
currently already integrated vectorization is present in default
sillytavern." Same mechanism (whole chat history → vector DB → search on
new input → inject matching messages), older transport. Replaced by
Vector Storage. Not maintained.

**Lorebook / World Info.** Static keyword-triggered prompt injection. World
Info entries fire when their keywords appear in the recent message text,
and the entry's body is inserted into the prompt
(https://docs.sillytavern.app/usage/core-concepts/worldinfo/). This is a
*write-once curated* artifact, not a transcript index. As of 2024-2025
World Info also supports vector activation as part of Vector Storage
(semantic instead of pure keyword), but the artifact is still curated,
not the transcript.

**Summarize extension.** Periodic running summary generated by an LLM,
inserted into the prompt at a configurable depth. Token budget is computed
as `max summary buffer = context size - summarization prompt - previous
summary - response length`
(https://docs.sillytavern.app/extensions/summarize/). This is the
*opposite* of V0 — lossy compaction of the transcript. Useful as a
counter-example: this is what the community used before vectorization
worked well, and per several how-to writeups (e.g.
https://rpwithai.com/how-to-manage-long-chats-on-sillytavern/) is still
the most-recommended path "in most cases."

**Author's Note.** Static user-controlled string injected near the end of
the prompt. Not a memory mechanism in the V0 sense. Mentioned only because
the original brief listed it.

**Third-party extensions worth naming:**

- **timeline-memory** (unkarelian, 35 stars,
  https://github.com/unkarelian/timeline-memory). Tool-call based.
  Generates AI summaries of "chapters" of the chat; agent invokes
  `query_timeline_chapter` / `query_timeline_chapters` to retrieve them.
  Stores chapters in chat metadata as JSON. **Tool-call retrieval shipped
  in a hobbyist extension** — but the artifact is summary-based, not
  verbatim, and chapters are coarse.
- **TunnelVision** (Coneja-Chibi/deadbranch-forks,
  https://github.com/Coneja-Chibi/TunnelVision). "Fully autonomous and
  agentic lorebook, tracker, and summary retrieval." Agentic in the sense
  of LLM-decided retrieval. Summary-based.
- **SillyTavern-MemoryBooks** (aikohanasaki,
  https://github.com/aikohanasaki/SillyTavern-MemoryBooks). User marks
  scene start/end; extension generates a JSON-summary lorebook entry.
  Vectorized for retrieval. Not verbatim.
- **sillytavern-character-memory / CharMemory** (bal-spec,
  https://github.com/bal-spec/sillytavern-character-memory). Auto-extracts
  *structured character memories* into the Data Bank, vectorized. Pure
  fact-extraction shape — Mem0-adjacent, not Pattern 1.
- **SillyTavern-ReMemory** (InspectorCaracal,
  https://github.com/InspectorCaracal/SillyTavern-ReMemory). "Yet another
  SillyTavern memory extension." Summary-centric.
- **arkhon_memory_st** (kissg96,
  https://github.com/kissg96/arkhon_memory_st_archive). Archived. Was a
  generic memory plugin.

Searching "r/SillyTavernAI" via web search for dominant practice
(https://www.arsturn.com/blog/sillytavernai-lorebooks-with-gemini-2-5-a-complete-guide,
https://rpwithai.com/how-to-manage-long-chats-on-sillytavern/) suggests
the community pattern in 2024-2026 has converged on **summarization
combined with vectorized lorebook entries**, not on verbatim retrieval as
the *primary* mechanism. Vector Storage is the recommended companion, but
running summaries are still recommended as the load-bearing piece for
long chats. [Inference, with caveat: I did not directly index Reddit; this
is reading practitioner write-ups.]

**Verdict on SillyTavern:** Verbatim per-message embedding of the *current
session*, with verbatim spans injected at generation time, is **shipped,
on by default, automatic, single-card** (Vector Storage). What is *not*
shipped: tool-call recall (only one extension does this, with summaries),
tiered cheap/rich indexing, multi-card disposability, line-numbered
indexing, or a metadata layer beyond the embedding itself.

### Q1.2 — Oobabooga text-generation-webui

A different kind of negative finding: the long-term-memory ecosystem in
text-generation-webui is real but **stale and fragmented**.

**superboogav2** (in-tree extension,
https://github.com/oobabooga/text-generation-webui/tree/main/extensions/superboogav2).
Adds extra information from URLs/files/text-input as embeddings. Per the
README, it operates on **external data** added by the user, not on chat
transcript automatically. Manual "Add" / "Clear Data" controls. Active in
the sense of "still in the repo" but not heavily updated in 2024-2026
[inference from issue activity].

**long_term_memory** (wawawario2,
https://github.com/wawawario2/long_term_memory). The original LTM
extension. Uses `sentence-transformers/all-mpnet-base-v2` and scikit-learn
linear search against loaded embedding vectors. **Explicitly marked "no
longer in development"** per the runpod.io writeup
(https://www.runpod.io/blog/how-to-work-with-long-term-memory-in-oobabooga-and-text-generation
— "The original long_term_memory extension is no longer in development,
and anyone still using it should migrate"). Hacker News thread
(https://news.ycombinator.com/item?id=35944203) is from 2023. Dead.

**annoy_ltm** (YenRaven,
https://github.com/YenRaven/annoy_ltm). Uses Annoy ANN library for
nearest-neighbor retrieval over chat history. Described as "an experiment."
Single-author, low-maintenance. Was a successor to long_term_memory but
itself stalled per the underlines/awesome-ml list
(https://github.com/underlines/awesome-ml/blob/master/llm-tools.md).

**complex_memory** (theubie,
https://github.com/theubie/complex_memory). "A KoboldAI-like memory
extension." Stores memory entries inside the character JSON file, manually
curated, keyword-triggered. Static curated memory, not transcript
indexing.

**Verdict on Oobabooga:** The long-tail of LTM extensions exists but is
mostly **abandoned** or single-author experimental. The closest equivalent
to V0 Tier-1 (per-turn embedding of the chat transcript) is annoy_ltm; it
is essentially abandoned. superboogav2 is alive but operates on external
data, not transcripts. Nothing here is tiered, multi-card, disposable, or
tool-call-driven. The community has effectively migrated to SillyTavern
for this use case.

### Q1.3 — KoboldAI / koboldcpp

Per the Memory/Author's Note/World Info wiki page
(https://github.com/KoboldAI/KoboldAI-Client/wiki/Memory,-Author's-Note-and-World-Info)
and the koboldcpp wiki (https://github.com/LostRuins/koboldcpp/wiki):

- **Memory** = a fixed string injected at the top of the prompt
  (constant). Curated, not retrieved.
- **Author's Note** = constant string injected near the end. Curated.
- **World Info** = keyword-triggered curated entries, the original of the
  pattern that SillyTavern adopted. Inserted after Memory, before story
  text.
- **TextDB / `--embeddingsmodel`** (newer, koboldcpp). koboldcpp can now
  load a GGUF embedding model and expose `/v1/embeddings` and
  `/api/extra/embeddings`. KoboldAI Lite has a "TextDB" feature for vector
  search against arbitrary text. *Not* automatic chat-history indexing
  by default; it is a primitive that the user wires up. Useful as a
  finding for the multi-card question: koboldcpp explicitly supports
  loading a separate embedding model alongside the main LLM, and the
  endpoints are independent.

**Discussion thread #223** "Use embeddings instead of keywords for World
Info search"
(https://github.com/KoboldAI/KoboldAI-Client/discussions/223). Multi-year
discussion of moving World Info from keyword-trigger to semantic-trigger.
Implemented partially via the TextDB path; not a default.

**Verdict on KoboldAI:** Memory / Author's Note / World Info are curated
artifact patterns, not transcript indexing. Embedding endpoints exist but
are user-wired, not automatic. The "automatic per-turn embedding of the
transcript" pattern is **not** a default in KoboldAI; it is a default in
SillyTavern (which is the more common front-end for koboldcpp anyway).

### Q1.4 — Open-WebUI

Per the official docs
(https://docs.openwebui.com/features/chat-conversations/memory/,
https://docs.openwebui.com/features/chat-conversations/rag/) and the
DeepWiki mirror
(https://deepwiki.com/open-webui/open-webui/6.4-memory-and-context-management):

- **Memory feature** stores user-scoped extracted facts ("I prefer Python
  for backend tasks", "I live in Vienna") in a vector DB. Manually
  editable. As of recent versions with Native Function Calling, the model
  can manage its own memory via five tool calls (add/update/delete/list/
  query). This is the **fact-extraction** pattern — explicitly *not*
  Pattern 1 / V0. Same shape as ChatGPT Memory and Mem0.
- **RAG** operates on attached documents, not on the chat history itself
  by default. Hybrid BM25 + vector search via EnsembleRetriever
  (https://deepwiki.com/open-webui/open-webui/5.4-hybrid-retrieval-strategies).
  Cross-encoder reranker. Configurable via `ENABLE_RAG_HYBRID_SEARCH`,
  `HYBRID_BM25_WEIGHT`. Performance issue #20327 is open as of recent
  releases — BM25 reindexes per query, O(n) latency.
- **Reference Chat History** (discussion #13041,
  https://github.com/open-webui/open-webui/discussions/13041,
  and adaptive-memory plugin
  https://open-webui.com/open-webui-adaptive-memory/) is a *requested*
  feature; some plugin variants exist.

**Verdict on Open-WebUI:** RAG infrastructure is solid (hybrid, reranker,
cross-encoder) and is the most production-shaped of the hobbyist tools.
Memory is fact-extraction. Verbatim per-turn transcript indexing of the
*current* session is **not** the default and is approximated only by
adaptive-memory plugins.

### Q1.5 — AnythingLLM, LM Studio, Jan, Msty

**AnythingLLM** (Mintplex-Labs,
https://github.com/Mintplex-Labs/anything-llm). Document-oriented RAG
front-end. Workspace = documents + chat. Chat history is preserved per
workspace; documents are chunked + embedded + retrieved at query time. An
`agent_memory.txt` file exists for agent-mode "long-term memory" but
documentation is thin (issue #4821). Issue #3289 is an open feature request
for a Mem0-style memory layer integration. **Verbatim transcript indexing
of the current chat is not a documented feature**; chat history is just
appended to the prompt up to context-window limits.

**LM Studio** (https://lmstudio.ai/docs/app/basics/rag). "Chat with
Documents" feature. If document fits in context, full text is dropped in;
otherwise RAG-mode chunks and retrieves. Up to 5 files, 30 MB combined.
Citations at end of response. Embeddings via configurable models
(nomic-embed-text-v1.5, EmbeddingGemma). MCP support added in 0.3.17 (June
2025). **Chat history itself is not indexed for retrieval** — RAG operates
on attached documents only, per docs.

**Jan AI** (https://www.jan.ai/docs). Open-source ChatGPT alternative.
Stores chat history in local SQLite. **No documented automatic
transcript-indexing or RAG-over-chat-history feature** as of the current
docs. Standard "history is a list, eventually trimmed."

**Msty Studio** (https://docs.msty.studio/features/knowledge-stacks/overview).
Knowledge Stacks is the RAG primitive. Notably, the Next-Gen Knowledge
Stacks feature (https://docs.msty.studio/features/knowledge-stacks/next-gen)
allows **adding past conversations to a stack** — "you can add past
conversations into your stack, so your AI can reference things you've
already discussed." This is the closest of the four to V0, but the
mechanism is *user-curated* (you upload a Conversation Project) and the
stack is then queried as a generic document store. Not automatic per-turn,
not in-session, not tiered.

**Verdict on this group:** None of these tools default to indexing the
*current session* verbatim per-turn for retrieval. They all default to
"RAG on attached documents" plus "history fits, or it doesn't." Msty's
"add past conversations to a stack" is the most adjacent feature; it is
manual and cross-session.

### Q1.6 — In-session retrieval as a hobbyist pattern

The specific question — *does any hobbyist tool frame the current active
session as a retrieval artifact you query during the conversation, instead
of relying on summarization or sliding-window for in-session compaction?*

**SillyTavern Vector Storage answers yes, partially.** The *current chat*
is indexed message-by-message in the background, and verbatim messages
are shuffled into the prompt at generation time. But the model does not
*query* — the front-end injects. There is no `recall(query)` tool; the
"query" is just "the most recent 2 messages, embedded." This is the
in-session-retrieval mechanism, but in *push* form, not *pull* form.

**timeline-memory** (https://github.com/unkarelian/timeline-memory) is the
only hobbyist extension I found that wires retrieval as a **tool call**
the model invokes mid-conversation: `query_timeline_chapter`,
`query_timeline_chapters`. But the artifact queried is summary-based
chapters, not verbatim spans. 35 stars; one author; active in 2025.

**Hermes-LCM (Lossless Context Management)** (Stephen Schoettler,
https://github.com/stephenschoettler/hermes-lcm) is the most surprising
find of the entire survey, and the one closest to V0's exact framing,
*outside* the hobbyist roleplay scene. Hermes Agent is NousResearch's
agent framework; LCM is a third-party plugin. Per the README and
hermesatlas.com project page
(https://hermesatlas.com/projects/stephenschoettler/hermes-lcm):

- "Persists every message in a SQLite database organized by conversation."
- "Summarizes chunks of older messages into summaries using the configured
  LLM" — but the **raw messages stay in the database**, summaries link
  back to source messages, "agents can drill into any summary to recover
  the original detail."
- DAG of summary nodes; raw leaves are verbatim messages.
- Tools the agent calls **mid-conversation**: `lcm_grep`, `lcm_describe`,
  `lcm_expand`, `lcm_expand_query`, `lcm_status`.
- Explicit framing: "the agent gets an explicit, lossless, current-session
  recall path inside the plugin itself, avoiding reliance on an auxiliary
  cross-session retrieval step just to recover details from the
  conversation that was compacted in front of the agent."
- Large tool results are externalized to JSON files referenced by the
  database, addressable later via `lcm_describe(externalized_ref=...)`.

This is **V0 reframings 9 and 10 named and shipped as a plugin**, in the
hobbyist agent layer, modulo:

- Storage backend is SQLite, not a line-numbered text file, so retrieval
  granularity is the message, not the line.
- Retrieval is grep + LLM-summary expansion, not embedding-based dense
  retrieval (so semantic queries work less well).
- It *does* compact (DAG nodes summarize chunks); V0 says "never
  summarize." Hermes-LCM treats summaries as a navigation index *over*
  the verbatim store, not as a replacement. Functionally equivalent for
  retrieval, less pure for the "transcript is the artifact" framing.
- Single-card; no disposable-context or cross-card design.
- Not tiered in the cheap-vs-rich sense (everything is grep-shaped).
- License: not specified in search results [inference: unverified].
- Maintenance: cannot tell from search excerpts whether the plugin is
  actively maintained.

There is also a sibling plugin **lossless-claw**
(https://github.com/martian-engineering/lossless-claw) for OpenClaw, which
is the same pattern in a different harness. Per the proposal issue
(https://github.com/NousResearch/hermes-agent/issues/5701), the design is
explicitly being floated as a pluggable context-engine pattern across
multiple agent frameworks.

**This is the strongest existing analogue to V0 found in this survey.**
It is more directly a "verbatim current-session, agent recalls via tool
call, never lose a message" implementation than anything covered
yesterday — Claude memory tool and Letta/MemGPT recall are framed
cross-session; Hermes-LCM is framed *current-session*. The user's V0 is
not unique on the tool-call-into-current-session axis.

### Q1.7 — r/LocalLLaMA, r/SillyTavernAI, Hacker News surface

A direct-Reddit search via `site:reddit.com` returned no useful matches
[negative finding — Reddit indexing in web search is poor]. Indirect
evidence from how-to writeups and HN threads:

- HN "Ask HN: How do you give a local AI model long-term memory?"
  (https://news.ycombinator.com/item?id=46252809). Consensus: external
  vector DB plus aggressive summarization plus retrieval/eval loops. No
  one in the thread frames the *current session* as the retrieval
  artifact; all framing is cross-session or document-RAG.
- Older HN thread on the LTM extension for ooba
  (https://news.ycombinator.com/item?id=35944203) is from 2023 and
  predates most of the modern hobbyist tooling.
- Practitioner writeups (rpwithai.com, arsturn.com, the runpod.io blog,
  helloserver.tech, weisser-zwerg.dev, antlatt.com) almost all describe
  the standard stack: **summarize the old, vector-search the rest, attach
  documents for RAG.** The current-session-as-retrievable-artifact
  framing is not a named pattern in the practitioner literature I found.

**Verdict for Q1:** The hobbyist community has solved the *embedding +
verbatim retrieval* half of V0 (SillyTavern Vector Storage is mature and
default-on). It has *partially* solved the *tool-call mid-conversation*
half (timeline-memory; Hermes-LCM is the closest single implementation).
It has **not** solved tiered cheap/rich indexing, line-numbered
granularity, multi-card disposability, or temporal-aware routing as
default features in any tool surveyed.

---

## Q2 — Academic prototypes

The yesterday pass covered LongMemEval, LoCoMo, Mem0, Zep/Graphiti, and
the temporal-RAG/SelRoute literature. This pass widens the academic
lens.

### Q2.1 — Generative Agents (Park et al., 2023)

Park et al., UIST 2023 (arXiv:2304.03442,
https://ar5iv.labs.arxiv.org/html/2304.03442). The canonical design.
Mechanism specifics:

- **Memory stream** = chronological list of every observation, plan, and
  reflection. Each entry has a natural-language string, a creation
  timestamp, a most-recent-access timestamp, an importance score (LLM
  self-rated 1-10), and an embedding.
- **Retrieval scoring**: weighted sum of three signals, each
  min-max-normalized to [0,1] —
    - recency = exponential decay over time since last retrieval (decay
      factor 0.99 per simulated hour in the paper),
    - relevance = cosine similarity between memory embedding and query
      embedding,
    - importance = the LLM-rated importance score.
  α weights set to 1 in the paper (uniform).
- **Reflection** = periodically, the agent generates higher-level
  abstractions ("Klaus is dedicated to research") that are *also* added
  to the same memory stream as new entries with their own importance
  scores. So the stream is heterogeneous: raw observations + reflections
  + plans, all embedded, all retrievable.

How close is this to V0?

- **Memory stream is a verbatim store.** Yes, observations are stored as
  natural language. Match for V0's "store the words."
- **Retrieval is per-query, top-k.** Yes. Match.
- **Index is dense vector.** Yes — embedding-based retrieval over the
  whole stream. Match for V0 Tier-1.
- **Tiered features.** *Partial.* The importance score is an LLM-rated
  cheap-feature equivalent; reflections are a richer LLM pass. But
  reflection is *adding new abstract entries*, not enriching the index of
  existing entries. The closer-to-V0 framing — "embed first, classify
  later when idle" — is **not** what Generative Agents does.
- **Disposable context / multi-card.** Not addressed; this is a research
  simulator, not a system architecture.
- **In-session vs. cross-session.** Generative Agents has no "session"
  concept — agents run continuously over simulated days. The retrieval
  is *over their entire lifetime*. Functionally this is in-session +
  cross-session collapsed; matches V0's "session is the retrieval
  artifact" framing more than Claude/Letta's cross-session-only framing.

**Verdict:** Generative Agents is the most cited academic ancestor of
the V0 retrieval-scoring shape. It is **not** tiered in the V0 sense; it
*is* a unified-session retrieval design; it does not address the GPU /
disposability question (it predates the modern resident-model framing).

### Q2.2 — A-MEM (Xu et al., 2025)

A-MEM, arXiv:2502.12110 (Xu, Liang, Mei, Gao, Tan, Zhang, Rutgers/AGI
Research, https://arxiv.org/abs/2502.12110, code at
https://github.com/agiresearch/A-mem). Zettelkasten-inspired agentic
memory. Mechanism:

- **Note construction.** When a new memory is added, the system
  generates a structured note: contextual description, keywords, tags.
  This is an **LLM-generated rich-feature pass per memory** — a tiered
  step.
- **Link generation.** The system analyzes historical memories to
  identify relevant links. New edges added to a graph.
- **Memory evolution.** New memories can trigger updates to *existing*
  memory representations — i.e. the index is mutable.

How close to V0?

- **Verbatim store.** Yes, the note retains the original content plus
  generated metadata. Match.
- **Tiered indexing.** **Yes, sort of.** Note construction is an
  LLM-pass-per-memory; this is a "rich features at write time" approach,
  not "cheap inline + rich at compaction." A-MEM does the rich pass
  *eagerly* (every memory gets the LLM treatment) rather than lazily
  (compaction-time). Closer match than Generative Agents.
- **Multi-card.** Not addressed.
- **In-session.** A-MEM operates over a stream of memories, not
  specifically over a current session transcript. [Inference: the
  experiments use multi-session benchmarks like LongMemEval.]
- **Mutable index.** A-MEM updates older memory representations as new
  ones come in. V0 explicitly does not modify older entries (the
  transcript is append-only, but the *index* of the transcript could be
  modified — V0 does not address this).

**Verdict:** A-MEM is the closest match for the *tiered LLM-enrichment*
half of V0. Eager rather than lazy. Not multi-card. Not specifically
in-session. Strong overall design match for V0 V2.

### Q2.3 — MemoryBank (Zhong et al., 2023)

MemoryBank, arXiv:2305.10250 (https://arxiv.org/abs/2305.10250, AAAI 2024
https://ojs.aaai.org/index.php/AAAI/article/view/29946, code at
https://github.com/zhongwanjun/MemoryBank-SiliconFriend).

- Persistent vector store (FAISS) of memory pieces: dialogue turns, event
  summaries, personality snapshots. Mixed verbatim and summarized.
- Dense top-k similarity retrieval.
- **Ebbinghaus forgetting curve** for memory decay. Memories are
  reinforced or attenuated based on time and access. (Same conceptual
  family as Generative Agents' recency term, but explicitly framed as a
  forgetting model.)
- Productized as the SiliconFriend chatbot.

**Verdict:** Verbatim + summary mixed-store. Same retrieval mechanism as
Generative Agents (recency + relevance, plus importance via Ebbinghaus).
Not tiered in the cheap/rich sense. Not multi-card. Cross-session-first
framing.

### Q2.4 — MemGPT/Letta (covered yesterday)

Already covered in yesterday's research file
(`2026-04-24-session-as-artifact-and-temporal-retrieval-prior-art.md`,
Q1.1). Recall memory is verbatim; archival memory is processed. Not
tiered cheap-vs-rich. Single-card. Cross-session by design but the
recall tier *also* covers in-session because the conversation log is the
recall log.

### Q2.5 — MemoChat (Lu et al., 2023)

MemoChat, arXiv:2308.08239
(https://ar5iv.labs.arxiv.org/html/2308.08239). "Tuning LLMs to Use
Memos for Consistent Long-Range Open-Domain Conversation." Pipeline:
LLMs are tuned to (a) write self-composed memos summarizing topics, (b)
retrieve relevant memos when the topic recurs, (c) condition responses
on retrieved memos. Iterative *memorization-retrieval-response* cycle.

**Verdict:** Memo-based, not verbatim-based. The memo is a summary the
LLM writes. Same family as ConversationSummaryMemory in LangChain.
**Anti-pattern relative to V0.** Listed for completeness.

### Q2.6 — RecallM, ChatDB, MemoryLLM, Ret-LLM, SCM

- **RecallM** (https://www.emergentmind.com/topics/recallm). Hybrid Neo4j
  graph + ChromaDB vector store. Stores triples + embeddings. Cypher +
  similarity hybrid retrieval. **Mem0/Zep family** — fact-extraction +
  graph. Anti-pattern for V0.
- **ChatDB** (Hu et al., 2023). "Augmenting LLMs with databases as their
  symbolic memory." LLM writes SQL operations to record/recall facts.
  Symbolic, not verbatim-text.
- **MemoryLLM** (Wang et al., ICML 2024,
  https://github.com/wangyu-ustc/MemoryLLM). Self-updatable memory
  embedded in model weights. "Memory region within the weights" — not a
  retrieval system at all in the V0 sense.
- **Ret-LLM** (Modarressi et al., arXiv:2305.14322
  https://arxiv.org/abs/2305.14322; evolved into MemLLM,
  arXiv:2404.11672). Knowledge stored as triplets in an external memory
  unit. Read/write tool calls. Triplet store, not verbatim text.
- **SCM (Self-Controlled Memory)** (Liang et al., arXiv:2304.13343,
  https://arxiv.org/html/2304.13343, code at
  https://github.com/wbbeyourself/SCM4LLMs). Three components: LLM agent,
  memory stream (storing per-segment observations), memory controller
  (decides when to retrieve and what to retrieve). The memory stream
  *can* be verbatim segments; the controller is an LLM that decides
  retrieval. **Closer match to V0 in the controller-driven retrieval
  sense.** Uniform single-card design. Not tiered.

**Verdict for Q2.6:** RecallM/ChatDB/MemoryLLM/Ret-LLM are not
verbatim-store designs. SCM is partial — verbatim segments are possible
but not the focus, and there's no tiered indexing.

### Q2.7 — H-MEM, MAGMA, Memoria, EMem, HippoRAG

These are all 2024-2026 academic memory designs found in the Awesome-AI-
Memory list (https://github.com/IAAR-Shanghai/Awesome-AI-Memory).

- **H-MEM** (arXiv:2507.22925,
  https://arxiv.org/abs/2507.22925). Hierarchical memory with four
  layers: Domain → Category → Memory Trace → Episode. Each vector has a
  positional index pointing to its sub-memories. Layer-by-layer
  retrieval. **Hierarchical** but not tiered in the V0 sense — H-MEM's
  hierarchy is over *abstraction levels*, not over *index richness at
  the same level*. Different axis.
- **MAGMA** (arXiv:2601.03236). Multi-graph: orthogonal
  semantic/temporal/causal/entity graphs. Retrieval as policy-guided
  traversal. Architectural match for V0 V2's temporal routing — multiple
  index views, query-adaptive selection. But not specifically
  in-session.
- **Memoria** (arXiv:2512.12686). Session-level summarization +
  weighted KG user model. **Anti-pattern** — summary-driven.
- **EMem-G/EMem** (arXiv:2511.17208, "A Simple Yet Strong Baseline").
  Explicitly anti-compression: "rather than using aggressive compression
  or independent relation triples, the research proposes an
  event-centric representation … aiming to preserve information in
  non-compressive form." Elementary Discourse Units (EDUs) as the
  retrieval unit. **Verbatim-leaning baseline.** Strong intellectual
  match for V0's "preserve, don't compress" stance.
- **HippoRAG** (arXiv:2405.14831). Hippocampal-indexing-inspired graph +
  PageRank retrieval. Knowledge-graph-shaped, not verbatim-text-shaped.
  Anti-pattern for V0 directly, but the "neurobiologically inspired"
  framing is interesting context.

### Q2.8 — Has any academic system specifically targeted in-session
transcript retrieval as a substitute for compaction?

This is the sharpest version of the V0 question. Searching for "in-session
retrieval", "current conversation retrieval", "compaction substitute" via
arXiv-targeted queries surfaces:

- **EMem-G** (arXiv:2511.17208) — explicitly anti-compression, but
  framed at multi-session benchmarks, not "single-active-session
  retrieval substituting for compaction."
- **Microsoft Agent Framework Compaction docs**
  (https://learn.microsoft.com/en-us/agent-framework/agents/conversations/compaction)
  describe "context compaction (reversible)" — strip information that
  exists elsewhere; the agent can re-read via tool. This is the V0
  intuition stated in production-doc form: *retrieve from elsewhere
  instead of compacting*. But "elsewhere" is the file system / tool
  output, not the *current session transcript*.
- **Lethain's writeup** "Building an internal agent: Context window
  compaction" (https://lethain.com/agents-context-compaction/). Standard
  summarization-based compaction. No retrieval-substitute framing.
- **Hermes-LCM** (https://github.com/stephenschoettler/hermes-lcm —
  same as above). Already discussed; this *is* the explicit framing.
  Hobbyist plugin, not academic.

**Negative finding worth stating clearly:** I did not find a peer-reviewed
academic paper that specifically frames "verbatim retrieval over the
current session transcript as a *substitute for* compaction within the
same conversation." The conceptual primitives are everywhere
(MemGPT/Letta, Generative Agents, A-MEM, EMem-G); the *specific framing
of in-session retrieval replacing compaction* is more visible in
engineering writeups (Microsoft's compaction doc, Hermes-LCM, the
TianPan event-sourcing post from yesterday) than in academic papers.

**Verdict for Q2:** The academic literature has shipped most of the V0
ingredients separately:

- Verbatim store + retrieval: MemGPT/Letta, Generative Agents, MemoryBank.
- Tiered LLM-enrichment over memory: A-MEM (eager), Generative Agents'
  reflection (eager).
- Hierarchical structure: H-MEM (different axis from V0's tiering).
- Anti-compression baseline: EMem-G.
- Controller-driven retrieval: SCM, MemoChat (with summaries).

The *specific* framing — single active session, line-numbered transcript,
tiered cheap/rich, retrieval substitutes for compaction — is **not** a
named published academic pattern as of this survey. Hermes-LCM is the
closest existing implementation in any layer, and it is hobbyist code.

---

## Q3 — Tiered indexing in either community

The V0 claim under test: cheap features (embedding + parsed tags) inline
per-turn; rich features (LLM classification, entity extraction, discourse
tags) lazily during compaction or idle time.

**Hobbyist:**

- **SillyTavern Vector Storage** does only the cheap tier. Embedding + a
  hash + chunk metadata. Nothing richer.
- **CharMemory / SillyTavern-MemoryBooks / TunnelVision / timeline-memory**
  do *only* the rich tier (LLM-extracted summary + lorebook entry). No
  cheap-tier-first-then-rich-later pipeline.
- **Hermes-LCM** has summaries-of-chunks layered over verbatim raw, which
  is a form of two-tier index over the same store. Not "cheap inline
  plus rich at compaction" — it is "verbatim per-message + LLM-summary
  per-chunk." Different axis but architecturally adjacent.
- **No SillyTavern extension I found explicitly stages a cheap-features-
  inline + rich-features-lazy pipeline** (negative finding).

**Academic:**

- **A-MEM** runs a rich LLM pass *eagerly* per-memory. Same set of
  features as V0 V2's rich tier (descriptions, keywords, tags), but
  eager.
- **Generative Agents** assigns importance via LLM eagerly per-memory;
  reflections are richer/lazier (periodic LLM pass) but they create
  *new* memory entries rather than enriching existing ones.
- **H-MEM** builds hierarchy across abstraction levels, not across
  feature richness at the same level.
- **The cheap-inline + rich-lazy-at-compaction pattern as such is not
  named in the academic memory literature I surveyed** (negative
  finding). The closest production-doc statement is Microsoft's Agent
  Framework Context Compaction page, which describes asynchronous
  LLM-summary compaction in a sliding window
  (https://learn.microsoft.com/en-us/agent-framework/agents/conversations/compaction)
  — but the work being deferred is summarization for storage, not
  *enrichment of an index*.

**Verdict for Q3:** Tiered indexing where cheap features go inline
per-turn and rich features come at compaction/idle time is **not a
commodity pattern** in either community. A-MEM does the rich pass
eagerly. Hermes-LCM has a two-tier store but not a two-tier index. V0's
specific staging — embed inline, classify on idle — is not a named
pattern in the literature.

This is a meaningful finding. The user's V0 is not novel in *concept*
(deferred work is a standard engineering move) but appears to be novel
in *naming* the cheap/rich split as a memory-system architecture point.

---

## Q4 — Disposable-context / cross-card retrieval

The V0 claim under test: a small embedding/retrieval model resident on
*card 2* with explicit KV cache reset between queries; the primary stays
resident on *card 1*.

### Q4.1 — Multi-card homelab patterns observed

- **TEI (text-embeddings-inference)** (HuggingFace,
  https://github.com/huggingface/text-embeddings-inference). Standalone
  embedding inference server. Supports CUDA, ROCm (AMD MI200/MI300), CPU.
  Designed to run as its own service, often on its own GPU. Issue #87
  (https://github.com/huggingface/text-embeddings-inference/issues/87)
  is the report that TEI uses only one GPU on a multi-GPU node — i.e.
  TEI is single-GPU per service, but you run **multiple services pinned
  to different GPUs** to spread the load. This is the production pattern
  for separate-card embeddings.
- **Ollama multi-GPU** (per
  https://www.knightli.com/en/2026/04/19/ollama-multiple-gpu-notes/ and
  ollama issue #11986). Globally splits via `CUDA_VISIBLE_DEVICES`;
  per-model GPU pinning is **not** a built-in feature. Issue #5093
  documents this. So under Ollama, you cannot natively say "embed on GPU
  1, generate on GPU 0" — you have to run two Ollama instances or use a
  different runtime for one of them.
- **llama.cpp / koboldcpp** support `--main-gpu` and `--tensor-split` for
  splitting one model across cards, and you can run separate processes
  pinned to separate cards. koboldcpp's `--embeddingsmodel` exposes a
  separate embedding endpoint that can be a different GGUF on a
  different card via process boundary
  (https://github.com/LostRuins/koboldcpp/wiki).
- **ROCm** (AMD) supports multi-GPU inference but homelab practitioners
  report scaling issues with dual 7900 XTX
  (https://forum.level1techs.com/t/dual-gpu-7900xtx-vfio-ollama-llm-bad-scaling/229768)
  on PCIe 4.0 x8 — GPU load doesn't exceed 50%. This is the
  *tensor-parallelism* failure mode; the V0 design avoids it by running
  *different models on different cards* rather than splitting one model.
- **Asymmetric setups** (one GPU for inference, another for STT/TTS or
  preprocessing) are mentioned in passing in dev.to writeups
  (https://dev.to/rushichaudhari/training-llms-on-mixed-gpus-my-experiments-and-what-i-learnt-1k7n)
  but are not common.

**TEI + Qdrant on multi-GPU** (Hsu blog,
https://chaochunhsu.github.io/patterns/blogs/tei_qdrant_cache/) describes
running TEI on a dedicated GPU with Qdrant on CPU/another GPU — a
production-shaped multi-card embedding pipeline. This is the closest
direct analogue to V0's "card 2 = embedder + retrieval specialist."

### Q4.2 — Disposable-context (KV cache reset between queries)

This is the more specific axis. Searching for "KV cache reset" + "embedding"
+ "stateless" surfaces a different conversation than V0 expects:

- **KV cache reuse / persistence** is the dominant production framing.
  vLLM, TensorRT-LLM, NVIDIA's KV-cache-offload work
  (https://developer.nvidia.com/blog/optimizing-inference-for-long-context-and-large-batch-sizes-with-nvfp4-kv-cache/,
  https://developer.nvidia.com/blog/introducing-new-kv-cache-reuse-optimizations-in-nvidia-tensorrt-llm/),
  BentoML's KV-cache-offload guide
  (https://bentoml.com/llm/inference-optimization/kv-cache-offloading)
  all framed around **avoiding** disposability — preserve KV across
  requests for prefix caching benefits.
- **Stateless inference** is more often discussed in the
  embedding-server context: an embedding model is a single forward pass,
  no autoregressive KV. So an embedding service is *naturally* disposable
  — there is nothing to reset.
- **Disposable context for a small generative LLM used as a retrieval
  oracle** — i.e. the V0 framing where you load a small LLM, give it
  (query + index), get back line numbers, then *reset its KV cache* — is
  **not a named pattern in any source I found**. The closest published
  primitive is llama.cpp's slot save/restore (mentioned in the user's
  V3+ multi-user time-slicing note), which is the right primitive but is
  used in production for *preserving* state, not deliberately wiping it.

### Q4.3 — Multi-card homelab "embedding on card 2" as default

Most homelab writeups in 2024-2026 (the "Adding AI to my Homelab with an
eGPU" post, https://olav.ninja/adding-ai-to-my-homelab-with-an-egpu;
weisser-zwerg.dev's scaling guide) assume **one card** does everything.
Two-card setups are typically used to fit a *bigger model* via
tensor-parallel split, not to dedicate cards to different roles. The
asymmetric-roles pattern (card 1 = generation, card 2 = embedding +
retrieval) appears in production ML stacks (TEI separate from main
inference) but is **not a default homelab configuration**.

The "small resident retrieval model on card 2 with deliberate KV reset
between queries" pattern is, as far as this survey can tell, **not a
named pattern anywhere — production, hobbyist, or academic.** This is
the strongest negative finding of the entire survey, and it is consistent
with the user's V0 reframing 10 being genuinely original at the
configuration level.

### Verdict for Q4

- **Separate-card embeddings**: production pattern (TEI), not a homelab
  default but achievable with separate processes / runtimes.
- **Different-models-on-different-cards (asymmetric roles)**: rare in
  homelab, exists in production ML stacks.
- **Deliberate KV cache reset between queries on a small generative
  retrieval model**: not found as a named pattern. The closest analogue
  is "use a stateless embedding service," which is one step weaker —
  it doesn't use a generative model at all.
- **The combination — small *generative* retrieval model on card 2,
  treated as a disposable-context oracle the primary calls via tool —
  appears to be unclaimed.**

---

## Synthesis

### What's commodity in hobbyist/academic space (and was missed by yesterday)

1. **Per-message embedding of the current chat with verbatim-span
   injection at generation time.** SillyTavern Vector Storage, default
   on, single-card, automatic. This is the V0 Tier-1 mechanism, shipped
   in the largest hobbyist front-end. Yesterday's research focused on
   Claude/Letta/LangChain at the production layer and missed the
   hobbyist incumbent.
2. **Tool-call mid-conversation recall over verbatim current-session
   storage.** **Hermes-LCM** (Schoettler,
   https://github.com/stephenschoettler/hermes-lcm) and lossless-claw
   (https://github.com/martian-engineering/lossless-claw). This is
   reframing 9 + reframing 10 named and shipped, in the hobbyist agent
   layer. Modulo storage backend (SQLite vs. line-numbered file) and
   retrieval shape (grep vs. embedding), it is structurally what V0
   describes. **The single most important finding of this survey.**
3. **Eager tiered LLM-enrichment per memory.** A-MEM
   (arXiv:2502.12110) does what V0 V2 envisions (description + keywords
   + tags via LLM) eagerly per memory. The cheap-tier-inline / rich-
   tier-lazy split that V0 proposes is *not* what A-MEM does, but the
   feature set is the same.
4. **Recency + relevance + importance retrieval scoring.** Generative
   Agents (Park et al., 2023) is the textbook reference and is widely
   reimplemented.
5. **Anti-compression event-centric retrieval baselines.** EMem-G
   (arXiv:2511.17208) — explicit "preserve, don't compress" stance over
   discourse units.

### What's genuinely uncommon in hobbyist/academic space

1. **Tiered indexing where cheap features go inline per-turn and rich
   features come at compaction/idle time.** Not a named pattern in
   either community. A-MEM is eager; SillyTavern Vector Storage is
   cheap-only; Generative Agents has reflection (lazy) but it adds new
   memories rather than enriching existing index entries. **V0's
   cheap/rich split, deferred to idle, is unclaimed framing.**
2. **Line-numbered transcript granularity.** The literature uses
   "messages" or "rounds" or "EDUs"; line-level granularity is not
   discussed. [Inference: probably because most published systems work
   at the chat/message level; line-level granularity matters most for
   code-heavy or technical conversations where a single message is a
   large blob.]
3. **Disposable-context generative retrieval model on a separate GPU.**
   Production ML uses dedicated embedding services on separate GPUs
   (TEI), but those are stateless embedding models, not small generative
   LLMs used as retrieval oracles with deliberate KV resets. This
   specific combination — small generative retriever, separate card,
   stateless-by-policy — is not found.
4. **Temporal-aware state-vs-history routing over the transcript.**
   Already established as not-found in yesterday's research; this
   survey did not change that picture.

### Combinations unclaimed

The closest existing single system to the full V0 stack is **Hermes-LCM**
(verbatim current-session, tool-call recall, agent-driven retrieval,
DAG-based summary index over raw store). What Hermes-LCM does *not* have
that V0 proposes:

- Embedding-based retrieval (Hermes-LCM is grep + LLM-summary expansion).
- Cheap/rich tiered indexing.
- Cross-card disposable-context retrieval.
- Line-numbered granularity.
- Temporal-aware routing.

The single existing system closest on the *retrieval-on-current-session*
axis is SillyTavern Vector Storage (embedding-based, automatic,
default-on), but it lacks tool-call invocation, tiered indexing, and
multi-card disposability.

**The full V0 stack — verbatim line-numbered transcript + tiered
cheap/rich indexing + tool-call retrieval + disposable-context model on
a separate GPU + temporal-aware routing — is not implemented as a single
system anywhere I found.** Each *individual* component exists in some
form somewhere; the combination is unclaimed. This is the same shape of
finding as yesterday's Pattern 1 + Pattern 2 verdict — the soup is novel,
the ingredients are not — but extended to two more axes (the tiered
indexing axis and the multi-card disposability axis).

### What yesterday's framing should be revised to say

Yesterday's session-notes synthesis claimed: "The literature measurably
prefers verbatim retrieval (+12.4 R@5 per LongMemEval) over LLM-summary
extraction, but the production systems (Mem0, ChatGPT Memory) shipped
summary."

Today's correction: **the hobbyist layer also shipped verbatim
retrieval, before the production layer did.** SillyTavern's Vector
Storage has been default-on for verbatim per-message embedding +
verbatim-span injection for at least the LongMemEval era. The
production-vs-measurement gap that yesterday's research framed is real
at the *commercial-product* layer (ChatGPT, Mem0), but it is *not* a
hobbyist-vs-academic gap. The hobbyist layer is closer to the
measured-better thing than the commercial layer is.

The portfolio framing in
`2026-04-24-session-notes-full.md` lines 241-244 ("we will not claim
novelty on Pattern 1") is correct and should be reaffirmed. The
substantive claims V0 can make are:

- **Tiered cheap/rich indexing as a memory-system axis** (genuinely
  uncommon framing, even if deferred-work is a standard engineering
  move).
- **Disposable-context generative retrieval on a separate GPU**
  (combination not found).
- **In-session retrieval explicitly substituting for compaction with
  embedding-based dense retrieval over a line-numbered transcript**
  (Hermes-LCM is the closest, but uses grep + summary-expansion; the
  embedding-based, line-numbered version is unclaimed).
- **Temporal-aware state-vs-history routing layered on the above**
  (yesterday's Pattern 2; remains unclaimed).

---

## Citations index (deduplicated)

### Hobbyist / homelab

- SillyTavern Chat Vectorization docs —
  https://docs.sillytavern.app/extensions/chat-vectorization/
- SillyTavern Smart Context (deprecated) —
  https://docs.sillytavern.app/extensions/smart-context/;
  https://github.com/SillyTavern/SillyTavern/issues/2625
- SillyTavern Data Bank / Vector Storage —
  https://docs.sillytavern.app/usage/core-concepts/data-bank/;
  https://deepwiki.com/SillyTavern/SillyTavern/6.3-vector-storage-and-rag-system;
  https://deepwiki.com/SillyTavern/SillyTavern/6-context-and-memory-systems
- SillyTavern Summarize —
  https://docs.sillytavern.app/extensions/summarize/
- SillyTavern World Info —
  https://docs.sillytavern.app/usage/core-concepts/worldinfo/
- SillyTavern-Extras (obsolete) —
  https://github.com/SillyTavern/SillyTavern-Extras
- timeline-memory (unkarelian) —
  https://github.com/unkarelian/timeline-memory
- TunnelVision (Coneja-Chibi) —
  https://github.com/Coneja-Chibi/TunnelVision;
  https://github.com/deadbranch-forks/TunnelVision-sillytavernyp
- SillyTavern-MemoryBooks (aikohanasaki) —
  https://github.com/aikohanasaki/SillyTavern-MemoryBooks
- sillytavern-character-memory (bal-spec) —
  https://github.com/bal-spec/sillytavern-character-memory
- SillyTavern-ReMemory (InspectorCaracal) —
  https://github.com/InspectorCaracal/SillyTavern-ReMemory
- arkhon_memory_st (kissg96, archived) —
  https://github.com/kissg96/arkhon_memory_st_archive
- Oobabooga superboogav2 —
  https://github.com/oobabooga/text-generation-webui/tree/main/extensions/superboogav2
- Oobabooga long_term_memory (wawawario2, unmaintained) —
  https://github.com/wawawario2/long_term_memory;
  https://news.ycombinator.com/item?id=35944203;
  https://www.runpod.io/blog/how-to-work-with-long-term-memory-in-oobabooga-and-text-generation
- annoy_ltm (YenRaven) —
  https://github.com/YenRaven/annoy_ltm
- complex_memory (theubie) —
  https://github.com/theubie/complex_memory
- KoboldAI Memory / Author's Note / World Info —
  https://github.com/KoboldAI/KoboldAI-Client/wiki/Memory,-Author's-Note-and-World-Info
- KoboldAI embedding-via-keywords proposal —
  https://github.com/KoboldAI/KoboldAI-Client/discussions/223
- koboldcpp wiki (TextDB / `--embeddingsmodel`) —
  https://github.com/LostRuins/koboldcpp/wiki
- Open-WebUI memory docs —
  https://docs.openwebui.com/features/chat-conversations/memory/;
  https://deepwiki.com/open-webui/open-webui/6.4-memory-and-context-management
- Open-WebUI hybrid retrieval —
  https://deepwiki.com/open-webui/open-webui/5.4-hybrid-retrieval-strategies
- Open-WebUI Reference Chat History discussion —
  https://github.com/open-webui/open-webui/discussions/13041
- Open-WebUI Adaptive Memory plugin —
  https://open-webui.com/open-webui-adaptive-memory/
- AnythingLLM repo + memory-feature request —
  https://github.com/Mintplex-Labs/anything-llm;
  https://github.com/Mintplex-Labs/anything-llm/issues/3289;
  https://github.com/Mintplex-Labs/anything-llm/issues/4821
- LM Studio RAG docs —
  https://lmstudio.ai/docs/app/basics/rag;
  https://deepwiki.com/lmstudio-ai/docs/8.3-retrieval-augmented-generation-(rag)
- Jan AI docs —
  https://www.jan.ai/docs
- Msty Knowledge Stacks (Next-Gen) —
  https://docs.msty.studio/features/knowledge-stacks/overview;
  https://docs.msty.studio/features/knowledge-stacks/next-gen
- Hermes-LCM (Stephen Schoettler) —
  https://github.com/stephenschoettler/hermes-lcm;
  https://hermesatlas.com/projects/stephenschoettler/hermes-lcm;
  https://github.com/stephenschoettler/hermes-lcm/blob/main/engine.py;
  https://github.com/stephenschoettler/hermes-lcm/blob/main/plugin.yaml
- Hermes-Agent + LCM-as-plugin proposal —
  https://github.com/NousResearch/hermes-agent/issues/5701;
  https://hermes-agent.nousresearch.com/docs/developer-guide/context-compression-and-caching
- lossless-claw (Martian Engineering) —
  https://github.com/martian-engineering/lossless-claw
- HN "Ask HN: How do you give a local AI model long-term memory?" —
  https://news.ycombinator.com/item?id=46252809
- rpwithai SillyTavern long-chat guide —
  https://rpwithai.com/how-to-manage-long-chats-on-sillytavern/

### Academic

- Park et al., Generative Agents, UIST 2023, arXiv:2304.03442 —
  https://ar5iv.labs.arxiv.org/html/2304.03442
- Xu et al., A-MEM, arXiv:2502.12110 —
  https://arxiv.org/abs/2502.12110;
  https://github.com/agiresearch/A-mem
- Zhong et al., MemoryBank, arXiv:2305.10250 —
  https://arxiv.org/abs/2305.10250;
  https://ojs.aaai.org/index.php/AAAI/article/view/29946;
  https://github.com/zhongwanjun/MemoryBank-SiliconFriend
- Lu et al., MemoChat, arXiv:2308.08239 —
  https://ar5iv.labs.arxiv.org/html/2308.08239
- Liang et al., SCM, arXiv:2304.13343 —
  https://arxiv.org/html/2304.13343;
  https://github.com/wbbeyourself/SCM4LLMs
- Modarressi et al., Ret-LLM / MemLLM, arXiv:2305.14322 —
  https://arxiv.org/abs/2305.14322
- Wang et al., MemoryLLM, ICML 2024 —
  https://github.com/wangyu-ustc/MemoryLLM
- Hu et al., RecallM —
  https://www.emergentmind.com/topics/recallm
- Gutiérrez et al., HippoRAG, arXiv:2405.14831 —
  https://arxiv.org/abs/2405.14831
- H-MEM, arXiv:2507.22925 —
  https://arxiv.org/abs/2507.22925
- MAGMA, arXiv:2601.03236 —
  https://arxiv.org/html/2601.03236v1
- Memoria, arXiv:2512.12686 —
  https://arxiv.org/html/2512.12686v1
- EMem-G/EMem, arXiv:2511.17208 —
  https://arxiv.org/abs/2511.17208
- Awesome-AI-Memory list (IAAR-Shanghai) —
  https://github.com/IAAR-Shanghai/Awesome-AI-Memory

### Multi-card / homelab GPU configuration

- HuggingFace TEI —
  https://github.com/huggingface/text-embeddings-inference;
  https://huggingface.co/docs/text-embeddings-inference/index
- TEI single-GPU-per-instance issue —
  https://github.com/huggingface/text-embeddings-inference/issues/87
- TEI + Qdrant multi-GPU pattern (Hsu) —
  https://chaochunhsu.github.io/patterns/blogs/tei_qdrant_cache/
- Ollama multi-GPU notes —
  https://www.knightli.com/en/2026/04/19/ollama-multiple-gpu-notes/;
  https://github.com/ollama/ollama/issues/5093;
  https://github.com/ollama/ollama/issues/11986
- llama.cpp Vulkan multi-GPU performance —
  https://github.com/ggml-org/llama.cpp/discussions/10879;
  https://github.com/ggml-org/llama.cpp/discussions/15021
- Dual 7900 XTX scaling Level1Techs thread —
  https://forum.level1techs.com/t/dual-gpu-7900xtx-vfio-ollama-llm-bad-scaling/229768
- ROCm multi-GPU docs —
  https://rocm.docs.amd.com/en/latest/how-to/rocm-for-ai/fine-tuning/multi-gpu-fine-tuning-and-inference.html
- HeteroGPU (mixed-vendor pipeline parallelism) —
  https://dev.to/rushichaudhari/training-llms-on-mixed-gpus-my-experiments-and-what-i-learnt-1k7n
- KV cache reuse (NVIDIA TensorRT-LLM) —
  https://developer.nvidia.com/blog/introducing-new-kv-cache-reuse-optimizations-in-nvidia-tensorrt-llm/
- KV cache offloading (BentoML guide) —
  https://bentoml.com/llm/inference-optimization/kv-cache-offloading

### Engineering writeups on compaction / context management

- Microsoft Agent Framework Compaction —
  https://learn.microsoft.com/en-us/agent-framework/agents/conversations/compaction
- Lethain on internal-agent context-window compaction —
  https://lethain.com/agents-context-compaction/
- Google Developers context-aware multi-agent framework —
  https://developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/
- Phil Schmid context-engineering part 2 —
  https://www.philschmid.de/context-engineering-part-2
- Claude Code session memory (claudefa.st) —
  https://claudefa.st/blog/guide/mechanics/session-memory
- claude-history (Raine) —
  https://github.com/raine/claude-history
