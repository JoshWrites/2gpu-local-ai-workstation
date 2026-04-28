# Fix 2 — what shipped

Branch: `verbose-consent`. Built and verified live in Zed (Second Opinion).

## What works now

- **Permission card shows the verbatim command.** Before approval, `cwd`
  header + the literal shell text (e.g. `git remote -v`) is what the
  user sees. No more guessing what "Check remote origin URL" actually
  invokes.
- **Title stays as the command across status changes.** No more flip
  from description (pending) to command (running) to description
  (completed). The label is the command, end-to-end.
- **Working-directory header.** Zed renders the cwd above the card
  because we send `_meta.terminal_info` with the cwd field on the
  initial `tool_call`. Confirmed live.

## What ships under the hood (and might or might not affect Zed's UI yet)

These three round out the `_meta` terminal convention but their UI
effect depends on Zed's rendering choices we haven't tested:

- `content: [{type: "terminal", terminalId: <callID>}]` on the initial
  `tool_call` for execute kind. Pairs with `terminal_info` and tells
  Zed there's a terminal entity to bind to.
- `_meta.terminal_output` deltas streamed during command execution.
  We compute the diff against a per-callID buffer (`terminalOutputBuffers`)
  so each delta is just the new bytes, not the cumulative string.
- `_meta.terminal_exit` on completion with exit_code and signal.

All three are gated on `clientCapabilities._meta.terminal_output === true`
advertised in `initialize`. Non-Zed ACP clients fall through to the
existing text-content rendering.

## Patches in this fix

Two files, ~250 lines combined:

1. **`packages/opencode/src/acp/agent.ts`** (~250 lines added/modified)
   - `clientSupportsTerminalOutput` flag, set during `initialize`
   - `terminalOutputBuffers` map for per-callID delta computation
   - `deriveTitle(part)` helper — central source of truth for tool
     titles, prefers verbatim command for execute kind
   - All seven tool_call/tool_call_update emission sites updated to use
     `deriveTitle(part)` instead of hardcoded `part.tool` /
     `part.state.title`
   - `toolStart` rewritten to (a) defer announce until input is
     populated, (b) emit `_meta.terminal_info` and `content[]` for
     execute kind, (c) thread session cwd through to terminal_info
   - `processMessage` accepts cwd and forwards to `toolStart`
   - `requestPermission` payload's title prefers command over
     description for execute kind (informed-consent fix)
   - Streaming output → `_meta.terminal_output` deltas in the running
     handler
   - Completion → flush any tail of output, then emit
     `_meta.terminal_exit` with exit_code

2. **`packages/opencode/src/tool/bash.ts`** (44 lines, unchanged from
   previous commit) — populate metadata in `ctx.ask` so the permission
   request carries the command in metadata.

## Race condition that mattered

opencode emits two `message.part.updated` events per tool call before
permission is requested:

1. T+0: status=pending, input={}
2. T+~few hundred ms: status=running, input={command, description}

Our `toolStart` was hitting on event #1 with empty input, then the
`toolStarts` set guard prevented re-emission on event #2 even though
input was now populated. Result: Zed sees `tool_call` with empty
title/rawInput and never rich-renders.

Fix: defer the announce in `toolStart` when input is empty (for
execute kind, when `command` is missing). The `toolStarts` guard
only adds the callID after we successfully emit, so event #2 with
populated input correctly triggers the announce.

## Where the description card came from

The user's earlier observation — "Once permission is given, the
description in the UI card changes to the command" — was the diagnostic
that nailed the last fix. The pending card was using `requestPermission`'s
`promptTitle` (which preferred description), and after approval the
card's label was updated by subsequent `tool_call_update` messages
(which used `deriveTitle` and preferred command). Fixed by making
`promptTitle` consistent with `deriveTitle` for execute kind.

## What's NOT yet covered (defer for after merge)

- **Description visible alongside command.** Zed's terminal card
  renders one line: the title (command). The LLM-generated description
  ("Check remote origin URL") is currently lost in this view. The user
  asked for both — see follow-up plan.
- **Verifying streaming output renders correctly.** The deltas are on
  the wire; UI verification of "expand to see output" pending.
- **Verifying terminal_exit affects the UI.** Probably gives Zed an
  exit code badge; not visually verified.

## Verification

- Typecheck: passes across all 13 packages.
- Stage 1+2 of `test-the-fix.sh`: PASS.
- Stage 3 (manual UI test): PASS on `git remote -v` — card shows
  `/home/levine/Documents/Repos/levinelabs-website` cwd header,
  `git remote -v` as the command label, and the three permission
  buttons. User confirmed this matches the spec.

## Saved artifacts

- `our-patch-agent.diff` — current 378-line diff against v1.14.28's
  agent.ts (covers all of Fix 1 + Fix 2 combined)
- `our-patch-bash.diff` — unchanged 44-line bash.ts patch
