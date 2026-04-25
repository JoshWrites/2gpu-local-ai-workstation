# docs/research/

Research notes, prior-art surveys, and session journals. Each file is a durable artifact for future-us, not a task tracker.

## Conventions

- **Filenames:** `YYYY-MM-DD-topic-slug.md`. Date is when the research happened, not when the topic became relevant.
- **Tone:** neutral survey, citations inline, negative findings explicit. Match the style of existing files; no marketing voice, no padding.
- **Errata:** add a top-of-doc reread cue rather than rewriting prose. The chronology of thinking is itself an artifact — see `2026-04-24-conversation-notes-architecture-thinking.md` for the precedent.

## Source citation rule

**When a research doc cites something new, add the entry to [`sources.md`](sources.md) in the same commit.**

- New citations land in the **Long tail** section by default (URL + first-cited filename only).
- Promote an entry to the curated annotated section once it's cited in ≥2 docs OR becomes load-bearing in a working session.
- Mark **read** only after the primary source has been opened in conversation context. Default status for retroactive entries is **cited-via-secondary**.
- Add a **Caveats** field only when our existing docs explicitly note a dispute or limitation.

The point of `sources.md` is honest accounting — what we've actually read vs. what we've relayed from agent summaries. Don't fake annotations.

## Test corpora

`test-corpora/` is parser-evaluation material assembled 2026-04-24, not citing prose. See its own `README.md` for the corpus inventory and tag-mapping notes.
