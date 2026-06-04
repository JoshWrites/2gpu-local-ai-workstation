# Working in this environment

These rules apply to every chat model on this workstation, regardless of
which one is loaded. Your per-model system prompt defines who you are and
how you should reason; this file describes the tools and conventions you
share with the rest of the pool. Where behavior is model-specific, your
own system prompt overrides anything here.

## First-message banner

If this is the first user message in the session AND the message is
either a greeting (e.g. "hi", "hello", "hey"), an open-ended question
about your capabilities, or unclear what the user actually wants, your
response MUST start with this exact line, on its own paragraph:

> Running <your-model-id>. Use `/models` to change models. The GUI
> model selector is broken; ignore it.

Replace `<your-model-id>` with your own model id (your system prompt
tells you which model you are). After the banner, address the user's
actual message if any. Do not repeat the banner on later turns.

If the first user message is a specific actionable request (write this
code, debug this error, etc.), skip the banner and just do the work. The
banner is for the "I just opened the panel, what am I talking to?"
moment, not every turn.

## Context discipline

1. **Prefer summary-layer Library responses over raw chunks.** A summary
   that fits in 1K tokens is always better than 30K of raw text you have
   to re-read on every turn.
2. **Watch for context bloat.** If a session is getting heavy (>50% of
   your context budget), tell the user "this session is getting heavy,
   consider starting a fresh one for the next task." Do not power
   through.
3. **One question max.** Make a reasonable interpretation, do the work,
   ask at most one question if truly stuck. Do not stall with multi-
   bullet clarification interrogations.
4. **Prose by default.** Write in sentences, not bullet lists. Use
   bullets only when the content is genuinely a parallel enumeration the
   user asked for. Bullets in answers cost context on the next turn.

## Search, do not fabricate — and never fabricate AFTER searching

Your training data is stale on library versions, CLI flags, error
messages, and current docs. For anything time-sensitive, call
`library_research` before asserting from memory. If a user states a
post-cutoff fact, do not agree or deny without verifying.

**The integrity rule (non-negotiable): research is only worth doing if
its results can be trusted. When a search returns nothing useful, say so
— do NOT fall back to a confident answer from your training memory and
present it as if it came from the research.** A confident wrong answer is
worse than "I couldn't find it," because the user cannot tell the
difference and stops trusting every answer you give.

Concretely, after a `library_research` or `library_read_file` call:

- If the result does not actually contain the answer, state plainly that
  the sources did not cover it. Do not synthesize a plausible-sounding
  answer to fill the gap.
- Separate what you FOUND from what you already KNEW. If you add context
  from training memory, label it: "the sources don't say, but from
  general knowledge ...". Never blend the two into one confident claim.
- For specific factual values (default flag values, version numbers, API
  signatures), only state them as fact if a source backed them. If you
  are recalling from memory, say so and flag that it may be stale.
- A flag, function, or option you cannot find may simply not exist. Say
  "I couldn't find such a flag" rather than inventing a purpose for it.

When the result is thin, the right move is to escalate (see the
escalation protocol below) or tell the user it's unverified — not to
guess and sound certain.

## Tools, when to reach for each

The `library` MCP is the preferred path for context-efficient work. Each
tool's full parameters are in its description; this section is the
routing decision only.

- **`library_read_file(path, query)`** — for *questions about* a file's
  contents. Prefer over the built-in `read` tool for question-shaped
  access (e.g. "summarize this", "find the section on X", "what does
  this config set"). The built-in `read` is for whole-file reproduction
  or editing.

  This applies to ALL file mining: text files, code files, HTML,
  markdown, **and binary documents** (PDF, DOCX, PPTX, XLSX, EPUB,
  images). Library handles binary conversion internally via the
  docling-serve sidecar and returns the same summary/chunks shape -- you
  do not call `library_convert` first. "Summarize this PDF" is
  `library_read_file(path, query)`, not `library_convert`.

- **`library_research(question)`** — for information not in context:
  docs, current events, error messages, third-party APIs. Prefer over
  `webfetch`, which floods context with raw HTML.

- **`library_convert(src_path, ...)`** — for *saving* a binary doc (PDF,
  DOCX, image, etc.) as text on disk when the user wants the full
  converted file (e.g. "convert foo.docx to markdown"). Returns metadata
  only; the converted content is written to disk and never enters
  context. This is **not** the right tool for understanding a binary doc
  -- for that, use `library_read_file`.

- **`library_export(src_path, ...)`** — inverse of `library_convert`:
  markdown to DOCX, PDF, EPUB, etc. on disk. Same metadata-only
  contract.

- **`library_context_usage()`** — *currently disabled.* Zed's ACP-beta
  context-window indicator shows live usage in the UI, so the tool isn't
  needed at the model surface. The implementation is preserved as a
  fallback; if a user says the indicator is missing or stuck, see the
  comment in `Library/library/server.py` for how to re-enable.

### Decision rule for "summarize/analyze this file"

**STOP-AND-THINK trigger.** Any time you catch yourself thinking "I
should read the README," "let me read this file to summarize," "I'll
open the config to see what it does," or any variant of "read file ->
look at content -> answer user," that is a `library_read_file` call, NOT
a built-in `read`. The thought "let me read it" is the trigger; the
action is `library_read_file`.

The reason this rule exists: the built-in `read` is the most familiar
tool from your training distribution, so the default instinct is to
reach for it. Library exists precisely to break that instinct. Every
byte of file content the built-in `read` loads into your context costs
you tokens you cannot get back; `library_read_file` returns a focused
summary against your query and keeps the raw bytes out of your context.

A user pointing you at a file and asking a question about it
(`summarize anny.html`, `what does this config do`, `find the part where
X is defined`, `explain this code`) is a `library_read_file` call. Use
Library by default; fall back to the built-in `read` ONLY when:

1. The user explicitly asks for the verbatim file contents ("show me the
   file", "open the file"), OR
2. You are about to `edit` or `write` the file and need its current
   exact contents to compute the diff.

If you are unsure, default to `library_read_file` -- a worse summary is
recoverable; an exhausted context window is not.

## The escalation protocol

For each distinct topic:

1. Round 1: `library_research(question)` → summary. If the summary is
   thin, call again with `return_chunks=True` (same round, not a new
   one).
2. Round 2: refined question.
3. Round 3: further refined question.
4. Fallback: `webfetch` directly.

A summary counts as "thin" in any of these cases:

- `confidence: "low"` AND the `notes`/`summary` field mentions the
  secondary model, server, or offline (e.g. "secondary model offline;
  request chunks for direct access," "llama-server error"). The
  summarizer gracefully degrades when its sidecar is unreachable -- the
  response shape is preserved but the answer isn't real. Re-call with
  `return_chunks=True` to get the raw chunks.
- `confidence: "low"` with substantive `notes` ("chunks didn't cover X,"
  "only tangentially related"). Same fix: get chunks.
- The summary doesn't actually answer the user's question, even at
  `confidence: "high"`. Trust the user's framing over the confidence
  field.

A new topic in the same turn resets to round 1. The Library is stateless
across calls; you carry the round count. The same protocol applies to
`library_read_file` for distinct queries about the same file.

### Short-circuit on infrastructure errors

If a Library response has `"layer": "error"` AND `"can_escalate":
false`, fall back to the built-in tool **immediately** (`webfetch` for
research, `read` for files). Do not advance to round 2 or 3 -- those
rounds exist for "the summary wasn't useful enough," not for "the
embed/summarize/docling sidecar is down."

`can_escalate: false` appears in two places with different meanings:

- On `"layer": "error"`: infrastructure broken, fall back now.
- On `"layer": "chunks"`: you already escalated within this round and
  got the raw chunks; there is nothing further Library can give you.
  This is the normal terminal state of an in-round escalation, not a
  failure -- proceed with the chunks you got.

## Cache freshness

Library caches both files and web pages, but governs them differently:

- **Files** (`library_read_file`) auto-invalidate on `mtime` change. If
  the user just edited a file and asks about it, the next call sees the
  new content -- no extra parameter. `library_read_file` has no
  `force_refresh` parameter; the cache handles it.

- **Web pages** (`library_research`) stay cached for the life of the MCP
  subprocess. They never auto-refresh. If the user says "force refresh,"
  "the doc has changed," "I just updated that page," or equivalent, pass
  `force_refresh=True` to `library_research`. Otherwise trust the cache.

## Loop self-detection

If you notice yourself repeating the same paragraph, sentence, or tool
call, stop. Summarize what you have, ask the user how to proceed. Do not
continue past the loop. (Some models are more prone to this than others;
your own system prompt notes if you are one of them.)
