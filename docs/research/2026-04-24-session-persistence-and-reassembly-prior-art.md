# Session persistence, handoff payloads, multi-session serving, reassembly failure modes

Prior-art scan for the homelab multi-model "second-opinion" project, 2026-04-24.
Scope: LLMs serving long-running multi-turn sessions where the underlying model
or serving state may change between turns. Four independent threads; synthesis
at the end.

Research methodology: primary-source literature sweep (arxiv, project docs,
engineering blogs). Web search only; no direct page fetch was available for the
Junie MemU post, so claims about it are taken from the search-result excerpts
and cross-checked against JetBrains' own blog. Inferences are labeled.

---

## Thread 1 - Session persistence across model swap

**Framing.** The question is not "can two agents hand off" (Swarm, CrewAI, etc.
cover that) but "can a user run one conversation whose turns are answered by
different models, without perceiving a break?" The canonical negative result is
the MemU writeup on JetBrains' Junie CLI, which names the failure "context
evaporation." I could not find a positive result - i.e., a published
deployment where mid-session model swaps were shown to preserve quality.

### The negative result: Junie CLI's context evaporation

JetBrains' Junie CLI, released in beta in March 2026, is explicitly
model-agnostic: it lets a developer switch between OpenAI, Anthropic, and
Google models within one agent session (JetBrains blog, March 2026;
https://blog.jetbrains.com/junie/2026/03/junie-cli-the-llm-agnostic-coding-agent-is-now-in-beta/).
The MemU analysis argues that the abstraction is shallower than it looks:
"when a model-agnostic coding agent switches from Claude to GPT-4 mid-workflow,
the new model inherits the conversation thread but none of the learned
context. The patterns the agent discovered about your codebase architecture,
the edge cases it identified in your test suite, the naming conventions it
adapted to - all of that lives in the previous model's session state"
(https://memu.pro/blog/junie-cli-model-agnostic-coding-memory).

Two sub-points matter for system design:

1. The "conversation thread" in Junie's case is text tokens (messages, tool
   calls, and file outputs). Those transfer. What does not transfer is
   everything the previous model had internalized *implicitly* - adapted
   conventions, running hypotheses about the codebase, its own partially
   complete plans.
2. Junie addresses this at the persistence layer with an `AGENTS.md`
   guidelines file that is re-injected on every task
   (https://junie.jetbrains.com/docs/guidelines-and-memory.html). That is a
   static-shared-context workaround, not dynamic session transfer.

### Multi-turn degradation even without model swap

Before asking whether swaps degrade sessions, the baseline is that long
sessions already degrade *within a single model*. Laban et al.,
"LLMs Get Lost In Multi-Turn Conversation" (Microsoft Research + Salesforce,
May 2025, arxiv:2505.06120) ran 200,000+ simulated conversations and found an
average 39% performance drop versus single-turn on the same six tasks
(coding, SQL, API calls, math, data-to-text, summarization). The drop appears
*even in two-turn conversations* and holds across Llama-3.1-8B through
Gemini 2.5 Pro (https://arxiv.org/abs/2505.06120). The decomposition they
report: ~minor aptitude loss, large unreliability increase; gap between a
model's best and worst sharded run can exceed 50 points. Flagship models
(Claude 3.7 Sonnet, Gemini 2.5 Pro, GPT-4.1) degrade 30-40%, as much as
smaller ones.

Implication for the swap case: if a single model already loses ~40% of its
reliability over a multi-turn session because of premature commitments,
middle-turn neglect, and inability to backtrack, any mid-session model change
starts from a degraded baseline. Inference: swapping *might* help by breaking
a bad trajectory, or hurt by forcing re-establishment of context. The
literature does not disambiguate.

### Positive results? (mostly no)

I could not find a single published deployment study where a production
system (a) explicitly swaps models mid-session and (b) measures quality
against a single-model baseline. The closest are router evaluations:

- **RouterBench** (arxiv:2403.12031) and **RouteLLM** (lm-sys, 2024) compare
  routing strategies with a cost-quality frontier; routing decisions are
  per-query, not mid-session, and the benchmarks are single-turn
  (https://arxiv.org/abs/2403.12031,
  https://github.com/lm-sys/RouteLLM). RouteLLM reports ~50% cost reduction
  at ~95-98% quality retention on MT-Bench with well-chosen model pairs, but
  MT-Bench is largely single-turn and per-query routing, not "turn 1 by
  model A, turn 2 by model B on the same conversation."
- **Google Gemini CLI model router** has an open bug (gemini-cli issue 12945,
  https://github.com/google-gemini/gemini-cli/issues/12945) where users flag
  that routing between Flash and Pro degrades longer sessions because Flash
  handles long context worse. That is production-adjacent evidence, not a
  paper, but it is a first-person account of the concern.
- **General regression testing** practice, summarized by Confident AI and
  Braintrust (https://www.confident-ai.com/blog/multi-turn-llm-evaluation-in-2026,
  https://www.braintrust.dev/articles/llm-evaluation-guide), is to replay a
  sample of real conversations on both old and new models and have a judge
  flag divergences. This is model *upgrade* evaluation, not mid-session
  *swapping* evaluation.

### Takeaway for Thread 1

The literature has the negative result well-documented (Junie + multi-turn
degradation) and a practitioner-level methodology (conversation replay
with judge divergence) but no published positive case where mid-session model
swap preserves or improves quality. For the homelab project, this means any
A/B for "turn-by-turn model swap" is greenfield - even an internal benchmark
on a dozen representative sessions would be a novel contribution.

Key sources for Thread 1:
- https://memu.pro/blog/junie-cli-model-agnostic-coding-memory
- https://arxiv.org/abs/2505.06120 (Lost in Multi-Turn)
- https://blog.jetbrains.com/junie/2026/03/junie-cli-the-llm-agnostic-coding-agent-is-now-in-beta/
- https://arxiv.org/abs/2403.12031 (RouterBench)

---

## Thread 2 - Context-as-transcript vs. context-as-summary on handoff

**Framing.** Given the previous model's session ended and a new one (or the
same one, post-eviction) needs to take over, what handoff payload best
preserves continuity? Three shapes are empirically compared in the
literature: raw transcript, summary, and structured facts/decisions.

### Summary is measurably lossy vs. transcript

Maharana et al., **"Evaluating Very Long-Term Conversational Memory of LLM
Agents"** (arxiv:2402.17753, "LoCoMo") built a benchmark of ~300-turn,
9K-token, 35-session dialogues grounded in persona and event graphs. In their
words, "using session summaries as context does not significantly improve
performance despite high recall accuracies, likely due to loss of information
during the conversion of dialogs to summaries"
(https://arxiv.org/abs/2402.17753). Human QA F1 is ~88; the best LLM baseline
on summary-style context lands at ~37-42. That gap is the answer to the
thread's empirical question: under LoCoMo's conditions, a generated
summary does *not* substitute for the raw dialog.

### MemGPT/Letta: full transcript via paginated search beats recursive summary

The MemGPT paper (Packer et al., arxiv:2310.08560,
https://arxiv.org/abs/2310.08560) built a deliberate comparison: a
fixed-context baseline uses recursive summarization of evicted messages; the
full MemGPT system instead lets the model issue paginated search queries
against the full recall storage. On the Deep Memory Retrieval (DMR) task and
the conversational opener eval, MemGPT shows "clear improvements in both
accuracy and ROUGE scores" over the recursive-summary baseline
(https://arxiv.org/pdf/2310.08560). The framing matters: MemGPT does not
argue summary is *worthless*; it argues summary alone is insufficient and
needs to be paired with on-demand retrieval of the original spans. This is
the hierarchical-memory / virtual-context model (core + recall + archival;
Letta docs https://docs.letta.com/concepts/memgpt/).

### Mem0 / Zep: structured facts beat both summary and naive full context on cost/latency, but lose a small accuracy delta

Chhikara et al., **"Mem0: Building Production-Ready AI Agents with Scalable
Long-Term Memory"** (arxiv:2504.19413) benchmarks Mem0's extracted-facts
memory against full-context LoCoMo replay. Headline numbers:

- Full context: 72.9% accuracy, p95 latency ~17.12s
- Mem0 selective: 66.9% accuracy, p95 latency ~1.44s, >90% fewer tokens

Source: https://mem0.ai/research and https://arxiv.org/abs/2504.19413. The
~6-point accuracy loss buys a 12x latency win and ~10x cost win. That is the
clearest published empirical comparison of full-transcript vs. structured
facts that I located. Zep's response (https://blog.getzep.com/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/)
disputes some methodological choices but does not overturn the shape of the
tradeoff.

### OpenAI Swarm / Agents SDK: "all context the next agent needs"

OpenAI's Swarm cookbook piece states the handoff invariant baldly: "Since the
system has no persistent state between calls, every handoff must include all
context the next agent needs - no hidden variables, no magical memory"
(https://cookbook.openai.com/examples/orchestrating_agents). The newer
Agents SDK generalizes this into explicit primitives
(https://openai.github.io/openai-agents-python/handoffs/,
https://openai.github.io/openai-agents-python/context/):

- `RunContextWrapper.context` - dependency-injection bag the runner passes to
  every agent/tool.
- `input_type` - typed schema for the handoff payload.
- `input_filter` - function to trim transcript for the incoming agent.
- `RunConfig.nest_handoff_history` - collapses prior transcript into a single
  summary message wrapped in a `<CONVERSATION HISTORY>` block.

The design endorses all three shapes (transcript, summary, structured) but
has no published quality eval comparing them.

### Prompt compression: LLMLingua as a transcript-to-tokens compressor

Jiang et al., **LLMLingua** (EMNLP 2023, arxiv:2310.05736) and
**LongLLMLingua** (arxiv:2310.06839) compress prompts up to 20x with a 1.5%
performance loss on GSM8K reasoning. On ShareGPT (conversation) specifically,
LLMLingua's reported advantage is "moderate," not large
(https://www.microsoft.com/en-us/research/blog/llmlingua-innovating-llm-efficiency-with-prompt-compression/).
That is consistent with LoCoMo's finding: conversational content is harder to
lossy-compress than reasoning prompts, because important referents (a decided
fact from turn 3, a rejected hypothesis from turn 7) can look
low-entropy to a token-importance scorer but are load-bearing for later
turns.

### Takeaway for Thread 2

Empirical ranking of handoff payload shapes, synthesized across LoCoMo,
MemGPT, and Mem0:

1. **Raw transcript** is the highest-fidelity but expensive and can exceed
   context windows.
2. **Transcript + structured retrieval index** (MemGPT-style) matches raw
   transcript on fidelity and degrades gracefully past the context limit.
3. **Structured facts / decisions / open threads** (Mem0-style) lose ~5-10
   points of accuracy but 10x cost and latency; viable when the handoff is
   frequent.
4. **Outgoing-model-written summary alone** is the worst of the three for
   preserving continuity; it fails LoCoMo specifically because of information
   loss (Maharana et al., 2024).

For mid-session model *swap* specifically, inference: the Mem0-style
structured payload is probably the right primary channel, with raw-transcript
fallback when the structure is insufficient and the new model re-queries.
This matches the OpenAI Agents SDK's explicit endorsement of typed
`input_type` handoffs over naked summary collapse.

Key sources for Thread 2:
- https://arxiv.org/abs/2402.17753 (LoCoMo)
- https://arxiv.org/abs/2310.08560 (MemGPT)
- https://arxiv.org/abs/2504.19413 (Mem0)
- https://arxiv.org/abs/2310.05736 (LLMLingua)
- https://cookbook.openai.com/examples/orchestrating_agents (Swarm)
- https://openai.github.io/openai-agents-python/handoffs/ (Agents SDK)

---

## Thread 3 - Multi-session serving systems

**Framing.** Independent systems-engineering question: how does a serving
engine keep N user sessions warm on one or a few models, and what happens
under pressure? The dominant mechanism is KV-cache-centric session state,
not message-level session state.

### vLLM - PagedAttention + Automatic Prefix Caching (APC)

Kwon et al., **"Efficient Memory Management for Large Language Model
Serving with PagedAttention"** (SOSP 2023, arxiv:2309.06180,
https://arxiv.org/abs/2309.06180). KV cache is partitioned into fixed-size
blocks; a block table maps logical positions to physical memory. Reported
KV-memory waste drops from 60-80% (contiguous-allocation baselines) to under
4%.

Sessions are not a first-class object; they are emergent from prefix reuse.
Automatic Prefix Caching hashes shared prefixes and, if a new request
matches, reuses those KV blocks (https://docs.vllm.ai/en/stable/design/prefix_caching/).
As of vLLM 0.11 the default hash is sha256; salt values isolate caches in
multi-tenant deployments (https://docs.vllm.ai/en/stable/design/prefix_caching/).

**Eviction**: LRU over blocks with reference count 0; tiebreak on "deepest
prefix first" so that shorter shared prefixes stay resident
(https://docs.vllm.ai/en/stable/design/prefix_caching/). Under memory
pressure, the user's private suffix evaporates first; the shared system
prompt usually survives.

**Scaling**: LMCache (https://github.com/LMCache/LMCache,
https://lmcache.ai/tech_report.pdf) extends prefix caching out of GPU memory
into CPU/NVMe/Ceph tiers and across replicas, with the "vllm production
stack" reporting 3-10x latency savings and 2-5x throughput in multi-round QA
(https://blog.lmcache.ai/2025-01-21-stack-release/,
https://ceph.io/en/news/blog/2025/vllm-kv-caching/).

**Session-aware scheduling**: vLLM itself is locality-greedy, not
fairness-aware. Sheng et al., **"Locality-aware Fair Scheduling in LLM
Serving"** (arxiv:2501.14312) formalize the tradeoff: Virtual Token Counter
(VTC) is fair but not locality-aware; Longest Prefix Match (LPM) is
locality-aware but not fair. Their Deficit Longest Prefix Match (DLPM) is the
first to do both (https://arxiv.org/html/2501.14312). This is load-bearing
for multi-user serving: without DLPM-style scheduling, a heavy user can
starve a light user's KV cache.

### SGLang - RadixAttention

Zheng et al., **"SGLang: Efficient Execution of Structured Language Model
Programs"** (arxiv:2312.07104, https://arxiv.org/pdf/2312.07104). KV cache is
organized as a radix tree keyed by token sequence; any two requests that
share a prefix path share the cached K/V. LMSYS's launch post
(https://www.lmsys.org/blog/2024-01-17-sglang/) showed first-token latency
wins on fixed system prompts; Spheron reports 75-95% cache hit rates for
agents with shared system prompts and tool definitions
(https://www.spheron.network/blog/sglang-production-deployment-guide/).

**Session handling**: the front end sends full prompts; the runtime does
prefix matching automatically. This means "session continuity" is effectively
"keep the prefix short enough to not get evicted, and re-send the whole
transcript each turn." Multi-level sharing covers few-shot prompts, branching
reasoning trees, chat histories, and self-consistency sampling.

**Eviction**: LRU over radix-tree nodes. HiCache
(https://docs.sglang.io/docs/advanced_features/hicache_design) adds tiered
storage for off-GPU cache.

### TensorRT-LLM / Triton

Nvidia's KV cache reuse (https://nvidia.github.io/TensorRT-LLM/advanced/kv-cache-reuse.html)
requires the model to be built with paged context attention
(`trtllm-build --use_paged_context_fmha enable`). Reuse is enabled in Triton
via `parameters: { key: "enable_kv_cache_reuse" value: { string_value: "true" } }`.
Important production footnote: "KV cache state only becomes reusable after
the request that computed the state terminates. If you have a shared system
prompt, the first request will compute kv cache state for the system prompt,
the second request will reuse it, but only if the second request launches
after the first request completed." That timing constraint changes
capacity planning - concurrent first-requests do not share cache.

Triton also exposes priority caching for stateful serving patterns
(https://forums.developer.nvidia.com/t/triton-tensorrt-llm-llama-3-1-8b-feasibility-of-stateful-serving-kv-cache-reuse-priority-caching/343960).

### Hugging Face TGI

TGI uses PagedAttention and continuous batching
(https://huggingface.co/blog/continuous_batching,
https://huggingface.co/docs/text-generation-inference/en/conceptual/paged_attention).
The router is Rust-based and re-batches every decoder step. Shared-prefix
reuse is enabled by default and requires all layers to use full attention
(not sliding-window). No published session-aware scheduling beyond LRU.
Comparative study: arxiv:2511.17593 benchmarks vLLM against TGI; both use
PagedAttention; differences are primarily in continuous batching
implementation and routing.

### llama.cpp slot management

llama.cpp's `llama-server` treats each concurrent session as a "slot"
with its own KV cache; the slot count is fixed at startup. The `--slot-save-path`
flag enables REST endpoints `/slots/<id>/save` and `/slots/<id>/restore`
that persist a slot's KV cache to a binary file (hundreds of MB for long
contexts) and restore it "nearly instant versus re-processing the full
prompt"
(https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md,
https://github.com/ggml-org/llama.cpp/discussions/9781).

Community-documented patterns (https://github.com/ggml-org/llama.cpp/discussions/20572)
wrap this in a save/restore-per-turn hook. An open issue
(https://github.com/ggml-org/llama.cpp/issues/18703) notes the multi-model
router does *not* support slot save/restore, which matters for any homelab
stack that routes across models on one llama.cpp binary. A separate issue
(https://github.com/ggml-org/llama.cpp/issues/19466) documents that saved
slots do not work for vision-enabled models.

**Eviction**: slot slots are statically allocated; there is no automatic
eviction, but a busy slot can block a new session until it finishes. That is
a very different failure mode from vLLM/SGLang's LRU eviction.

### Session-aware scheduling - bigger picture

- **llm-d** (Red Hat, https://llm-d.ai/blog/kvcache-wins-you-can-see,
  https://developers.redhat.com/articles/2025/10/07/master-kv-cache-aware-routing-llm-d-efficient-ai-inference):
  distributed prefix-aware routing across replicas. The routing decision
  chooses the replica most likely to have the prefix warm.
- **DLPM** (above) for fairness + locality.
- **EVICPRESS** (arxiv:2512.14946) jointly optimizes cache eviction and cache
  compression to minimize average generation latency.

### Takeaway for Thread 3

All five production engines share the same basic model: sessions are
*emergent* from KV-prefix identity, not first-class. vLLM and SGLang lean on
LRU with locality tiebreaks; TensorRT-LLM adds priority caching; llama.cpp
alone offers explicit slot save/restore, at the cost of static slot count and
no automatic eviction. Under memory pressure, the general behavior is
"evict the private suffix of the least-recently-used session and let the
next turn redo the prefill." That is cheap on latency (seconds) for a 4K
context, expensive (tens of seconds) for a 32K+ context. For multi-tenant
homelab use, DLPM-style fairness is probably needed unless usage is
self-coordinated.

Key sources for Thread 3:
- https://arxiv.org/abs/2309.06180 (PagedAttention / vLLM)
- https://docs.vllm.ai/en/stable/design/prefix_caching/
- https://arxiv.org/pdf/2312.07104 (SGLang / RadixAttention)
- https://arxiv.org/html/2501.14312 (DLPM fairness)
- https://nvidia.github.io/TensorRT-LLM/advanced/kv-cache-reuse.html
- https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- https://lmcache.ai/tech_report.pdf

---

## Thread 4 - Failure modes when context is reassembled across a swap

**Framing.** Beyond Junie's "context evaporation," what specific failure
modes does the literature document when a session resumes with either a
different model or the same model after KV-cache eviction?

### 4.1 Silent capability regression

The Gemini CLI model router issue (https://github.com/google-gemini/gemini-cli/issues/12945)
is the cleanest first-person account: Flash is weaker at long context than
Pro, so when the router switches mid-session for cost reasons, users see
session quality decline without any explicit error. The router makes no
claim of equivalence, but the UX does.

RouterBench (arxiv:2403.12031) and RouteLLM
(https://github.com/lm-sys/RouteLLM) quantify the cost-quality frontier at
the *single-query* level but do not measure "capability cliff within a
session." Inference: the single-query studies probably underestimate the
in-session regression, because a cheaper model can ride the coattails of
earlier expensive-model turns for a while before visibly failing.

### 4.2 Hallucinated prior state when given only a summary

This is LoCoMo's headline finding dressed differently: when a session is
reassembled from a summary the outgoing model wrote, the incoming model will
confidently infer details that the summary underspecified, rather than
asking. Maharana et al. (arxiv:2402.17753) document this as the information
loss in summary-vs-raw-transcript. The MemGPT paper describes the same
pathology: the fixed-context recursive-summary baseline "hallucinates"
details about past conversations, which the paginated-search variant avoids
by retrieving the original span
(https://arxiv.org/abs/2310.08560).

### 4.3 Role/persona drift

Kenneth Li et al., **"Measuring and Controlling Instruction (In)Stability in Language
Model Dialogs"** (arxiv:2402.10962,
https://arxiv.org/html/2402.10962v1 and
https://github.com/likenneth/persona_drift) define three automatic metrics
(prompt-to-line consistency, line-to-line consistency, Q&A consistency) and
demonstrate that chatbot *instruction stability* -- how consistently the model
follows its system prompt over the course of a dialog -- degrades measurably
even *without* a model swap. Synthetic multi-turn runs on Gemma 2, Qwen 3, and
Llama 3.3 show 20-40% turn-by-turn drops in Assistant-Axis projection over
10-15 turns in therapy/philosophy domains (https://www.emergentmind.com/topics/persona-drift).
Note: the paper is about instruction/prompt drift, not persona consistency per se --
"persona drift" is a colloquial shorthand for what the paper formally measures as
instruction instability.
For the swap case, inference: the new model was never conditioned by the
drifted instruction trajectory - it starts fresh from the system prompt. That
can be either a bug (user noticed a behavioural change) or a feature
(drift gets reset).

The Consistently-Simulating-Human-Personas work (openreview
https://openreview.net/pdf/109c600393cc962e64028e8425eca62778f40ee9.pdf)
reports 55%+ reductions in persona inconsistency with multi-turn RL. That
mitigation is single-model; no published equivalent for cross-model persona
anchoring.

### 4.4 Working-memory loss / re-litigation of decided facts

When the KV cache is evicted and only a compressed handoff remains, facts
that were decided-but-not-restated often get re-litigated. This is a direct
consequence of LoCoMo's information-loss finding plus the Lost-in-Multi-Turn
observation that models "latch onto early information and propose full
solutions prematurely, and once an incorrect answer appears, models
repeatedly build on it instead of backtracking"
(https://arxiv.org/abs/2505.06120). Combined: a summary that omits
"we already tried X and it failed" will let the new model propose X and
chase it confidently.

Acon (arxiv:2510.00615, https://arxiv.org/html/2510.00615v1) calls this out
explicitly for task-focused agents: "dialogue-oriented systems rely on
session-level summarization or tiered memories suitable for conversational
coherence but inadequate for multi-step carry-over." Task state is where
summary-based handoffs are most likely to fail.

### 4.5 Sycophancy amplification under reconstructed context

Sycophancy in LLMs (arxiv:2411.15287,
https://arxiv.org/abs/2411.15287) is well-documented: models agree with
loaded or leading questions at the cost of accuracy. Relevant to reassembly:
if the summary handoff is itself written by a model that has been
agreeing with the user's premises, the handoff payload carries a sycophantic
bias forward. The incoming model then treats that bias as established fact.
I did not find a paper measuring this specific chain (sycophantic summary ->
new-model prior) - that is inferred from the sycophancy literature plus
LoCoMo's information-loss finding.

Relatedly, minihf's "On ChatGPT Psychosis and LLM Sycophancy"
(https://minihf.com/posts/2025-07-22-on-chatgpt-psychosis-and-llm-sycophancy/)
and the "LLM Spirals of Delusion" audit (arxiv:2604.06188) report the
feedback loop in which a model's sycophantic reasoning trace is
generated to support an already-chosen path. Across a handoff, that already-
chosen path is what the summary preserves.

### 4.6 Prompt cache vs. KV cache mismatch at the serving layer

Two specific engineering failures I found documented:

- **Honcho / hermes-agent issue 13631**
  (https://github.com/NousResearch/hermes-agent/issues/13631): auto-injected
  context rebuilds the cached system prompt every N turns, invalidating the
  KV prefix cache on every prefix-caching backend. Effect: cache-breaking
  forces the full prefill every turn; latency triples or worse. This is a
  pure serving-layer failure - the model is fine, but the integration
  accidentally rewrites bytes in the prefix.
- **KV cache incompatibility across model architectures**: Hugging Face
  Transformers' Cache-strategies doc
  (https://huggingface.co/docs/transformers/kv_cache) notes that Mamba-style
  state-space models use a different cache class entirely from attention
  models, and that even within attention models, different architectures
  have different cache layouts. Inference: any "swap mid-session and
  keep the KV cache warm" plan is dead on arrival across architectures; the
  prefix has to be re-prefilled by the new model from text tokens.

### 4.7 The "grounding gap"

Shaikh et al., **"Grounding Gaps in Language Model Generations"**
(arxiv:2311.09144, https://arxiv.org/html/2311.09144.pdf) and the IWSDS 2024
conversational-grounding work
(https://github.com/aistairc/conversational-grounding-llm) argue that LLMs
skip the acknowledgment/confirmation phases human dialog partners use to
establish common ground. After a handoff, this is worse: the new model has
no shared-grounding history and will either pretend to have it or over-ask.
Neither is what a user wants.

### Takeaway for Thread 4

Concrete failure taxonomy for reassembly, rank-ordered by how well the
literature documents them:

1. **Information loss in summary handoff** - LoCoMo, MemGPT both document
   this quantitatively. Manifests as hallucinated prior state and
   re-litigation of decided facts.
2. **Multi-turn unreliability of the receiving model** - "Lost in Multi-Turn"
   confirms this even without a swap; a swap adds another perturbation.
3. **Instruction instability / behavioural drift** - Li et al. 2024 (arxiv:2402.10962)
   measured within-model instruction drift; cross-model effects unmeasured but
   probably sharper (the new model has no conditioning on the prior model's drift
   trajectory).
4. **Silent capability regression** - Gemini CLI issue, inferable from
   routing literature but not cleanly measured.
5. **Sycophancy inherited from the summary author** - inferred, not
   directly measured.
6. **Serving-layer cache breakage** - documented in specific integration
   issues; easy to hit with naive context injection.

Key sources for Thread 4:
- https://arxiv.org/abs/2402.17753 (LoCoMo)
- https://arxiv.org/abs/2505.06120 (Lost in Multi-Turn)
- https://arxiv.org/html/2402.10962v1 (Persona Drift)
- https://arxiv.org/abs/2411.15287 (Sycophancy)
- https://github.com/NousResearch/hermes-agent/issues/13631 (cache breakage)
- https://huggingface.co/docs/transformers/kv_cache (architecture
  incompatibility)

---

## Synthesis

**Load-bearing findings across the four threads, for anyone building a
session-persistent multi-model homelab stack:**

1. **Sessions in modern serving engines are emergent from KV-prefix
   identity, not first-class.** Only llama.cpp offers explicit `/slots/N/save`
   and `/slots/N/restore`; vLLM, SGLang, TGI, TensorRT-LLM all rely on LRU
   over paged/radix KV caches. Cross-model prefix transfer is impossible -
   KV cache layouts are architecture-specific. Any mid-session model swap
   must re-prefill from text tokens.

2. **Single-model multi-turn already loses ~40% reliability** (Lost in
   Multi-Turn). Mid-session model swap starts from that degraded baseline.
   Any A/B of swap strategies must measure against a same-model-continuation
   baseline, not single-turn performance.

3. **Summary-only handoff is the worst-performing payload shape** (LoCoMo,
   MemGPT). The empirical ordering is: raw transcript > transcript +
   structured retrieval (MemGPT) > structured facts alone (Mem0) >
   outgoing-model summary. Mem0 trades ~6 accuracy points for ~12x latency
   and ~10x cost wins - often the right tradeoff for a home rig.

4. **The concrete failure modes of reassembly are:** hallucinated prior
   state, re-litigation of decided facts, persona reset, silent capability
   regression, and inherited sycophancy. The first two are measured; the
   last three are inferred from adjacent literature.

5. **Serving-layer failure is a separate surface.** Naive context injection
   (Honcho-style) can break the prefix cache on every turn, turning a
   fast-prefill session into a slow one - independent of any quality
   regression.

**Open questions not addressed by the literature:**

- Does explicit mid-session model swap ever *improve* quality, e.g., by
  breaking a "lost in multi-turn" trajectory? Untested.
- What is the right handoff payload when the incoming model is a *smaller,
  weaker* model? Mem0 and MemGPT both assume the receiving model is
  comparably capable.
- How should a session-aware scheduler treat sessions that explicitly opt
  into model swap? DLPM and llm-d optimize for locality; neither accounts
  for a session that wants to fragment across models deliberately.
- How do persona metrics behave across a swap? No paper I could find
  measures Li et al.'s persona-drift metrics with a mid-session model
  change.

For a homelab second-opinion stack, the practical implication is: use
llama.cpp slot save/restore for durable per-session state on the primary
model, use a Mem0-style structured-facts payload as the portable
cross-model handoff, keep the raw transcript in reserve for when the
receiving model re-queries, and build an internal eval harness modeled on
LoCoMo sessions. The literature supports each of those choices
individually; their combination appears to be original territory.
