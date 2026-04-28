# opencode-shim — research and decision log

Branch: `opencode-shim`
Started: 2026-04-28

## Goal

Make opencode a **first-class citizen of Zed** for this user's workflow:
1. **Phase 1 — local correctness.** Permission prompts must surface in Zed's UI with the actual command shown, so the user can approve/deny per-call (not via static allowlists).
2. **Phase 2 — remote serving.** The same opencode-in-Zed experience must work when opencode runs on the workstation while Zed runs on the laptop, mirroring the existing `work-opencode` SSH-based pattern (see `project_multi_user_opencode.md`).

Top priority is the user's daily setup. Community contribution is desired wherever possible without slowing down phase 1.

## What's actually broken (confirmed by reading source)

- **Bug surface:** When opencode requests permission for a bash command in an ACP session, Zed's UI shows the tool box but with no command text. User has no way to approve, and Zed's ACP integration silently rejects.
- **Root cause, exact location:**
  - `packages/opencode/src/tool/bash.ts:264` and `:273` — `ctx.ask({ permission: "bash", patterns, always, metadata: {} })`. The bash tool calls the permission system with **empty metadata**, even though `params.command` and `params.description` are in scope right above the call.
  - `packages/opencode/src/acp/agent.ts:209` — `rawInput: permission.metadata`. The ACP layer faithfully forwards the empty metadata as the rawInput field that Zed reads.
  - Same pattern probably affects edit/write/etc. permissions, but for `edit` the metadata IS populated upstream (filepath + diff), so edit prompts likely work.
- **What Zed's side does:** [Zed maintainer's response on issue #53249](https://github.com/zed-industries/zed/issues/53249) — opencode's ACP adapter doesn't use Zed's `terminal/create` RPC or the `_meta`-based `terminal_info`/`terminal_output`/`terminal_exit` convention. Claude Code's ACP adapter does, which is why Claude Code gets rich terminal cards and approval flow. Zed's stance is "this is the agent's job to fix."

## The fix everyone agrees on

In `acp/agent.ts`, when a `permission.asked` event is processed, look up the actual tool input (`part.state.input`) by `(messageID, callID)` and use that as `rawInput` instead of the (empty) `permission.metadata`.

Reference implementation: **PR #7374** (closed unmerged Feb 7 2026).

- Authored by `opencode-agent[bot]` against issue #7370.
- 21 lines, surgical.
- One user (`ssweens`) confirmed it resolves the issue.
- **Closed without any rejection comment, no maintainer review.** Best read: bot-PR auto-staleness, not a substantive "no." This means the upstream path is wide open.

The exact diff is preserved in `pr-7374-diff.patch` in this directory.

## Five paths considered

| Option | Cost | Permanence for user | Community benefit | Risk |
|---|---|---|---|---|
| 1. Local message-rewriting shim | 0.5–1 day | High (own it) | Low unless published | Low |
| 2. Finish & maintain `josephschmitt/opencode-acp` fork | 2–4 days | Medium | Low–medium | Medium-high (8mo stale, "response never finishes" open issue, depends on opencode SDK drift) |
| 3. PR to opencode upstream | 1–3 days | **Best** | **High** | Low (PR #7374 was bot-stale, not rejected) |
| 4. PR to Zed upstream | 2–5 days | Best | Highest (helps all ACP agents) | Medium-high (Zed's stance is "agent's job") |
| 5. PR to ACP spec | Weeks | Best (long-term) | Highest (long-term) | High latency, doesn't help short-term |

## Decision: hybrid plan

1. **Build a local fix immediately** (Phase 1). Two viable shapes considered:
   - **Shim:** stdio JSON-RPC proxy that splices `rawInput` back in from cached `tool_call_update`s. Independent of opencode's source. Quickest to ship.
   - **Patched opencode:** apply the PR #7374 diff to a local opencode build. Cleanest fix, but requires building opencode from source and keeping the patch rebased against upstream.

   **Choice: build the shim first** because:
   - It also serves as the foundation for Phase 2 (remote-serving) — see below.
   - It's testable in isolation against captured fixtures.
   - It doesn't require maintaining a fork of opencode.
   - It's reversible (delete a directory, restore Zed config).

2. **Submit upstream PR to opencode** (option 3) once the shim's logic is proven. The shim's transform code is the seed of the upstream fix; we can port the same logic into `acp/agent.ts` (mirroring PR #7374) and submit as a fresh, human-authored PR. If accepted: shim becomes obsolete eventually. If rejected/stalled: shim continues to do its job.

3. **Defer terminal-cards (#14034)** as a Phase 1.5 polish item — the `_meta` `terminal_info`/`terminal_output`/`terminal_exit` synthesis is ~2x the work of the rawInput fix and is not blocking. The user's actual ask is "I can choose to approve" — that's just the rawInput fix.

## Phase 2: remote serving

Critical transport finding from reading `packages/opencode/src/cli/cmd/acp.ts`:

- The `opencode acp` command is **hardcoded to stdio**: it reads from `process.stdin`, writes to `process.stdout`, and feeds those streams through `ndJsonStream` from `@agentclientprotocol/sdk`.
- Underneath, opencode's ACP handler talks to its own internal HTTP server (`Server.listen(opts)`). That HTTP server is network-capable and is what `work-opencode` already exposes via SSH port-forwarding for the TUI flow.
- **Implication:** opencode core is fine for remote operation, but the ACP↔client wire is locked to stdio. There is no built-in `opencode acp --listen tcp://0.0.0.0:9999` knob.

### Where the shim fits in remote serving

This is exactly why building the shim is the right Phase 1 choice — it becomes the natural layer for Phase 2:

```
Phase 1 (local):
  Zed (laptop) ──stdio──▶ shim ──spawn+stdio──▶ opencode acp
                              │
                              └─ rawInput cache + splice

Phase 2 (remote, option A — shim-as-bridge):
  Zed (laptop) ──stdio──▶ shim-client ──TCP/SSH/socket──▶ shim-server (workstation) ──stdio──▶ opencode acp
                              │                                   │
                              └─ optional latency hiding         └─ rawInput cache + splice

Phase 2 (remote, option B — SSH wrapper, no protocol change):
  Zed launches shim-bin which is itself a wrapper that does
    `ssh workstation /path/to/shim --spawn-opencode`
  and pipes Zed's stdio through SSH to the remote shim. Same as the existing `work-opencode` pattern, but with the shim on the remote end.
```

Option B is far simpler and probably correct for V1 of Phase 2: the shim binary doesn't need a network mode at all — it just needs to be runnable on the remote workstation, with Zed's stdio piped to it via SSH. This matches the `work-opencode` mental model and inherits all of SSH's auth/encryption/multi-user behavior for free.

Option A (custom transport) is only worth doing if SSH overhead becomes a problem (it shouldn't — ACP traffic is tiny ndjson).

**Phase 1 design constraint that protects Phase 2:** keep the shim as a single self-contained binary/script with no machine-local dependencies beyond the opencode binary it spawns. As long as the shim runs cleanly on both laptop and workstation, Phase 2 is mostly a `~/.config/zed/settings.json` change to wrap it in `ssh`.

## Files in this directory

- `README.md` — this file
- `pr-7374-diff.patch` — the upstream fix as a saved patch (the seed of our work)
- `findings-source-walk.md` — what we found reading opencode's actual ACP source
- `decision-log.md` — chronological notes as the build progresses

## Open questions for the build

1. **Does the bug only affect bash, or also other tools?** The fix in PR #7374 is general (always look up `part.state.input`), so the upstream fix is one-size-fits-all. The shim should also be general — splice rawInput for any tool that arrives empty.
2. **Are there cases where empty rawInput is intentional?** Plausibly yes for some tools without inputs. Need to defend against false splices: only splice if we have a cached non-empty value for that exact `toolCallId`.
3. **What's the right binary format for the shim?** Bun-compiled single binary makes deployment trivial (just scp). TypeScript run via `bun` works locally but adds a runtime dep on the remote side. Lean Bun-compile by default; document the alternative.

## Sources

- [PR #7374 — Fix ACP permission rawInput empty bug (closed unmerged)](https://github.com/anomalyco/opencode/pull/7374)
- [Issue #7370 — [ACP] Opencode sets rawInput back to empty](https://github.com/anomalyco/opencode/issues/7370)
- [Issue #14034 — [Zed ACP] Tool call panel doesn't display actual terminal commands](https://github.com/anomalyco/opencode/issues/14034)
- [Zed Issue #53249 — External commands not showing when running OpenCode Agent](https://github.com/zed-industries/zed/issues/53249)
- [Zed Discussion #49590 — Single source of truth for (external) Agent permissions](https://github.com/zed-industries/zed/discussions/49590)
- [josephschmitt/opencode-acp — partial community ACP adapter, abandoned Sept 2025](https://github.com/josephschmitt/opencode-acp)
- [Agent Client Protocol spec](https://github.com/agentclientprotocol/agent-client-protocol)
- opencode source: `packages/opencode/src/acp/agent.ts:190-250` (handleEvent for permission.asked)
- opencode source: `packages/opencode/src/tool/bash.ts:258-279` (the empty-metadata calls)
- opencode source: `packages/opencode/src/cli/cmd/acp.ts` (stdio-only transport)
