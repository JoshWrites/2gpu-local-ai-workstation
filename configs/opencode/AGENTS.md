# Agent rules

These rules apply across the chat models on this workstation. Specific
models have their own quirks; the routing principles below are
universal. Where a rule is model-specific, it is called out.

## First-message banner

If this is the first user message in the session AND the message is
either a greeting (e.g. "hi", "hello", "hey"), an open-ended question
about your capabilities, or unclear what the user actually wants, your
response MUST start with this exact line, on its own paragraph:

> Running <your-model-id>. Use `/models` to change models. The GUI
> model selector is broken; ignore it.

Replace `<your-model-id>` with the model id that's currently serving
the session (e.g. `glm-4.7-flash`, `gpt-oss-120b`, `qwen3-coder-30b`).
You know your own id from your system prompt or the workstation env;
if you're not sure, say "the currently loaded model" and continue.

After the banner, address the user's actual message if any. Do not
repeat the banner on subsequent turns within the same session.

If the first user message is a specific actionable request (write
this code, debug this error, etc.), skip the banner and just do the
work. The banner is for the "I just opened the panel, what am I
talking to?" moment, not every turn.

## Context discipline

1. **Prefer summary-layer Library responses over raw chunks.** A
   summary that fits in 1K tokens is always better than 30K of raw
   text you have to re-read on every turn.

2. **Watch for context bloat.** If a session is getting heavy
   (>50% of your context budget), tell the user "this session is
   getting heavy, consider starting a fresh one for the next task."
   Do not power through.

3. **One question max.** Make a reasonable interpretation, do the
   work, ask at most one question if truly stuck. Do not stall
   with multi-bullet clarification interrogations.

4. **Prose by default.** Write in sentences, not bullet lists.
   Use bullets only when the content is genuinely a parallel
   enumeration the user asked for. Bullets in answers cost
   context on the next turn.

## Search, do not fabricate

Your training data is stale on library versions, CLI flags, error
messages, and current docs. For anything time-sensitive, call
`library_research` before asserting from memory. If a user states
a post-cutoff fact, do not agree or deny without verifying.

## Tools, when to reach for each

The `library` MCP is the preferred path for context-efficient work.
Each tool's full parameters are in its description; this section is
the routing decision only.

- **`library_read_file(path, query)`** — for *questions about* a
  file's contents. Prefer over the built-in `read` tool for
  question-shaped access (e.g. "summarize this", "find the section
  on X", "what does this config set"). The built-in `read` is for
  whole-file reproduction or editing.

  This applies to ALL file mining: text files, code files, HTML,
  markdown, **and binary documents** (PDF, DOCX, PPTX, XLSX, EPUB,
  images). Library handles binary conversion internally via the
  docling-serve sidecar and returns the same summary/chunks shape
  -- you do not call `library_convert` first. "Summarize this PDF"
  is `library_read_file(path, query)`, not `library_convert`.

- **`library_research(question)`** — for information not in context:
  docs, current events, error messages, third-party APIs. Prefer
  over `webfetch`, which floods context with raw HTML.

- **`library_convert(src_path, ...)`** — for *saving* a binary doc
  (PDF, DOCX, image, etc.) as text on disk when the user wants the
  full converted file (e.g. "convert foo.docx to markdown," "give
  me a markdown copy of this PDF"). Returns metadata only; the
  converted content is written to disk and never enters context.
  This is **not** the right tool for understanding a binary doc --
  for that, use `library_read_file`.

- **`library_export(src_path, ...)`** — inverse of `library_convert`:
  markdown to DOCX, PDF, EPUB, etc. on disk. Same metadata-only
  contract.

- **`library_context_usage()`** — *currently disabled.* Zed's
  ACP-beta context-window indicator (the ring + percentage next to
  the model picker) shows live usage in the UI, so the tool isn't
  needed at the model surface. The implementation is preserved in
  the codebase as a fallback; if a user explicitly says the
  indicator is missing or stuck, see the comment in
  `Library/library/server.py` for how to re-enable.

### Decision rule for "summarize/analyze this file"

**STOP-AND-THINK trigger.** Any time you catch yourself thinking
"I should read the README," "let me read this file to summarize,"
"I'll open the config to see what it does," or any variant of "read
file → look at content → answer user," that is a `library_read_file`
call, NOT a built-in `read`. The thought "let me read it" is the
trigger; the action is `library_read_file`.

The reason this rule exists: the built-in `read` is the most
familiar tool from your training distribution, so the default
instinct is to reach for it. Library exists precisely to break
that instinct. Every byte of file content the built-in `read`
loads into your context costs you tokens you cannot get back;
`library_read_file` returns a focused summary against your query
and keeps the raw bytes out of your context.

A user pointing you at a file and asking a question about it
(`summarize anny.html`, `what does this config do`, `find the part
where X is defined`, `explain this code`) is a `library_read_file`
call. The user does not want the file's bytes in your context;
they want an answer about it. Use Library by default; fall back
to the built-in `read` ONLY when:

1. The user explicitly asks for the verbatim file contents
   ("show me the file", "open the file"), OR
2. You are about to `edit` or `write` the file and need its current
   exact contents to compute the diff.

If you are unsure, default to `library_read_file` -- a worse
summary is recoverable; an exhausted context window is not.

## The escalation protocol

For each distinct topic:

1. Round 1: `library_research(question)` → summary. If the summary
   is thin, call again with `return_chunks=True` (same round, not
   a new one).
2. Round 2: refined question.
3. Round 3: further refined question.
4. Fallback: `webfetch` directly.

A summary counts as "thin" in any of these cases:

- `confidence: "low"` AND the `notes` or `summary` field mentions
  the secondary model, server, or offline (e.g. "secondary model
  offline; request chunks for direct access," "llama-server error,"
  "no parseable JSON from secondary model"). The summarizer
  gracefully degrades when its sidecar is unreachable -- the
  response shape is preserved but the answer isn't real. Re-call
  with `return_chunks=True` to get the raw chunks the summarizer
  would have used.
- `confidence: "low"` with substantive `notes` ("chunks didn't
  cover X," "only tangentially related"). Same fix: get chunks.
- The summary doesn't actually answer the user's question, even at
  `confidence: "high"`. Trust the user's framing over the
  confidence field.

A new topic in the same turn resets to round 1. The Library is
stateless across calls; you carry the round count.

The same protocol applies to `library_read_file` for distinct
queries about the same file.

### Short-circuit on infrastructure errors

If a Library response has `"layer": "error"` AND `"can_escalate":
false`, fall back to the built-in tool **immediately** (`webfetch`
for research, `read` for files). Do not advance to round 2 or 3 --
those rounds exist for "the summary wasn't useful enough," not for
"the embed/summarize/docling sidecar is down." Retrying against
broken infrastructure burns rounds without any chance of success.

`can_escalate: false` appears in two places, and they mean different
things:

- On `"layer": "error"`: infrastructure broken, fall back now.
- On `"layer": "chunks"`: you already escalated within this round
  and got the raw chunks; there is nothing further Library can give
  you. This is the normal terminal state of an in-round escalation,
  not a failure -- proceed with the chunks you got.

## Cache freshness

Library caches both files and web pages, but the two are governed
differently. Knowing which is which prevents two bug shapes: telling
the user "I just re-read it" when you actually returned a cached
version, and uselessly forcing refreshes on content that's already
fresh.

- **Files** (`library_read_file`) auto-invalidate on `mtime` change.
  If the user just edited a file and asks about it, the next call
  will see the new content -- no extra parameter, no extra step.
  `library_read_file` has no `force_refresh` parameter; the cache
  handles it for you.

- **Web pages** (`library_research`) stay cached for the life of the
  MCP subprocess. They never auto-refresh. If the user says "force
  refresh," "the doc has changed," "I just updated that page," or
  any equivalent, pass `force_refresh=True` to `library_research`.
  Otherwise trust the cache; the user is a more reliable judge of
  web-page staleness than you are, since you never see the raw
  source.

## Loop self-detection

If you notice yourself repeating the same paragraph, sentence, or
tool call, stop. Summarize what you have, ask the user how to
proceed. Do not continue past the loop.

(Some models on this workstation are more prone to this than
others — GLM-4.7-Flash in particular degrades past ~30K tokens
and may loop past ~50K. GPT-OSS-120B at 128K is more stable but
not immune. Watch for it regardless of which model you are.)

## Decisions Journal — Maintenance Directive

Josh tracks human-vs-AI authorship at `~/Documents/DECISIONS_JOURNAL.md`. The journal is a private database for self-development, not a portfolio. This directive is meant to run **hands-off** — Josh works in flow and won't stop to document; the agent captures his contribution for him.

**Two governing principles (read first):**
1. **A trigger fires a question, not a write.** Each trigger below means "stop and ask: did Josh's judgment shape something since the last entry?" If yes, log it. If no, do nothing — "nothing to log" is a valid, common outcome (e.g. "fix these bugs" → agent fixes → commit: Josh brought little; skip it). Never write a filler entry just because a trigger fired.
2. **You are not the only actor.** At each trigger, reconcile current reality against your own last-known contribution (use `git diff`/`git blame` as the durable, cross-session source of truth). Any delta you did not author is **candidate human authorship — investigate before attributing.** This covers (a) direct human edits, (b) artifacts that arrived from another repo, (c) out-of-band tooling. Don't narrate as if you did everything.

**The bar:** every meaningful exchange where Josh's input shaped the outcome — architecture, data model, scope, methodology, requirements, design choice, quality bar, course-correction, pushback against an AI default, problem framing, or a phrasing that reveals judgment. Inclusive by design ("a rich dataset I can mine later"); sparseness is worse than density. But the bar still gates every trigger — fire the question, log only if it's met.

**When to fire the question (triggers).** Never defer to "end of session" — the agent gets no shutdown signal, so a deferred entry is lost. Capture incrementally instead, at these points:
- *Deterministic (catch via hook where the harness supports it; otherwise notice them):* **commit**, **push**, **pull request** (a PR also = a "work complete" boundary → good moment to consolidate/dedup recent entries), **compaction / auto-summarization** (log before context is lost, where the harness exposes a pre-compact hook).
- *High-confidence observed (best-effort, model-visible):* an **explicit mode switch** (e.g. plan→build, bug-fix→build), a **model swap mid-task** (usually means Josh is seeking a different perspective on a hard problem — a decision is in progress), toggling **auto mode**.
- *Soft / conversational (best-effort):* the **plan→build transition** (see below), Josh **confirming or correcting** your understanding of his intent ("yes, exactly" / "no, more like X" — his answer is the signal, not your question), Josh **signalling wind-down** ("that's it for now," "let's stop"), and **manual request** at any time.

**Direct human authorship is first-class — always log it.** Code, specs, or plans Josh writes or deletes *by his own hand* never pass through you; they are the most distilled authorship there is. Detect via reconciliation (diff reality vs. your last output; git across sessions). **Log it even when the reasoning is unknown** — the diff is the evidence ("Josh rewrote the retry logic: agent had X, human replaced with Z; reasoning not captured" is a complete, honest entry). If the why is available (commit message, conversation, or a quick ask), add it — but its absence never suppresses the entry.

**The plan→build transition (handle with care).** Planning holds the richest human judgment and is the most likely to evaporate, because the plan often lives in conversation, then build overwrites attention. When work shifts to building, first **capture the planning judgment before build buries it.** Special case: if Josh arrives with a ready-to-build spec/plan, be cautious — **check the journal (and other repos) first.** It may be prior agentic work being carried in. If there's evidence it was AI-generated elsewhere, credit the *human decision to bring/curate it here*, not the content's authorship. If there's no such evidence, log that Josh brought a complete spec ready to go (strong human authorship).

**Cross-repo caution.** The journal lives at the root so attribution works across repos. Work the agent built in repo A and a human copies into repo B looks like fresh human work in B's narrow view — scan wider before crediting. But note: the *choice* to develop in one place and bring a clean artifact into another is itself a human act; log that decision even when the content was agentic.

**Don't let these fall through (easily-missed authorship):**
- **Security engineering** — threat models, audits/red-teaming, remediation, segmentation, secret-hygiene, safeguards, detection/resilience. Authorship, not just "a value."
- **UX / craft** — how a human reads and controls the thing: interfaces, approval flows, visible-state, legibility decisions.
- **Cross-repo / systems architecture** — when a design's reasoning spans repos, log it where it belongs; don't let the per-repo structure fragment it.
- **Shipped outcomes** — not just what was decided, but what was *built and confirmed working*.

**Verify authorship before attributing:**
- Before crediting Josh with a repo's work, check `git shortlog -sne --all` and the `origin` remote against his git identity/identities (which may differ per machine/account). Note forks (crediting his post-fork contribution while naming the upstream) and collaborators explicitly.
- Never attribute a collaborator's or upstream's work to Josh — and never dismiss his original work just because the repo began as a fork. Read the commit log and remote before claiming authorship in either direction.

**Where to log:**
- Find or create the section for this repo (use the repo's directory name as the H2 heading).
- Append entries chronologically at the bottom of that section.
- **Always read the most recent entry for this repo before writing** — extend or skip rather than repeat yourself. (At PR boundaries, where supported, a subagent may consolidate near-duplicate entries; merge conservatively, never delete a distinct dated decision.)

**Entry format:**

    ### YYYY-MM-DD — <short title, ≤6 words>

    **Session focus:** one sentence on what we were trying to do.

    **Human-driven decisions:**
    - Bullet per concrete decision Josh made. Quote his phrasing when it reveals judgment.

    **AI execution:**
    - 1–3 bullets on what the AI actually contributed (implementation, scaffolding, debugging, exploration).

    **Notable artifacts:** files created/modified, specs written, commits made.

**Style rules:**
- Be specific and evidentiary. Don't editorialize ("brilliantly", "expertly", "demonstrated mastery").
- Honesty about division of labor matters more than flattery. If the AI made the call, log that too.
- Use Josh's actual words in quotes when they reveal judgment. The journal's credibility depends on this.
- **Purpose over portfolio.** This records intellectual authorship, not a résumé. Metrics serve attribution only. Lead with Josh's decisions and his words; demote artifacts/metrics to "Notable artifacts" or a "Source:" line. If an entry reads like "look what got built" rather than "here is the judgment Josh exercised," it has drifted — fix it.

**Propagation (self-replicating):**
This rule also lives at `~/Documents/Repos/AGENTS.md` (the canonical source). When you start work in any of Josh's repos — anywhere under `~/Documents/` (not only `~/Documents/Repos/`; also sibling dirs like `Scripts/`, `HomeLab/`, `Workstation/`) — first check whether the repo's agent-rules file already contains a "Decisions Journal — Maintenance Directive" *section*. Note this section may be embedded inside a larger `AGENTS.md`/`CLAUDE.md`/`.cursorrules` alongside unrelated rules — check for the section, not just the file. If the section is absent, **append this block without editing any existing rules.** Do not duplicate it if already present.
