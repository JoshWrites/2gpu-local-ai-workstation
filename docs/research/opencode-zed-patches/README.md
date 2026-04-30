# opencode-zed-patches: research narrative

The diagnosis, the planning, and the dead ends behind the patches that
fix opencode's bash permission UX in Zed.

## Where the operational artifacts live

The patches themselves, the install instructions, and the smoke test
live in a separate repo, included as a submodule at
`../../opencode-zed-patches/` from this directory. That repo is the
"what to install" surface; this directory is the "why and how we got
here" surface.

- Top-level patches dir (submodule): `../../opencode-zed-patches/`
- Standalone repo (when published): `github.com/JoshWrites/opencode-zed-patches`

## What lives here

| File | What it captures |
|---|---|
| `original-research-readme.md` | The original starting-point readme: the bug surface, root cause from a source walk, five options considered, the hybrid plan that informed the work. The first 80 lines are still a good orientation read. |
| `findings-source-walk.md` | A walk of opencode's permission flow through `bash.ts`, `acp/agent.ts`, and the SDK glue. Identifies the exact lines where the empty metadata flows through. |
| `fix-1-title.md` | The plan for Fix 1 (permission card shows the actual command). What needed to change, where, and why the change was minimal. |
| `fix-2-plan.md` | The plan for Fix 2 (verbose consent: cwd header, persistent command title, terminal-output streaming). |
| `fix-2-research-report.md` | Research that informed Fix 2: the ACP `_meta.terminal_*` convention, what Claude Code's adapter does, what Zed's renderer expects. |
| `decision-log.md` | The choice between a stdio-proxy shim and a patched-binary approach. Records why the patched-binary path won. |
| `race-finding.md` | A race condition discovered during Fix 2 development around terminal output buffering. How we caught it and what the fix was. |
| `pr-7374-diff.patch` | An upstream PR (closed unmerged Feb 2026) that attempted roughly the same agent.ts fix. Kept here because the original-research-readme cites it as the closest prior art. |

## Reading order

For someone trying to understand the work end to end:

1. `original-research-readme.md` first 60 lines: the bug, the root cause, the five options.
2. `findings-source-walk.md`: the source-level evidence behind the bug claim.
3. `decision-log.md`: why a local patch instead of a stdio-proxy shim or an upstream PR.
4. `fix-1-title.md`, then look at `our-patch-agent.diff` in the submodule to see what shipped.
5. `fix-2-plan.md` and `fix-2-research-report.md`: the verbose-consent design.
6. `race-finding.md`: a real bug that surfaced during implementation.

The submodule's README focuses on installation. This README focuses on
the why. The two together answer "what did you do" and "why did you do
it that way."
