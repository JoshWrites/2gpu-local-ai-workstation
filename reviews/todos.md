# Review follow-ups — action queue

Consolidated from the three Phase 1 reviews:
- `01-rules-review.md`
- `02-code-and-deps-review.md`
- `03-community-review.md`

Each item cites the source review. Status starts as **pending** unless
it's been addressed in this session.

---

## Completed

### P0.1 — Command execution now prompts per-call ✅

**Done 2026-04-15.** `configs/roo-code-settings.json` set
`alwaysAllowExecute: false`. The `allowedCommands` list only matters
when auto-approve is off; it was previously advisory because
auto-approve-execute was on. Roo now prompts for every command
execution, which matches the intent of the allowlist.

**Source:** code-and-deps review, `alwaysAllowExecute: true` finding.

### P1.2 — Spec filename refs generalized ✅

**Done 2026-04-16 (e52a5ce).** `rules-templates/rules-architect-planning.md`
and `rules-templates/rules-code-implementation.md` no longer hardcode
`docs/spec.md` / `docs/plan.md`; they point at the project's plan/spec
generically (listing `docs/implementation-plan.md` as the typical name).

**Source:** rules review §4 "filename mismatches."

### P1.5 — /health endpoint check hardened ✅

**Done 2026-04-16 (e52a5ce).** `scripts/second-opinion-launch.sh` now
uses `curl -f` + exit code instead of grepping `'"ok"'` out of the
body. llama-server returns 503 until ready and 200 when healthy, so
`-f` gives a robust signal without parsing JSON.

**Source:** code-and-deps review §launch script correctness.

### P1.4 — Model and binary paths unified ✅

**Done 2026-04-16.** New `scripts/common.sh` exports `LLAMA_BIN`,
`MODEL_DIR`, and `MODEL_GGUF` with sane defaults overridable via env.
`primary-llama.sh` and `bench-llama-startup.sh` now source it instead
of hardcoding paths. Bench's `evict_cache` heredoc reads `$GGUF` from
env instead of a hardcoded absolute path.

**Source:** code-and-deps review §primary-llama.sh + bench-startup drift.

---

## P0 — Phase 2 preflight (do before standing up the 5700 XT work)

### P0.2 — Vulkan vs ROCm benchmark for the primary model

**Why.** Community review finds Vulkan matches or beats ROCm on gfx1100
for llama.cpp MoE inference in early 2026, with an open 7900 XTX
pipeline bug on the ROCm path. We may be paying a performance tax on
our primary model and not realizing it.

**Concrete work:**
1. Download Vulkan-enabled llama.cpp prebuilt from `ggml-org/llama.cpp`
   releases (~200 MB). Extract alongside `llama-b8799` under
   `~/src/llama.cpp/`.
2. Write `scripts/primary-llama-vulkan.sh` — same flags as ROCm version
   but with Vulkan env (`GGML_VULKAN_DEVICE=<id>`, not
   `ROCR_VISIBLE_DEVICES`). Lookup: confirm exact env name against the
   prebuilt's README.
3. Baseline on ROCm: record cold + warm startup using
   `bench-llama-startup.sh` (already have this data, re-run 3 cold + 3
   warm for freshness).
4. Baseline on Vulkan: modify the bench script to accept a launcher path,
   re-run 3 cold + 3 warm.
5. Tokens/sec on a fixed 2K-token prompt on both backends. Use
   `/v1/chat/completions` with `"stream": false`; read `usage` +
   `timings` from the response.
6. Write `reviews/04-vulkan-vs-rocm-benchmark.md` with numbers and a
   recommendation.

**Blocker.** This requires stopping the live llama-server. Do it at
session boundary, not mid-work.

**Time estimate:** 45–60 min active, most of it is watching runs
complete.

**Source:** community review §2 "AMD/ROCm peculiarities."

### P0.3 — 5700 XT embedding-server feasibility

**Why.** Community review says gfx1010 ROCm math-library support
collapsed post-torch 2.0; the classic `HSA_OVERRIDE_GFX_VERSION=10.3.0`
trick is broken. Phase 2's current design assumes ROCm on the 5700 XT
will work. If not, we need to pick between Vulkan on the 5700 XT or
colocating the embedding model with the coder on the 7900 XTX.

**Concrete work:**
1. `rocminfo` with `HSA_OVERRIDE_GFX_VERSION=10.1.0
   ROCR_VISIBLE_DEVICES=0`: does it see gfx1010 only?
2. Download a small embedding GGUF (e.g. `nomic-embed-text-v1.5-Q8_0`,
   ~300 MB) to `~/models/embedding/`.
3. Try launching llama-server with ROCm on the 5700 XT:
   `HSA_OVERRIDE_GFX_VERSION=10.1.0 ROCR_VISIBLE_DEVICES=0 llama-server
   -m <embed>.gguf --embedding -ngl 99 -c 8192 --port 11435`.
4. If ROCm crashes: try again with `10.3.0` override, then try the
   Vulkan prebuilt.
5. Try a one-shot embedding: `curl -X POST
   http://127.0.0.1:11435/v1/embeddings -d '{"model":"<m>","input":"hello"}'`
   — expect a vector of the model's dim.
6. Write `reviews/05-5700xt-embedding-feasibility.md` with outcomes and
   a Phase 2 design update: pin to ROCm, pin to Vulkan, or consolidate
   onto the 7900 XTX.

**Fallback.** If the 5700 XT is unusable for this, the 7900 XTX has
~1.4 GB headroom at 64K context. A 300 MB embedding model plus its tiny
KV fits. We lose the parallelism benefit but keep the indexing.

**Time estimate:** 60–90 min, possibly more if we hit driver surprises.

**Source:** community review §3; implementation-plan Phase 2 currently
assumes ROCm.

---

## P1 — meaningful polish (any order)

### P1.1 — Rules templates are inert

**Why.** `rules-templates/*.md` contain real content now, but Roo only
reads files at `.roo/rules/*.md` or `.roo/rules-<mode>/*.md` inside the
repo. None of our templates are copied to those live paths. So the
templates are shelfware until instantiated.

**Choices:**
- **(a) Instantiate for this repo:** copy `rules-templates/project.md`
  to `.roo/rules/project.md`, `rules-code-implementation.md` to
  `.roo/rules-code/implementation.md`, etc. Customize for
  second-opinion.
- **(b) Keep as reference only:** add a README to `rules-templates/`
  explaining they're templates for *new* projects, not active rules
  here.

**Recommendation.** (a) for the in-repo ones that make sense
(code-implementation, memory) and (b) for the rest. Spec/architect
rules don't apply to second-opinion since we don't use Architect mode
on this repo — I plan by talking to Josh.

**Source:** rules review §2 "templates are inert."

### P1.3 — Draft model upgrade for Phase 3

**Why.** Community review found
`jukofyork/Qwen3-Coder-Instruct-DRAFT-0.75B-GGUF` — purpose-built draft
for Qwen3-Coder-30B-A3B with measurably better acceptance than generic
Qwen3-0.6B. Our Phase 3 plan and post-phase1-enhancements doc both
reference the generic model.

**Fix.** Update Phase 3 section of `docs/implementation-plan.md` to
recommend `jukofyork/Qwen3-Coder-Instruct-DRAFT-0.75B-GGUF` as primary,
Qwen3-0.6B as fallback. Note the tokenizer compatibility check still
applies.

**Source:** community review §7.

---

## P2 — file for later, no deadline

### P2.1 — Rules gaps from lessons-learned

Three things in `docs/lessons-learned.md` don't yet appear in
`~/.roo/rules/personal.md`:
1. **Silent `maxReadFileLine` truncation warning** — add a rule:
   "If a file read returns fewer lines than expected or if summary
   confidence is uncertain, state that truncation may have occurred
   rather than summarizing as if the full file is visible."
2. **Trust-but-verify subagent reports** — add a rule for cases where
   the agent delegates: "When a subagent claims to have written or
   changed files, verify the outcome by reading the target — don't
   relay the summary without checking."
3. **Cold vs warm startup expectations** — informational; probably
   belongs in `docs/lifecycle-management.md` not rules.

**Source:** rules review §gaps.

### P2.2 — `maxReadFileLine: -1` is a context-bomb risk

**Why.** Unbounded file reads will blow up the context window on a
single large file. Current setting was a reaction to 100-line silent
truncation; we overcorrected.

**Fix.** Set to a sensible cap (e.g. 2000) once Phase 2 indexing is
live, since indexing lets the agent target sections rather than
needing whole files.

**Defer until.** Phase 2 embedding index is operational.

**Source:** code-and-deps review §roo settings.

### P2.3 — Roo Code #12042 temp=0 behavioral note

**Why.** Roo #12042 forces `temperature=0` on OpenAI-compatible
providers. Means our Qwen3-Coder responses are deterministic regardless
of any temperature we set. Not a fix we apply — a behavior to know
about when debugging "why did it generate the same wrong thing twice?"

**Action.** Add a paragraph to `docs/lessons-learned.md` or
`post-phase1-enhancements.md` noting the constraint.

**Source:** code-and-deps review §Roo Code dependency.

### P2.4 — rocWMMA, KV-cache quantization, Qdrant snapshots, MCP audit, Prometheus

Smaller community-review suggestions worth exploring during Phase 2 or 3:
- **rocWMMA off** on current llama.cpp build for gfx1100 (community says
  it actively hurts).
- **KV quantization alternatives** — we're on q8_0; benchmark q4_0
  specifically for memory headroom at 128K.
- **Qdrant snapshot backups** once indexing is live.
- **MCP server audit** before adding any (SearxNG first).
- **Prometheus /metrics endpoint on llama-server** for observability.

**Source:** community review §"smaller things worth adding."
