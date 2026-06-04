# Agent rules

Per-model behavior now lives in dedicated system-prompt files that swap
with the loaded model:

- **Per-model system prompts:** `configs/opencode/prompts/<model-id>.md`
  define each model's identity, reasoning discipline, strengths, and when
  it should suggest switching to a better-suited model. These are wired as
  the active agent's `prompt` and re-pointed by `scripts/model-swap.sh` on
  every model load, so the prompt always matches the loaded model.

- **Shared environment knowledge:** `configs/opencode/prompts/shared-environment.md`
  holds the universal tool-routing, Library escalation, context-discipline,
  and loop-detection rules that apply to every model. It is loaded
  additively via the `instructions` field in `opencode.json`, so it layers
  in alongside whichever per-model prompt is active.

This file (AGENTS.md) is still auto-discovered globally by opencode and
carries the self-replicating Decisions Journal directive below. Keep
operational agent rules in the prompt files above, not here, to avoid
duplicating content that `instructions` already loads.

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
