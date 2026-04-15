# Memory-bank rules template

Copy to `<project-root>/.roo/rules-code/memory.md` (and `rules-architect/`
equivalent if you want it in both modes). Applies wherever Roo touches
`memory-bank/`.

- `memory-bank/activeContext.md` is always current. Update it when the
  focus of work shifts — not after every commit, but when "what we are
  doing right now" genuinely changes.
- `memory-bank/progress.md` gets a dated entry at the end of each
  substantive work session. Terse: what changed, what's next, what's
  blocked. Never leave TODO stubs in the populated file.
- `memory-bank/decisionLog.md` records *decisions with lasting
  implications* — architecture, dependency picks, reversals. Skip minor
  tactical calls obvious from commit history.
- `memory-bank/productContext.md` and `systemPatterns.md` change rarely.
  Edit them when the project's shape or conventions shift, not for
  routine work.
- Never invent content to fill a stub. If you don't know, leave it empty
  and ask.
