# archive

Historical artifacts that document what we did and what we learned but
are no longer load-bearing in the current stack.

## What lives here

`reviews-roo-era/` holds notes from the Roo Code in VSCodium phase
(roughly mid-March through 2026-04-22). Iteration logs, the A/B test
methodology, baseline commit markers, an overnight summary, and a
follow-up todo list. The Roo-era stack is documented in
`../docs/lessons-from-the-roo-era.md`; the artifacts here are the raw
material that distilled into that doc.

## Why keep it

Two reasons.

First, the stack evolved. The reasoning behind decisions like the
two-card hardware envelope, the rules-as-files pattern, and the
polite-shutdown coordinator came out of work that happened during
the Roo era. Deleting the artifacts would erase the evidence trail.

Second, the project has grown into a portfolio repo. Showing the dead
ends and the iteration that got us here is more useful to a reader
than presenting only the polished final state.

## What does not live here

Active code. The launcher, systemd units, llama-shutdown, and
opencode configs are all current and live in their normal locations
at the repo root.
