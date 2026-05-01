# Full Session Notes -- 2026-04-24 Architecture Brainstorming

**Audience:** future-us (next session, after context reset). Read this to pick up
where we stopped without needing to reconstruct the thinking from the raw research
files. It complements but doesn't replace `2026-04-24-conversation-notes-architecture-thinking.md`
(which is more journal-shaped) and the six research reports in this folder.

**Scope:** an extended brainstorming session that started from "what else can we
offload to card 2?" and ended with a specific V0 plan for a retrieval-based session
memory system.

---

## TL;DR of where we landed

- **The primary model's only irreplaceable job is generating user-facing tokens.**
  Everything else (retrieval, summarization, classification, memory, observation,
  validation) is infrastructure and belongs wherever it's cheapest.
- **Session state should live as a verbatim, growing, line-numbered transcript
  artifact on NVMe.** The live KV cache is ephemeral; the transcript is durable.
  Never summarize it.
- **Retrieval over the transcript uses disposable-context on card 2**: a small
  resident model whose KV cache is reset between queries. The primary calls
  `recall(query)` and gets back verbatim line spans.
- **Indexes of the transcript live dynamically in DRAM**, loaded from NVMe when
  needed, kept warm because 64 GB is more than enough.
- **Indexing is tiered**: cheap per-turn inline (card 2), medium+rich during
  compaction pauses (card 1 or card 2 -- empirical, to be benchmarked).
- **Correctness invariant**: at compaction boundaries, the index is guaranteed
  complete up to the compaction horizon. Retrieval only trusts material up to
  the last compaction; everything after is in live KV anyway.
- **Temporal retrieval routing** (state queries vs. history queries) is the
  candidate novel contribution. The underlying components are all published;
  the combination is not.
- **Coordinator should be Python on CPU**, not a model. It calls small models
  as subroutines when judgment is needed. This matches all surveyed production
  systems except NVIDIA's RL-trained Orchestrator-8B.
- **Best-fit routing is a curation problem, not a runtime problem.** Admin picks
  models per use case on quarterly cadence, using public benchmarks + local
  reference sets. Runtime is a dictionary lookup.
- **Use cases are discovered, not invented.** Git history seeds initial
  distribution; monitor logs ongoing. Public benchmarks provide the taxonomy.
- **Seven architectural shapes for session state exist.** The literature
  measurably prefers verbatim retrieval (+12.4 R@5 per LongMemEval) over
  LLM-summary extraction, but the production systems (Mem0, ChatGPT Memory)
  shipped summary. For a homelab with no scale/privacy/latency pressure, the
  measured winner is available to us.

## V0 spec (concrete, buildable in days)

- Single session, single user.
- Card 2 hosts a small embedder (mxbai-embed-large already planned) and a
  resident small model for retrieval queries.
- After each turn completes: card 2 produces an index entry (embedding +
  basic tags: speaker, turn number, timestamp, length, contains-code,
  contains-citation). No LLM in this path -- just embedder + CPU parsing.
- Index entries stored in DRAM (working copy) and NVMe (durable).
- Primary has a `recall(query)` tool. Call flow:
  1. Primary emits tool call.
  2. Fabric resets card 2's retrieval-context KV.
  3. Sends (query + full session index) to card 2.
  4. Card 2 returns line-number verdicts.
  5. Fabric fetches those line spans from NVMe (transcript file).
  6. Returns verbatim lines + citations to primary.
- **No compaction yet.** V0's demo case is a long single session near the
  compaction boundary where recall is useful but compaction hasn't triggered.
- **Indexing scope: exchange only** (user message + assistant final response).
  Thinking/tool-use traces stored separately on NVMe but not indexed at V0.
- **No temporal routing yet.** Naive semantic retrieval. V0 explicitly will
  fail on supersession-sensitive queries -- measured as a known limitation to
  motivate V1/V2.

**Prerequisite artifacts before building V0:**

1. **Tier-1 indexing spec** -- one-page document specifying exactly what an
   index entry contains, which card does what, persistence format. We agreed
   we can't benchmark until we know what we're benchmarking.
2. **Tier-1 benchmark protocol** -- throughput, latency, retrieval quality on
   known-answer recalls. Based on existing `scripts/stress-test-stage1-card2.sh`
   + additions for end-to-end "turn completes -> index persists" wall-clock.

## V1 (later)

- Compaction on card 1. User sees an explicit pause.
- Parallel or sequential indexing during compaction window -- benchmarked
  to pick the faster path. Fabric supports both modes.
- Correctness invariant enforced: at resume, index is complete up to
  compaction horizon. Retrieval past that falls through to "still indexing,
  please wait."
- First real stress test for the disposable-context retrieval model.

## V2 (later still)

- Medium-tier indexing: rhetorical classification, topic tagging, entity
  extraction. LLM pass on card 2 (when idle) or card 1 (during compaction).
- Temporal query routing: state vs. history taxonomy (from LongMemEval).
  Primary declares query class when it calls `recall(query, mode="state")`.
- Supersession detection: turn N supersedes turn M on topic X. Uses the
  state-change dictionary / discourse-act ontology **if and only if** the
  parser survey finds a workable off-the-shelf parser. We do not build a
  taxonomy from scratch -- this is the explicit finding from the end-of-session
  research dispatch.
- **Trace-informed metatextual indexing** ("only exchange survives into the
  transcript and index, but the internal monologue shapes the metatextual
  index"). A/B tested against exchange-only indexing.

## V3+ (deferred)

- Cross-session retrieval. Falls out naturally once V0-V2 primitives work.
- Multi-user time-slicing via llama.cpp slot save/restore.
- Three-tier indexing scheduler with fairness + prefix locality (DLPM
  principles from arxiv:2501.14312).
- Registry + classifier + miss-logger for curation-driven routing.

---

## How we got here -- the ten reframings in order

This is the reasoning chain. Each reframing subsumed the last.

### Reframing 1: generation vs. everything else

Started from "active vs. passive context" which was fuzzy. Sharpened to:
primary's only irreplaceable job is generating user-facing tokens. All else
(retrieval, ranking, summarization, classification, memory, observation,
validation) is infrastructure placeable wherever cheapest.

### Reframing 2: three buckets of "passive"

- **Active**: primary generating.
- **Concurrent-passive**: runs while primary generating. Must be off-card
  for VRAM. (Watcher, live classifier, ingest embedding.)
- **Serial-passive**: runs while primary idle/unloaded. Can use card 1
  transient, card 2, CPU. (Compaction, overnight ingest, consolidation.)

Serial-passive was newly legal once swap time was deemed acceptable.

### Reframing 3: coordinator is a collection of concerns, not a thing

Different coordination concerns have different natural homes:
lifecycle=CPU program; routing=CPU+card-2 classifier when uncertain;
handoff detection=card-2 model; compaction=CPU scheduler triggering
card-1-transient; critique=card-2 model concurrent; permission gating=CPU
program. Dispatcher is Python calling LLM subroutines, not a model itself.

### Reframing 4: transient large specialist as a VRAM-budget trick

Stateless single-shot tasks don't need long KV. Swap the large tenant out
of card 1, load a bigger model temporarily with only a few thousand tokens
of context, run one turn, swap back. Works if you have the context-switch
mechanism (KV save/restore + mmap-warm weights).

### Reframing 5: arenas not roles

Stopped thinking "card 1 = primary, card 2 = support." Each resource is
*capacity* that gets assigned. Coordinator's real job is maintaining a live
assignment of "what's in each arena now" and transitioning cleanly.

### Reframing 6: best-fit is a curation problem

The hardest ML-looking question (does the system pick the right model?)
was dissolved by moving it out of runtime. Admin picks per-use-case on
quarterly cadence. Runtime is dictionary lookup.

### Reframing 7: use cases are discovered, not invented

Don't build a custom taxonomy. Public benchmarks already classify. Model
releases come pre-scored. Git history shows actual distribution of work.
Monitor logs catch what git doesn't (chat, explanations, one-offs).
Generalist serves unknowns; misses feed back into quarterly ritual.

### Reframing 8: storage-bounded registry, ranked-choice over deduplicated models

Algorithm: slots are voters weighted by frequency; models are candidates
scored by sum of slot-frequencies they're best-fit for; load in descending
score until disk full; reassign unseated slots to highest-scoring seated
model (often the generalist); admin can pin 2-3 specialists. All committed
to git so the history is the system's self-documentation.

### Reframing 9: transcript-as-retrievable-artifact -- Josh's critical move

The breakthrough. Instead of handing state off between models, keep the
full verbatim transcript as a durable growing artifact with an index.
When any model needs prior context, it retrieves the original lines via
tool call. Transcript never moves, never summarizes. The handoff problem
dissolves because there's nothing to hand off -- everything is readable
from the archive.

### Reframing 10: disposable-context retrieval -- Josh's sharpest move

The retrieval layer is itself an ephemeral specialist. Load once, keep
resident. Per query: reset KV cache, hand it (query + index), get back
line-number verdicts, reset again. The index can be massive -- even larger
than the transcript -- because it never has to fit in the primary's
context. Only the specialist sees it, one query at a time, with fresh
context each time. This unlocks arbitrarily rich indexing without
burdening the primary.

---

## Honest uncertainties at session end

These are *genuine* open questions, not rhetorical humility:

1. **Tier-1 indexing throughput on actual hardware.** We hand-waved
   1.5 sec/turn. Needs benchmarking on 5700 XT with Vulkan. First job of
   V0 prep.
2. **Retrieval-specialist model choice for card 2.** Candidates not
   specified. Depends on the parser-survey results landing tomorrow.
3. **Whether the primary reliably knows what kind of query it's asking.**
   AbstentionBench says reasoning models degrade at self-reflection. The
   "when in doubt return both" fallback mitigates but costs tokens.
4. **"Unresolved state" detection.** When the transcript is mid-debate
   with no decision yet. The research found change-point detection but
   not resolution-state detection. May be a real research problem.
5. **Whether off-the-shelf discourse parsers exist that map usefully to
   the target tags** (reversal, supersession, concession, contrast,
   elaboration, commitment, aside, directive, question, unresolved).
   Background agent dispatched to answer this; results in
   `2026-04-24-discourse-parser-survey.md` tomorrow morning.
6. **Whether the annotated discourse corpora are accessible enough to
   drive V2 parser evaluation.** Background agent dispatched to assemble;
   results in `docs/research/test-corpora/` tomorrow morning.
7. **How the primary signals "I'm done, system can compact now" vs.
   "wait, still thinking."** Not addressed. V1 problem.
8. **Two-user time-slicing scheduler fairness.** DLPM exists (arxiv
   2501.14312) but we haven't designed the specific policy. V3+ problem.
9. **Anonymization defaults** for logs that outlive context. Light
   auto-scrub (paths, secrets, hostnames) as default; full anon as switch.
   Mentioned, not designed.

## Explicit non-goals (to prevent scope creep in future sessions)

- **V0 will not** have compaction, temporal routing, supersession detection,
  cross-session retrieval, multi-user, or the dispatcher/registry machinery.
  It proves the mechanism. Nothing more.
- **We will not** build a rhetorical taxonomy from scratch. If the parser
  survey finds nothing workable, V2 is deferred and we revisit.
- **We will not** optimize for wall-clock latency at V0. Correctness and
  the mechanism come first.
- **We will not** claim novelty on Pattern 1 (transcript-as-artifact).
  The mechanism is standard. The portfolio story is "built the measured-
  better thing industry overlooked, with temporal awareness added, on
  local hardware, end-to-end." Stronger than false novelty.

## Research library assembled in this session

All in `docs/research/`:

1. `2026-04-24-multi-model-handoff-prior-art.md` -- dispatcher-behind /
   catch-and-swap + self-aware handoff requests.
2. `2026-04-24-front-and-passenger-dispatcher-prior-art.md` -- front and
   passenger variants.
3. `2026-04-24-session-state-architectures-survey.md` -- neutral survey of
   seven architectural shapes for session state.
4. `2026-04-24-session-persistence-and-reassembly-prior-art.md` -- four
   threads: persistence under swap, handoff payload shape, multi-session
   serving, reassembly failure modes.
5. `2026-04-24-session-as-artifact-and-temporal-retrieval-prior-art.md` --
   verbatim retrieval + temporal routing.
6. `2026-04-24-conversation-notes-architecture-thinking.md` -- thinking
   journal with two reread cues (erratum + round-3 soft-spots).
7. `2026-04-24-session-notes-full.md` -- this file.
8. `2026-04-24-user-contribution-notes.md` -- sibling to this file;
   tracks Josh's role specifically.
9. `2026-04-24-discourse-parser-survey.md` -- (landing tomorrow from
   background agent).
10. `test-corpora/` -- (landing tomorrow from background agent).

## For the morning session

Read this file first. Then:

1. Check the parser-survey and test-corpora agent outputs committed
   overnight. They'll tell us whether V2 is tractable with off-the-shelf
   tools or whether it's a research project.
2. If V0 still looks right, first concrete artifact to produce is the
   **Tier-1 indexing spec** (one page).
3. If V0 *doesn't* look right by morning, that's fine -- the research
   library is the real artifact and will have standalone value even if
   we never build.

## Tone note for whoever reads this next

The session was productive and honest. Josh repeatedly corrected me when
I drifted -- toward novelty-claiming, toward over-engineering, toward
scope creep. I took the corrections. The design we landed on is smaller
and more buildable than what I was sketching at multiple points in the
middle.

Nothing here is a commitment. We ended the session with a research
library and a plausible V0, not with a signed-off spec. Tomorrow-us
is free to throw all of it out.
