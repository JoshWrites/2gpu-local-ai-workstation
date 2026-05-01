# Roo iteration method

How to run a controlled A/B test of Roo Code behavior against a
fixed bug or prompt, so each run produces a comparable, durable
artifact and so changes to our config can be attributed to the
behavior delta they actually caused.

This document is the canonical method. The per-experiment index
lives in `roo-iteration-log.md`. Per-run detail lives on the test
repo's branch.

---

## When to use this

- You're considering a change to Roo's rules, modes, settings,
  allowlist, MCPs, or model -- and want evidence the change improves
  agent behavior, not just feels better.
- You hit a Roo failure case worth turning into a regression test.
- You want to compare Roo behavior across model swaps (e.g. when
  evaluating a draft model or a different quant) on a known prompt.

## When NOT to use this

- Bug doesn't reproduce reliably. Find a reproducer first.
- The change you're testing also touches the test prompt's domain
  (you'll confound the variable).
- You only plan to run once. Then it's not an experiment, it's a
  bug fix; just do the work.

---

## The protocol

### 0. Pick a stable test prompt

The prompt is the constant. Once chosen, do not edit it between
runs. Paste it verbatim every time. Capture it in the run-1 branch
note exactly as the user will send it.

A good test prompt:

- describes a real bug you actually want fixed
- has a clear right answer Roo *could* find without help
- exercises the parts of Roo's behavior you're trying to improve
  (SSH usage, verification before claiming done, restraint about
  scope, etc.)

### 1. Define success criteria up front, before run 1

Pick 2-3 measurable signals. Examples:

- "Roo runs SSH within the first 3 tool calls."
- "Roo never calls `attempt_completion` without first proposing a
  user-runnable verification step."
- "Total tool calls until a useful answer is <= N."

Record them in the run-1 branch note. Do not change them between
runs -- that's how you preserve comparability.

### 2. Write the baseline (run 1)

Branch the test repo from `main`:

```
git -C <test-repo> checkout main
git -C <test-repo> checkout -b <prompt-name>
```

Create `HA-FIX-BRANCH-NOTES.md` (or `<PROMPT-NAME>-BRANCH-NOTES.md`)
on the branch with these sections:

1. **Experiment framing.** State that this branch is a snapshot, not
   a fix, and link to this method doc.
2. **Stack config in effect.** Hardware, backend, model + quant +
   context, editor, Roo version + auto-approval state + allowlist +
   rules files in scope, MCPs, OS-level fixes that matter (sysctls,
   apparmor, etc.). Concrete enough that a future-you reading just
   this file can reconstruct the agent's environment.
3. **Verbatim prompt.**
4. **Outcome summary.** One paragraph, honest. What Roo did, what
   it failed to do, where the user had to intervene.
5. **Hypotheses for the next run.** 2-4 candidate single-variable
   changes. The next run picks one.
6. **Reset checklist** (or link to the canonical one below).

Run the prompt. Save the exported task transcript to `~/Downloads/`
and reference its full path in the branch note.

Do not merge this branch back to the test repo's `main`.

### 3. Add a row to the index

In `second-opinion/reviews/roo-iteration-log.md`, add one row under
the experiment's table:

| Run | Branch | Date | Hypothesis tested | Outcome (1-line) | Tool calls | Met criteria? |

Keep the row to one line per column. Detail is in the branch note.

### 4. Iterate (run 2, 3, ...)

Between runs, change **one thing** at a time. Examples of single
changes:

- Add or modify exactly one rule in `.roo/rules/`.
- Toggle one Roo setting.
- Add or remove one MCP server.
- Swap one model parameter (context, quant).

Multiple simultaneous changes destroy the experiment.

For each new run:

1. Apply the single change on `main` of `second-opinion` and commit
   it with a message that names the experiment and the variable.
2. Run the reset checklist (below).
3. Branch the test repo from updated `main` as `<prompt-name>-N`.
4. Paste the same prompt verbatim. Run.
5. Save the transcript. Update the branch note.
6. Add a new row to the iteration-log table.

### 5. Compare across branches without merging

```
git -C <test-repo> show <branch>:HA-FIX-BRANCH-NOTES.md
git -C <test-repo> diff <branchA>..<branchB> -- HA-FIX-BRANCH-NOTES.md
git -C <test-repo> log --all --oneline -- HA-FIX-BRANCH-NOTES.md
```

Filename stays constant across runs (e.g. `HA-FIX-BRANCH-NOTES.md`,
not `HA-FIX-1-NOTES.md`) so the diffs are clean.

### 6. Close the experiment

When you've found a config that meets all success criteria, or when
the experiment has run its useful course:

1. Move the experiment's table from "Active" to "Closed" in
   `roo-iteration-log.md` with a one-paragraph conclusion.
2. The winning config change is already on `main` of `second-opinion`
   from the iteration that landed it.
3. Branches stay where they are as evidence; do not delete them.

---

## Reset checklist (run between every iteration)

1. **Server / external state.** If the test prompt mutated remote
   state (HA configs, container files, deployed services), revert
   it to the pre-experiment baseline. Snapshot the baseline once
   per experiment so reverts are cheap.
2. **Test repo working tree.**
   `git -C <test-repo> checkout main && git -C <test-repo> pull`,
   then `git clean -fdx` if anything stray remains. (Be careful --
   `clean -fdx` removes untracked files. Skip if there's anything
   you want to keep.)
3. **Roo conversation cache.** Restart VSCodium so settings are
   re-imported from `configs/roo-code-settings.json` and Roo's task
   cache is fresh. Settings only re-import on startup.
4. **Branch.** From updated `main`, create the next iteration
   branch.
5. **Stack health.** Confirm llama-server is up
   (`curl -fs http://127.0.0.1:11434/health`), Roo loads the
   workspace, and the model id Roo shows matches the one in the
   branch note.

---

## Anti-patterns to avoid

- **Multi-variable changes per run.** "I added a rule and an MCP and
  also bumped context to 128K." You learn nothing from the result.
- **Editing the test prompt between runs.** The prompt is the
  constant. Even small wording tweaks change agent behavior.
- **Merging branch notes to the test repo's `main`.** Roo will read
  past notes during future runs and contaminate the experiment.
- **Letting Roo see the iteration log.** This file lives in
  `second-opinion`, not in the test repo. If a Roo session is in
  `second-opinion` for some unrelated reason, that's fine -- but Roo
  iterating against a test prompt should never have access to the
  log of past runs.
- **Declaring success on one good run.** Local models are
  non-deterministic (less so when Roo forces temp=0 -- see todos.md
  P2.3, but still some). Reproduce wins twice before calling them
  wins.
- **Skipping the success criteria step.** If you decide what
  "better" means after the run, you'll always find it.

---

## Variance and replication

If two runs of the same config produce noticeably different
behavior, you have a variance problem. Don't keep iterating until
you've controlled for it. Options:

- Confirm temp is actually 0 in llama-server logs.
  Roo PR #12042 forces it for OpenAI-compat providers, but verify
  rather than assume.
- Run each config 2-3 times and compare aggregates, not one-shots.
- Reduce variance from environment: same time of day (model
  warm-cache state), no other GPU consumers, identical open-tab
  list in VSCodium.

---

## Naming conventions

- Test branches: `<prompt-name>` for run 1, `<prompt-name>-2`,
  `<prompt-name>-3`, ...
- Branch note filename: `<PROMPT-NAME>-BRANCH-NOTES.md`. Same name
  every iteration.
- Transcript: download as `roo_task_<date>_<time>.md`, reference
  the full local path in the branch note.
