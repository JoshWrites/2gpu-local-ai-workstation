# Lessons from the Roo era

Date: 2026-04-30
Status: closed chapter; documenting what carried forward.

## What the Roo era was

The first agentic-coding setup on this workstation used **Roo Code**, a
fork of Cline, running inside an isolated **VSCodium** profile. The
pairing made sense at the time: VSCodium had the editor surface and
extension system, Roo had a credible agent loop with rules files, and
together they let you run a real local-AI-driven coding session.

That stack was active from roughly mid-March 2026 through April 22.
Then the work shifted to opencode running in Zed, which is the current
production setup.

This doc captures the load-bearing decisions and mistakes from the Roo
era that survived the move. Not a blow-by-blow history; a list of
things that turned out to be true regardless of which agent you run.

## The decisions that carried forward

### Two-card hardware envelope

The 7900 XTX as the primary inference card and the 5700 XT as a
secondary support card was a Roo-era decision, validated under a
different agent than the one we run today. The conclusion holds:

- The primary card hosts one weights-heavy chat model at a time.
- The secondary card hosts smaller bursty workloads that the agent
  loop calls during a session.

What changed: the *kind* of secondary-card workload. Roo era plans had
the secondary running a "support intelligence" model (Phi-4 Mini
observer, aspect classifier, voice). That never shipped. The actual
secondary today runs Library MCP's summarize and embed services, plus
edit-prediction for the editor.

The hardware envelope held; the workload assignment changed.

### Rules-as-files

Roo's `.roo/rules/` and `.roo/modes/` directories taught us that agent
rules belong in plain markdown alongside the code. opencode's
`AGENTS.md` is the same shape. Move repos, the rules move with them.
Edit the rules in a regular editor. Diff them in git.

The `rules-templates/` directory still in this repo predates opencode.
The templates are still useful as a starting point for any agent
(opencode, future tools) that picks up a per-repo or per-project rule
file.

### The need for a "polite shutdown" coordinator

Roo era taught the value of an editor-exit hook that releases GPU
resources. With Roo and VSCodium, services were started by hand and
left running because there was no obvious moment to stop them.

The current `llama-shutdown` script and the `second-opinion-launch.sh`
wrapper grew from that lesson. They survive into the opencode-and-Zed
era unchanged in architecture, just retargeted at a different editor.

### Multi-user discipline

The Roo era ran under a single user. The need to support a second user
(a second person on the same workstation, or the same user reaching in
from a laptop) surfaced just as the Roo-to-opencode move was happening.
The polkit rule, the system-scoped llama services, and the launcher's
"refuse to stop if anyone else is using llama" logic all came from
that period. They apply equally to the new stack.

## The decisions that did not carry forward

### The "support intelligence" vision

The original architecture had a small secondary-card model running
permanently as an *observer* of the primary's conversation, extracting
"learnings" into a knowledge base, classifying topic shifts, and so
on. Phi-4 Mini was the candidate.

None of it shipped. The reasons are documented elsewhere (the
`watcher.py` writeup; the divergence note in `reference-guide.md`),
but the short version: in opencode-and-Zed the agent panel makes the
agent's behavior visible to the operator in real time. Aborts catch
gross failures. The remaining gap (confabulation, quiet scope-drift)
is real but smaller than the original observer architecture assumed.

If a future watcher returns, it will be a confabulation-and-drift
detector reading opencode session logs, not a Phi-4 observer reading
Roo transcripts. The shape of the problem changed when the surrounding
tool changed.

### The Roo Code fork

The original four-phase plan in this repo's old README ended with
"Roo Code fork" as a deferred phase. The fork would have added
support-intelligence integration, real-time observer hooks, and other
mechanisms tied to the observer architecture. None of those exist in
opencode-or-Zed today. Some are not needed (opencode's plugin API
covers some of the same ground); some are now hypothetical pending the
future watcher. The fork itself is off the roadmap.

### VSCodium-specific tooling

The `install-roo-modes.sh` script that merged repo rules into Roo's
custom-modes settings file is gone. Roo's settings DB at
`~/.config/VSCodium-second-opinion/User/globalStorage/...` is no
longer touched. The isolated VSCodium profile dir on disk is left as a
historical artifact. It does not get loaded by anything we run today.

## What this doc is for

When someone (you, a year from now; me; a stranger reading the public
repo) wonders "what was the original design and why did it change,"
this is the short version. The long version lives in the research
docs under `docs/research/2026-04-24-*` and in the `reviews/`
directory. Those are first-draft thinking artifacts; this doc is the
filtered output.

The "Roo Code in VSCodium" framing in the original README and
reference guide is preserved with status banners pointing at the
divergence. It is documented intent, not active code. The active
code targets opencode in Zed and is described in the rest of this
repo.
