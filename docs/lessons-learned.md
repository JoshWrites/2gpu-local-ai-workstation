# Lessons learned -- second-opinion Phase 1

Written 2026-04-15, end of Phase 1. Captured while context was still fresh.
Organized by the decision, not by chronology -- false starts sit next to
the fix that replaced them.

## Reference-guide drift

The April 2026 reference guide was a solid starting point but was wrong or
stale on several concrete details. Most of Phase 1's "revise and retry"
time came from trusting the guide instead of checking current state.

### GPU device indices were inverted

Guide assumed GPU 0 = 7900 XTX. Reality on `levine-positron`: GPU 0 =
5700 XT (gfx1010, 8 GB), GPU 1 = 7900 XTX (gfx1100, 24 GB). Every
`ROCR_VISIBLE_DEVICES` reference in the guide had the wrong value.

**Fix:** `ROCR_VISIBLE_DEVICES=1` in `primary-llama.sh` to pin the
primary model to the 24 GB card. Documented the confirmed mapping in
`systemPatterns.md`.

**Lesson:** always re-derive hardware addressing from `rocminfo` /
`lspci`, never trust a guide's default on a specific box.

### `HSA_OVERRIDE_GFX_VERSION` alone masked the GPU-selection bug

Setting `HSA_OVERRIDE_GFX_VERSION=11.0.0` globally made both cards report
as gfx1100 to ROCm. Without `ROCR_VISIBLE_DEVICES`, llama.cpp happily
enumerated both and defaulted to device 0 -- loading an 18 GB model onto
an 8 GB card. Caught it because the OS monitor showed 99% utilization on
the wrong card; the log looked superficially fine.

**Lesson:** HSA override is a compatibility hack, not a scope. Combine
with `ROCR_VISIBLE_DEVICES` whenever you care *which* card runs the work.

### Model choice was stale within days of the guide

Guide recommended Qwen3.5-27B Dense. Research in Phase 1 surfaced two
open llama.cpp bugs affecting exactly our stack: #21383 (ROCm illegal-
memory-access on agentic tool calls with quantized KV) and #20225 (full
reprocess every turn on long contexts). Swapped to Qwen3-Coder-30B-A3B
MoE, which also happens to be faster (3B active vs 27B dense).

**Lesson:** any LLM recommendation more than a month old deserves a
bug-tracker check before it goes into a plan.

### Ollama "restart on exit" trap in the original launcher

The first draft of `primary-llama.sh` had a `trap` that restarted Ollama
when llama-server exited. This would have silently re-enabled a service
the 2026-04-15 boot cleanup intentionally disabled. Caught because Josh
flagged the boot-cleanup baseline explicitly.

**Lesson:** reference guides assume conservative fallbacks; your baseline
may deliberately forbid them. Cross-check every auto-action against the
environment's documented constraints.

## llama.cpp flag churn

### `--flash-attn` changed signature in b8799

Guide used `--flash-attn` as a boolean flag. b8799 requires
`--flash-attn on|off|auto`. Silent error from the reference guide's
example; first launch failed at arg parse.

**Lesson:** llama.cpp releases quickly and breaks flags. Always do one
dry run (`llama-server --help | grep <flag>`) before trusting example
invocations.

### `-cram` is default-on in current builds

Guide treated prompt caching as something to configure. Current
llama-server defaults to `--cache-ram 8192` (8 GB host RAM prefix cache).
This is why the Phase 4 "aspect server" design from the reference guide
would have been redundant reinvention.

**Benchmarked:** 9,792-token identical prompt, 22.9s cold prompt eval
-> 22ms warm (9,791/9,792 tokens cached). **~1028x speedup.** Real, not
marginal.

**Lesson:** check current defaults before building abstraction around
"missing" features. The thing you're about to wrap may already exist.

## Roo Code surprises

### Provider profiles are encrypted in SQLite, not a plaintext file

Spent time grepping `globalStorage/rooveterinaryinc.roo-cline/settings/`
for a config file. Roo writes provider URL, model, API key, and headers
into VSCode's `secretStorage` -- which on Linux is libsecret /
gnome-keyring, encrypted, not plaintext-editable. The SQLite key is
`secret://...roo_cline_config_api_config` and its value is ciphertext.

**Fix:** configure once via the UI, export to JSON, point
`roo-cline.autoImportSettingsPath` at the JSON. Every editor start
re-imports from the JSON, so the repo is the source of truth.
Documented in `docs/roo-settings-management.md`.

**Lesson:** "programmatically manage this" does not mean "edit the
storage directly." Find the application's declared import/export path
and use it. Respecting encrypted storage is a feature.

### `huggingface-cli` is deprecated; use `hf`

Tried `huggingface-cli download ...`. Got a deprecation warning and no
download. Current CLI is `hf` (from `huggingface-hub >= 1.0`). Small
thing, five seconds to fix, but worth noting.

### Roo's first-run creates empty stubs, not a usable config

`globalStorage/rooveterinaryinc.roo-cline/settings/custom_modes.yaml`
starts as `customModes: []`. There's no "import" button visible until
you've configured a provider. The bootstrap path is necessarily
GUI-first. Can't ship a fully hands-free install.

### `maxReadFileLine: 100` silently truncates

First smoke-test: Roo read four docs, confidently summarized them,
missed the second half of each. No UI indicator that files were
truncated. Model confidently filled in what it couldn't see.

**Fix:** `maxReadFileLine: -1` in the autoImport JSON (restart to apply).

**Lesson:** any agent config that defaults to "read the first N of M
lines" is a silent-lie risk. Audit defaults for truncation behavior
when you onboard a new agent framework.

### Roo's Code mode over-plans simple questions

"What files are in this project?" in Code mode -> ten tool calls reading
every file and a follow-up question about next steps. 19% of 32K context
burned with no answer produced. Code mode's system prompt trains the
model to build a mental model before answering, which is the wrong
shape for exploration.

**Fix:** use Ask mode for exploration. Keep Code mode for actual edits.
Rolled the reasoning into `~/.roo/rules/personal.md`.

**Lesson:** modes are not just tool-scoping; they carry a prompt budget
and a behavioral shape. Use them as intended, not by habit.

### "Spec" mode from the reference guide is already in Roo as "Architect"

Spent time scaffolding `.roo/modes/spec.yaml` to match reference-guide
Part 5. Then inventoried Roo 3.52.1's built-ins and found Architect --
markdown-only edits, ask-clarifying-questions role -- is functionally
identical.

**Fix:** deleted the custom Spec mode, use built-in Architect, kept
Review as the one mode without a built-in equivalent.

**Lesson:** when a framework has "helpful defaults," enumerate them
before writing custom equivalents. Anchor list: go extract every
default from the shipped package source before the first customization.

## Phase 2 redirected mid-plan

Original Phase 2 design (from the reference guide): post-session observer
on the 5700 XT running Phi-4 Mini to extract learnings into
`~/.observer/` and per-project `.observer/` refs. Real effort: extraction
script, prompt engineering, two-scope index, session-start rule.

Rejected after Phase 1's Roo-reads-everything smoke test. The observed
pain wasn't "forgetting across sessions" -- it was **reading**. Roo burned
19% of context on exploratory full-file reads it couldn't even complete
(silent truncation). The right intervention is semantic retrieval over
the repo, not post-hoc extraction of conversation transcripts.

Roo already has codebase indexing built in. Qdrant backend, embedding
model pluggable. Phase 2 now stands up an embedding server on the 5700
XT and wires that integration instead. Less novel code, better match to
the actual problem.

**Lesson:** a plan written before using a thing will misjudge where the
pain lives. Run the Phase 1 system for real sessions before committing
Phase 2 design -- and be willing to discard work already specified if
data contradicts the premise. The observer idea isn't dead, just
demoted; it may return if memory-bank + indexing prove insufficient.

## Design decisions validated

### Isolation via `--user-data-dir`, not a second install

Initial thought: second VSCodium install (Insiders, flatpak) for the
agentic setup. Rejected on grounds of update burden. Next thought:
VSCode Profiles. Rejected on extension-host sharing. Final: separate
`--user-data-dir` + `--extensions-dir` launched via a wrapper script.

Worked cleanly. Normal VSCodium is untouched. Roo Code lives only in
the isolated instance. Launcher script + desktop entry make it feel
like a separate app. This is the right pattern for "experimental
environment inside a stable editor."

### systemd `BindsTo` for lifecycle, not a wrapper trap

First sketch of "stop llama when editor closes" was a wrapper script
with an EXIT trap. Rejected because VSCodium forks and detaches on
Linux when an instance is already running -- the wrapper exits
immediately, would kill llama while the user is still typing.

systemd user units with `Requires=llama... BindsTo=llama...` plus
`codium --wait` in the editor unit is the clean solution. Standard
Linux desktop-integration pattern. Survives crashes, no orphan
processes, no custom PID tracking.

**Lesson:** when coordinating process lifetimes, use the init system.
It already solved this problem.

### Benchmark before alerting

Built the yad splash with real phase thresholds derived from
`bench-llama-startup.sh` (3 cold + 7 warm runs). Variance was tiny
(+/-0.65s cold, +/-0.02s warm), so a 50% slack warn threshold is both
noise-proof and actually meaningful.

Skipping this step would have given either noisy false positives (too
tight) or alerts that never fire (too loose). 15 minutes of benchmarking
bought alert thresholds grounded in reality.

**Lesson:** any threshold-based alert needs data behind it. "Feels
right" is not a threshold.

## Epistemic / process lessons

### First-run reads need to be surfaced, not summarized

Subagents reported back with descriptions of work done. Several times
the description described what they *intended*, not what they wrote.
Verifying the actual files caught small divergences -- a dropped
`ROCR_VISIBLE_DEVICES`, a mode file in the wrong location, etc.

**Lesson:** trust but verify subagent reports. When the agent says "I
wrote X to Y," read Y.

### Push-back is a load-bearing feature

Explicit instruction to push back on faulty premises caught several
issues early: the Ollama restart trap, the Phase 4 reinvention of
`-cram`, the 5700-XT-as-post-session-observer framing. Each would have
been wasted work if agreed to politely.

**Lesson:** "say no when I'm wrong" is a tool, not a tone. Build it in
at the start; it compounds.

### Real use beats anticipated use

The 19% context burn, the silent truncation, the Code-mode over-planning
-- none were visible from reading the reference guide. All appeared in
the first five minutes of actually driving Roo. Phase 2's redirection
depended entirely on this.

**Lesson:** for any tool chain that will be used interactively, plan
only the minimum to reach first contact, then let contact shape the
next plan. Pre-planning past that point is speculation.

### Three cold-start samples is fine; seven warm-start samples is overkill

Benchmarking: 7 warm runs showed 20 ms variance. Three would have been
enough to establish the baseline. Didn't hurt -- total cost was 10 min --
but next time 3+3 would do.

**Lesson:** sample until the standard deviation stops moving. Extra
samples past that point are reassurance, not data.
