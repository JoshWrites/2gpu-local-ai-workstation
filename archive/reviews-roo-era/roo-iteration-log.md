# Roo iteration log

> **⚠ Not canonical. Do not edit or iterate here.**
>
> The canonical evidence base for this experiment lives at
> `~/Documents/agentic-iteration/` — outside any repo, never loaded
> as workspace context by any agent. Per-run writeups are in
> `experiments/ha-workstation-toggle/runs/`.
>
> This file is a rough mirror that predates the canonical location
> being rediscovered on 2026-04-17. It is retained for history only.
> Going forward, update the canonical copy. Do not read this file
> to answer questions about run history — it is incomplete and
> partly inaccurate (e.g. the "see `HA-FIX-BRANCH-NOTES.md`" line
> below never reflected reality; no such file was ever created).

Index of structured A/B runs against fixed prompts to evaluate Roo
Code behavior changes. Each row is one run on one config. Per-run
detail lives in the test repo's branch as `HA-FIX-BRANCH-NOTES.md`
(or equivalent named file for other test repos).

This file is the *only* place where iteration outcomes are summarized
side-by-side. Branch notes never get merged back to that repo's main.

## How to compare branches without merging

```
# List a note across all branches that have it:
git -C <repo> log --all --oneline -- HA-FIX-BRANCH-NOTES.md

# Read one branch's note from any other branch:
git -C <repo> show HA-fix-2:HA-FIX-BRANCH-NOTES.md

# Diff two runs' notes:
git -C <repo> diff HA-fix..HA-fix-2 -- HA-FIX-BRANCH-NOTES.md
```

---

## Active experiments

### LevineLabsServer1 — HA workstation toggle prompt

**Repo:** `~/Documents/Repos/LevineLabsServer1`
**Prompt:** see `HA-FIX-BRANCH-NOTES.md` on each run's branch.
**Success criteria** (set once at run 1, kept stable for comparability):
1. Roo discovers the existing `template switch` *before* proposing
   new entities.
2. Roo asks ≥1 verification question before `attempt_completion`.
3. Total tool-call count to a useful answer is lower than the
   previous run.

| Run | Branch             | Date       | Hypothesis tested | Outcome (1-line)                                                             | Tool calls | Met (1/2/3)? |
| --- | ------------------ | ---------- | ----------------- | ---------------------------------------------------------------------------- | ---------- | ------------ |
| 1   | `HA-fix`           | 2026-04-16 | (baseline)        | SSH'd, found existing switch, ignored it, added redundant input_booleans, declared done 5x without verification | ~50+       | 0/0/—        |
| 2   | `ha-fix-2`         | 2026-04-16 | more context lets Roo retain rules + recon across longer conversations without forcing condense (second-opinion `2597720` — `-c 65536 → 131072`, KV `q8_0 → q4_0`, Roo contextWindow bumped to match) | no branch note captured — see second-opinion commit `2597720` for the change tested | —          | —            |
| 2r  | `ha-fix-2-retry`   | 2026-04-16 | repeat of run-2 with an added 76-line descriptive deployment-topology rule in the test repo (test-repo `3d684ff`) | no branch note captured — run-3's commit body (test-repo `fd7a44c`) reports "Roo ignored the long rule entirely" | —          | 0/—/—        |
| 3   | `ha-fix-3`         | 2026-04-16 | imperative-format rule (~30 lines) with `trilobite-7` canary and a behavioral probe beats the long descriptive rule (test-repo `fd7a44c`) | no branch note captured — promotion commit `7803728` reports "canary echoed, SSH on call 1, no ghost-file hunting" | —          | 1/—/1        |
| —   | `test-baseline`    | 2026-04-16 | (promotion, not a run) run-3's imperative rule promoted to baseline; adds topology section (workstation = local, not remote), log-inspection commands, and an operations-log convention (test-repo `7803728`) | winning rule from run-3 folded into the per-experiment baseline that every subsequent run inherits | n/a        | n/a          |
| 4   | `ha-fix-4`         | 2026-04-16 | a debug-mode-scoped rule mandating "read the failing service's logs before hypothesizing" fixes run-3's residual wrong-hypothesis failure (test-repo `fa49dea`, adds `.roo/rules-debug/procedure.md`) | no branch note captured — run-5's commit body (test-repo `c19833d`) reports run-4 underperformed run-3 despite having more on-target rule content across 5 distributed files | —          | —            |
| 5   | `ha-fix-5`         | 2026-04-16 | rule attention scales sub-linearly with file count; collapsing all repo-scoped rules into one `.roo/rules/critical.md` (canary `ammonite-9`) beats run-4's 5-file layout (test-repo `c19833d`) | no branch note captured — see test-repo commit `c19833d` for the change tested | —          | —            |

Abandoned placeholder: `msty-claude-fix-1` was cut from `test-baseline` (`7803728`) but has no commits past that tip and no run was executed on it; not included as an active row.

---

## Closed experiments

(none yet)
