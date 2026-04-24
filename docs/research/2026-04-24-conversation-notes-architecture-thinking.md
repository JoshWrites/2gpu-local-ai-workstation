# Architecture Thinking — Conversation Notes (2026-04-24)

**Purpose:** Preserve the reasoning developed during a long brainstorming session on
2026-04-24. This is a thinking journal for future-us, not a spec. The shape is still
being tested; don't treat it as decided. Write-ups that *are* specs will live elsewhere
in `docs/superpowers/specs/`. Research backing these ideas is in sibling files under
`docs/research/`.

Audience: the person (probably Josh, possibly a collaborator) who picks this thread
back up weeks or months later. Assume they have full hardware context (7900 XTX / 5700
XT / 5950X / 64 GB / 1+ TB NVMe homelab) but may not remember the specific thought
chain.

---

## The original question we started with

How do we get the most out of the 7900 XTX + 5700 XT + 5950X + 64 GB + NVMe
workstation, given that the "primary" model shouldn't be burdened with noisy context?

This was framed in terms we'd already been using — "active context" vs. "passive
context." Active = what the primary model must see to think clearly. Passive = noisy
input that can be compressed off-card before any distilled result reaches the primary.
Current examples already built: embedder on card 2, watcher on card 2, research
distiller on card 2.

## How the framing evolved

Over the session, we moved through several reframings. Each one subsumed the last.

**Reframing 1: generation vs. everything else.**
"Active/passive context" was fuzzy at the edges. The sharper version: the primary
model's only irreplaceable job is *generating the next user-facing token*. Retrieval,
ranking, summarization, classification, memory maintenance, validation, observation —
none of these require the primary's specific weights. All of them can in principle
live elsewhere (CPU, card 2, scheduled jobs). The architecture question becomes "where
is each non-generation concern cheapest to host?"

**Reframing 2: three buckets, not two.**
Initial split was active (primary is generating) vs. passive (happens elsewhere). But
passive has two sub-kinds:

- **Concurrent-passive** — happens while the primary is generating. Must be off-card
  for VRAM reasons. Examples: watcher, live classifier, embedding at ingest time.
- **Serial-passive** — happens when the primary is idle or unloaded. Can run on card
  1 transient, card 2, or CPU. Examples: transcript compaction between turns, ingest
  re-embedding overnight, nightly consolidation.

Serial-passive was the newly-legal bucket once we established that swap time is
acceptable (user doesn't optimize for wall-clock). A 27B-class compactor running
between turns does a much better job than a 4B one, and the swap cost is fine.

**Reframing 3: coordinator as collection of concerns, not a thing.**
We started by asking where "the coordinator" should live (in front of the operator,
behind the endpoint, as a passenger-seat advisor). But "the coordinator" isn't one
thing — it's several concerns, each with its own natural home:

| Coordination concern | Best home |
|---|---|
| Lifecycle (load/unload models) | CPU program — boring, deterministic |
| Routing operator request to a model | CPU program calling card-2 classifier when uncertain |
| Detecting handoff need mid-turn | Card 2 model (semantic judgment) → CPU router |
| Compaction / re-embedding | CPU scheduler triggering card-1-transient or card-2 jobs |
| Critique / advice during generation | Card 2 model (must be concurrent with card 1) |
| Permission gating / safety | CPU program (no model needed) |

The takeaway: the dispatcher should mostly be **Python on CPU** calling **small LLMs
on card 2 as classifier/summarizer subroutines**, not itself a model. The
"intelligence" lives in the LLM calls. The "coordination" lives in code. This matches
every production system surveyed except NVIDIA Orchestrator-8B, which is RL-trained
specifically for the orchestrator role. An off-the-shelf small model prompted as an
orchestrator underperforms (see the PEAR benchmark and HuggingGPT evidence in
`2026-04-24-front-and-passenger-dispatcher-prior-art.md`).

**Reframing 4: transient large specialist as a VRAM-budget trick.**
A stateless single-shot task doesn't need a long KV cache. If the task can be phrased
as an RPC (input fully specifies the problem; output is self-contained; no follow-up
in the same turn), then the 24 GB VRAM budget normally spent on weights + long KV can
be reassigned to *larger weights + minimal KV*. The primary is a time-sliced
resource, not a fixed tenant.

Examples of strong-fit transient work: spec synthesis, hard algorithmic questions,
adversarial critique of a plan, code review of a finished diff, structured extraction.

This requires a context-switch mechanism: freeze primary state, unload primary, load
specialist, run one turn, unload specialist, restore primary. The hard steps are KV
save/restore (solvable via llama.cpp `--slot-save-path`) and keeping primary weights
warm in DRAM page cache (solvable via `mmap`-backed GGUF files). Published
integration of these two mechanisms does not appear to exist as of 2026-04.

**Reframing 5: arenas, not roles.**
We stopped thinking of "card 1 = primary, card 2 = support" and started thinking of
each resource as capacity:

- NVMe (1 TB+, ~5 GB/s): model archive, KV dumps, transcripts, embeddings, ingest corpora
- DRAM (64 GB, ~50 GB/s): warm weight cache via mmap, hibernated KV, Python state
- CPU (5950X, 16C/32T): orchestration, deterministic logic, small classifiers, embedder at scale, draft model
- Card 2 (5700 XT, 8 GB, Vulkan): small always-resident helpers, OR one medium single-turn, OR transient big with no context, OR GPU oomph for a scripted function
- Card 1 (7900 XTX, 24 GB, ROCm): long-session primary, OR transient bigger specialist, OR overnight heavy work

The coordinator's real job: maintain a live assignment of "what's in each arena right
now" and transition between assignments cleanly.

**Reframing 6: the best-fit problem is a curation problem, not a runtime problem.**
Mid-session, we hit the hardest question: "how does the system pick the best-fit
model for a request?" Research said this is unsolved — models can't reliably
self-assess limits (AbstentionBench: reasoning fine-tuning *degrades* abstention by
~24%); PEAR shows weak planners degrade quality more than weak executors; Self-MoA
shows heterogeneous routing often makes quality worse than single-model baseline.

Josh's reframing: **don't make runtime solve this.** Instead:

- Admin (a human, probably the user) surveys model releases on a quarterly cadence.
- For each established use case in a *registry*, admin picks the current best-fit
  based on public benchmark numbers + reference-set testing of the 2-3 plausible
  finalists on the user's real prompts.
- Runtime becomes a dictionary lookup: classifier sorts the request into a registry
  slot; registry says which model; Fabric loads it (or uses it if already loaded).
- A *monitor* logs every request, its classification, and whether the output was
  good. "Unknown" classifications get served by a *generalist* model and logged as
  misses. Admin reviews miss log at quarterly ritual; genuine new use cases get
  registry slots and benchmark-family assignments.

This dissolves the research problem. Intelligence moves out of the hot path and into
a quarterly human-curated artifact. The runtime becomes deterministic.

**Reframing 7: use cases aren't invented, they're discovered.**
Another sharpening from Josh: don't invent a use-case taxonomy. The industry already
did that — public benchmarks like SWE-bench, LiveCodeBench, MMLU-Pro, BFCL, RULER,
etc. already define use cases precisely and reproducibly. Model releases come
pre-scored on them. Discovery has two sources:

- **Git history (startup seeding):** what has the user *actually* produced? Commit
  shapes tell you the rough distribution — "40% Python with tests, 20% specs, 15%
  bash, etc." Map those distributions to the benchmark families that already measure
  them.
- **Monitor logs (ongoing):** while running, the system logs prompts + classifier
  tag + output. Poll mode logs ten real prompts per classifier category per period,
  capped for reviewability. At audit time, the admin spot-checks both "was the
  classification right" and "was the output good."

The generalist is a provisional slot-holder for unknown categories. It's *good*, not
merely adequate (Josh's correction to my earlier framing) — users shouldn't suffer
when misclassified. The noticeability of misses comes from the log, not from user
pain.

**Reframing 8: storage-bounded registry, ranked-choice over deduplicated models.**
Models are large; NVMe is large but finite. Algorithm for deciding which models to
keep on disk, sketched:

- Registry slots are weighted by observed frequency (from monitor logs).
- Each candidate model gets a score equal to the sum of frequencies of all slots
  it's best-fit for (one model can cover multiple slots — the dedupe gain).
- Load models in descending score order until disk budget is full.
- Slots whose preferred model doesn't make the cut get reassigned to the
  highest-scoring model that *did* make the cut (often the generalist).
- Admin can pin 2-3 specialist models that don't meet the frequency bar but matter
  (e.g., a reasoner used biweekly for spec work). Pins are visible and reviewed.

**Reframing 9: the session-state question (where we stopped).**
We then went deep on a piece we hadn't addressed yet: when there are two users AND
requests can move between models, how is session coherence maintained?

Sub-questions:

1. How do you resume a session after a swap without losing what's been established?
2. How do two users time-share without their sessions contaminating each other?
3. What's the architectural shape for "context carries across model changes" — is it
   one model holding the thread with others as subroutines, or peers passing state
   between them, or a shared memory store, or something else?

Round-2 research is in-flight to answer these without bias. Reports will land at:

- `2026-04-24-session-state-architectures-survey.md` (neutral enumeration + equal-depth survey of all shapes found in the literature)
- `2026-04-24-session-persistence-and-reassembly-prior-art.md` (four specific
  threads: persistence under swap, handoff payload shape, multi-session serving
  stacks, reassembly failure modes)

## What the user wants from the user surface

Listed by Josh explicitly:

1. **Heartbeat indicator.** Always-visible proof the system isn't hanging. Status
   line showing arena, model, phase (generating, loading, swapping, awaiting tool).
2. **Graceful fallback.** On hang or loop, the system does something sensible and
   the user sees what happened. Never a silent freeze.
3. **Single-thread-of-conversation illusion.** The user sees one conversation, even
   if several models have contributed.
4. **Confidence in best-fit handling.** Each piece of the task handled by the right
   model — this is what the curation-not-runtime reframing solves.
5. **Action-severity gating.** Reads are free. Writes need polite confirmation.
   Deletes need typed confirmation (already built: `confirm_destructive.py`).
6. **Two-user concurrency by time-slicing.** Anny and Josh share the stack.
   Sessions serialize at turn granularity. Each user perceives full use of the
   system; the penalty is time, not quality.

## The three-layer mental model (tentative)

Still being tested. Nothing below is decided.

- **Fabric:** small Python daemon on CPU. Owns arena state, session state, scheduler,
  transitions. Does not think. Executes state transitions when given them. Every
  action logged and fallback-covered. Target: ~2,000 lines.
- **Council:** small set of stateless helpers the Fabric invokes — classifier,
  router, compactor, watcher, embedder, reranker, miss-logger. Mostly card 2 and
  CPU. Each is a tool, not an agent.
- **Primaries:** whatever large model is currently serving the user's turn.
  Interchangeable. Come and go based on registry + scheduler. Know about tools they
  can call, including handoff-request tools. Don't know about Fabric internals.

## The admin ritual (tentative)

**Monthly (lighter):**
- Glance at novel-use-case log. Any patterns emerging?
- Note use cases where output quality felt like it slipped.

**Quarterly (heavier, one evening):**
- Review novel-use-case log. Real new categories, or one-offs?
- Survey model releases. Prune to candidates that fit the hardware envelope *and*
  claim improvements on use-case-aligned benchmarks.
- For each registry entry where a candidate exists: reference-set bench of
  candidate vs. incumbent. Swap if meaningfully better.
- For each new category identified: reference-set bench of plausible models, pick
  a fit, add to registry with benchmark-family assignment.
- Update registry file. Commit with a detailed message explaining why each entry
  changed. Push to git. Done until next quarter.

**Audit tooling is a prerequisite.** An annoying audit won't get done. A CLI that
walks prompts one-by-one, shows classifier tag + model output, accepts single-keystroke
verdicts ("classification right? Y/N", "output quality 1-5") is mandatory before the
ritual becomes sustainable.

## Phased build (tentative, not committed)

Each phase is independently useful:

- **V0:** Fabric daemon, single user, one primary model, no swaps. Status line,
  transcript persistence, write/delete gates. Proves state machine and user surface.
- **V1:** Specialist transient swap. KV cache save/restore + mmap-cached weights.
  Proves context-switch mechanism.
- **V2:** Council members online. Watcher, classifier, compactor, embedder as
  Fabric-callable tools.
- **V3:** Two-user time-slicing. Per-user session state; scheduler alternates turns.
- **V4:** Registry + miss-logger + audit tool. The curation loop becomes real.

## Reread cue (added after round-3 research landed, same session)

**When rereading this doc, read it with an eye for soft spots.** Round-3 research
(`2026-04-24-session-as-artifact-and-temporal-retrieval-prior-art.md`) established
several things that may change what still holds up in this document:

- **Pattern 1 (session-as-retrievable-artifact) is NOT novel.** It is standard
  and already deployed (Anthropic's Claude memory `conversation_search` /
  `recent_chats` per Simon Willison's 2025-09-12 analysis; Letta/MemGPT's
  `recall memory`; LangChain `VectorStoreRetrieverMemory`). My earlier claim
  that this was new territory was wrong.
- **Verbatim retrieval outperforms summary extraction by +12.4 R@5 on
  LongMemEval.** The industry's summary-based systems (Mem0, ChatGPT Memory)
  appear to have shipped the measurably-worse option. Homelab context makes
  the constraints that drove them to summaries (scale, privacy-by-distance,
  low latency budget) mostly not apply.
- **Temporal-aware retrieval routing** — routing retrieval on whether the query
  wants current state vs. decision history — is where the actual research gap
  lives. Every ingredient exists in separate papers (SelRoute, LongMemEval,
  Zep/Graphiti, Generative Agents recency decay, change-point detection). No
  named combination.
- **The portfolio framing updates:** not "invented X" but "built the
  measurably-better thing industry overlooked, with temporal awareness added,
  on local hardware, end-to-end." Stronger and defensible with citations.

Soft spots to watch for when rereading:
- Anywhere this doc implies the Pattern 1 mechanism is itself new.
- Anywhere the three-layer Fabric/Council/Primaries model assumes *state
  transfer* between models is the hard problem. Retrieval-on-demand against
  a durable transcript subsumes much of that. The Council's "handoff-spec
  writer" may not need to exist at all.
- The "possibly novel" section needs narrowing. The only clearly-novel piece
  is the specific *integration* (verbatim transcript + temporal query routing
  + homelab-hardware specifics + slot-save-restore time-slicing), not any
  single component.
- The phased build (V0-V4) may want restructuring around retrieval-first
  rather than coordinator-first. V0 = "verbatim retrieval with pre-compaction
  recall working in a single session." That's the minimum viable win per the
  user's own framing in the session this doc was written from.

## Erratum (added after round-2 research landed, same session)

In Reframing 4's discussion of the transient-specialist swap mechanism (Step 2
of the sequence), the original draft said the outgoing primary should write a
**prose handoff spec** for the incoming specialist. Round-2 research contradicts
this. Agent 4's Thread 2 findings (see
`2026-04-24-session-persistence-and-reassembly-prior-art.md`) establish the
empirical ranking of handoff payload shapes:

    raw transcript > transcript + structured retrieval >
    structured facts alone (Mem0) > outgoing-model summary

Outgoing-model prose summary is the **worst-measured** payload shape. The correct
design is a **structured-facts schema** — fields like `goal`, `decisions_made`,
`open_threads`, `attempted_approaches`, `current_blocker`, `specialist_request` —
that the outgoing model fills in and the incoming model reads. Mem0's numbers
quantify the tradeoff: ~6 accuracy points lost vs. raw transcript, in exchange
for ~12× latency and ~10× cost reduction.

This updates the handoff-spec-writer Council member's role from "write a prose
problem statement" to "fill a schema." Small change in interface, large change
in expected quality.

## Honest uncertainties / open questions

Written now while I still remember them. Revisit when research lands.

1. **Classifier miss signal.** How does the classifier express "unknown" at
   runtime? Explicit N+1 category? Confidence threshold? Second-pass "are you sure"?
   Load-bearing for the miss-logger.

2. **Reference-set mechanics.** Need a `bench use_case_id --candidate model_spec`
   CLI that runs N reference prompts, stores outputs, supports side-by-side compare.
   Doesn't exist; must be built before first ritual.

3. **Registry seeding from git.** "Sample your git" is abstract. What's the concrete
   first operation? Commit-message keyword buckets? File-extension distribution +
   diff sizes? Both? Needs a prototype.

4. **Anonymization in logs.** Between Josh and Anny it's fine today, but logs
   outlive memory of context. Light auto-scrub (strip absolute paths, redact
   secrets by pattern, placeholder hostnames) as default. Full anon as a switch for
   later.

5. **Audit time budget.** 10 prompts × 10 use cases × ~2 min each = 3.5 hours. Too
   long to sustain quarterly. Sampling tiers + single-keystroke UI brings it to an
   hour. If tooling is absent, ritual rots.

6. **What happens mid-turn if the target model isn't loaded?** Three options,
   tradeoffs not fully explored:
   - Swap-and-serve: slow, correct.
   - Fallback-and-log: fast, imperfect, log ensures future correctness.
   - Queue-and-wait: predictable, possibly annoying.

7. **Fabric failure independence.** Fabric as SPOF: if it crashes, the primary card
   is unreachable. Distiller/watcher independently fail today without affecting each
   other. Need to keep Fabric code extremely boring.

8. **Session-state shape.** Still open, research pending. Is it one thread-holder +
   subroutines, peers passing baton, shared memory, transcript-replay, or
   something else entirely? Equal-weight research is in flight.

## What's novel here, possibly

Josh noted this probably has blog/portfolio value, and may have more value if
genuinely novel. What I'd flag as worth further investigation:

- **"Three-bucket" context taxonomy (active / concurrent-passive / serial-passive)**
  as a design vocabulary. Hasn't appeared in the literature the research agents
  found, but I didn't do an exhaustive check.
- **KV-save + mmap-warm-cache + handoff-spec generation** as an integrated
  context-switch for GPU-resident LLMs. Each component exists. The integration
  doesn't appear to be published as of 2026-04 (see
  `2026-04-24-multi-model-handoff-prior-art.md` §7 and JetBrains Junie writeup).
- **Curation-on-slow-clock registry** (admin ritual + benchmark-aligned taxonomy +
  miss-log discovery loop) as an alternative to runtime "smart routing." The
  individual pieces all exist; the framing — explicitly moving intelligence out of
  the hot path into human-curated artifacts on a quarterly cadence — may be worth
  articulating.
- **Storage-bounded registry with ranked-choice over deduplicated models.** Again,
  individual pieces are standard. The specific algorithm (slots are voters weighted
  by frequency, models are candidates scored by sum-of-voters, load in descending
  order, reassign unseated slots to highest-scoring seated model, admin can pin)
  may be fresh.

None of these are verified novel. Round-2 research will either confirm or find
prior art.

## Preservation notes

- Three research reports have been saved to `docs/research/` before this document:
  - `2026-04-24-multi-model-handoff-prior-art.md`
  - `2026-04-24-front-and-passenger-dispatcher-prior-art.md`
  - (Plus this file and two more being written by background agents)
- MEMORY.md has not been updated. If this architecture becomes real, add a pointer.
- This is not a spec. Do not implement from this document. It's for continuity of
  thinking only.

---

*Written 2026-04-24 during an extended brainstorming session. If the architecture
pans out, a proper spec will live in `docs/superpowers/specs/` and this file becomes
historical context. If it doesn't pan out, this file is the record of why.*
