# Fix 2 plan — emit Zed's `_meta` terminal convention

## Goal

Match the user spec for permission cards:

> 2 lines verbatim command + 1 line description in the collapsed card;
> expand to see full output preview before approving.

## What "rich card" actually means in Zed

Zed has **two** code paths for permission cards on bash tool calls:

1. **Minimal card** (current): triggered when `kind: "execute"` and no
   `_meta.terminal_info`. Only renders `title`. No expander.
   Fix 1 makes this title useful; can't do more.

2. **Terminal card** (target): triggered when `_meta.terminal_info` is
   present. Renders working_dir, command label, time elapsed, output
   stream, and a Disclosure widget (chevron) for collapse/expand.
   This is what we need.

Code reference: `crates/agent_ui/src/conversation_view/thread_view.rs:5924`
(`render_terminal_tool_call`) — the rich card. Decoder for the convention
is at `crates/agent_servers/src/acp.rs:3340-3450`.

## The convention is Zed-proprietary, not ACP spec

The `_meta.terminal_info` / `terminal_output` / `terminal_exit` keys are
Zed extensions to ACP. The official ACP spec defines a *client-driven*
terminal model (`terminal/create`, `terminal/output`,
`terminal/wait_for_exit`) where the client runs the command — that's not
what we want, since opencode runs the command itself.

**Both reference implementations follow the same shape:**

- `@zed-industries/claude-agent-acp` (TypeScript) — batched output emission
- `zed-industries/codex-acp` (Rust) — streamed output emission

Wire shapes are identical between the two.

## Capability negotiation

Zed advertises the extension in `initialize`:

```json
"clientCapabilities": {
  "_meta": {
    "terminal_output": true,
    "terminal-auth": true
  }
}
```

**We must check for this before emitting the convention** — non-Zed ACP
clients (formulahendry/vscode-acp, gemini-cli-desktop, etc.) don't
advertise it. Both reference adapters fall back to a fenced code block
when absent.

opencode currently has the gate at `acp/agent.ts:563`:

```ts
if (params.clientCapabilities?._meta?.["terminal-auth"] === true) { ... }
```

We add a parallel check for `terminal_output` and stash it on the agent
instance. Reuse pattern.

## Wire shape — verbatim from claude-agent-acp

### A. Initial `tool_call` announce (status: pending)

```jsonc
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "...",
    "update": {
      "sessionUpdate": "tool_call",
      "toolCallId": "<bash tool callID>",
      "title": "<the actual command>",         // <-- VERBATIM command
      "kind": "execute",
      "rawInput": { "command": "...", "description": "..." },
      "status": "pending",
      "content": [
        { "type": "terminal", "terminalId": "<same as toolCallId>" }
      ],
      "_meta": {
        "terminal_info": {
          "terminal_id": "<same as toolCallId>",
          "cwd": "/abs/path"
        }
      }
    }
  }
}
```

Two crucial details:
- `terminal_id === toolCallId`. No UUIDs, no hashing. Reuse opencode's existing callID.
- `content[]` carries an in-spec `ToolCallContent::Terminal` variant. Zed pairs it with the `_meta.terminal_info` to create the display-only terminal entity.

### B. Streaming output (`tool_call_update`, status: in_progress)

```jsonc
{
  "sessionUpdate": "tool_call_update",
  "toolCallId": "<callID>",
  "_meta": {
    "terminal_output": {
      "terminal_id": "<same callID>",
      "data": "stdout chunk\n"
    }
  }
}
```

Many of these per call. opencode's bash tool already streams output
internally (see the existing `metadata.output` updates in agent.ts:432).
We just route those chunks into `terminal_output` deltas.

### C. Exit (`tool_call_update`, status: completed/failed)

```jsonc
{
  "sessionUpdate": "tool_call_update",
  "toolCallId": "<callID>",
  "status": "completed",
  "_meta": {
    "terminal_exit": {
      "terminal_id": "<same callID>",
      "exit_code": 0,
      "signal": null
    }
  }
}
```

## Where in opencode this lives

The bash tool's lifecycle in `tool/bash.ts` already emits the right
events at the right moments:

- Tool announce → currently `tool_call` (state.input = {})
- Live output → currently emitted as `metadata.output` updates
- Completion → status: completed with metadata

These all flow through `acp/agent.ts`. The fix is in agent.ts, not bash.ts:
intercept events for `kind: "execute"` tools and add the `_meta` keys
when the client advertises capability.

## Implementation outline

1. **Detect capability.** In `initialize`, store `params.clientCapabilities?._meta?.["terminal_output"] === true` as `this.terminalOutputCapable`.

2. **Patch `tool_call` emission for bash.** Where opencode currently sends the initial pending tool_call, add `_meta.terminal_info` and the `content: [{type: "terminal", terminalId}]` block when `kind === "execute"` and the capability is on. Set `title: command` (the verbatim command, replacing Fix 1's description fallback for terminal-capable clients only).

3. **Patch streaming output.** Where opencode currently emits `metadata.output` deltas during bash execution, ALSO emit a parallel `tool_call_update` with `_meta.terminal_output` carrying the new chunk. This is the streaming path codex-acp uses.

4. **Patch completion.** When the bash tool reaches `status: "completed"` or `"failed"`, append `_meta.terminal_exit` with `exit_code` and `signal`.

5. **Fallback path.** When the capability is off, keep current behavior (Fix 1's title-derivation logic still applies).

## Risks and gotchas surfaced by research

- **Encoding.** Bash output may contain non-UTF8 bytes. Codex-acp uses `String::from_utf8_lossy`. We need an equivalent in TS — `Buffer.toString("utf8")` does that lossily. Don't try to send Uint8Arrays in `data`.
- **Race per opencode #7370.** The first `tool_call` MUST carry `rawInput` populated AND `_meta.terminal_info`. opencode currently sends `rawInput: {}` in the initial announce and updates later. Our existing patches partly mitigate this; for the `_meta` fix we need to ensure both fields land in the first emission, not just the update.
- **Permission flow ordering.** The permission card renders from the tool_call message that triggered the permission ask. The terminal_info on that announce is what gives the card its expandable nature. If we emit terminal_info only on the post-approval run, the prompt card stays minimal — too late.

## Estimated effort

~2–3 hours including:
- Reading codex-acp's streaming pattern in detail (best reference for cadence).
- Writing the four patches above.
- Adding tests against captured fixtures.
- Verifying with stages 1+2 of test-the-fix.sh and a manual session.

This is significantly less than my earlier "half day" estimate because the
research surfaced a copy-able protocol with two reference implementations.
The code is well-trodden; we just port it.

## What ships when

- **Capability gate + terminal_info on announce** alone gets the rich
  permission card with command label and chevron. Most of the user's
  spec, even before output streaming.
- **Streaming output** adds the live preview during execution and the
  expanded-card output preview before approval.
- **Exit status** completes the picture — exit code visible in the card.

These could land as one PR or three. Recommend one: it's a coherent
"emit Zed terminal convention" change.

## Upstream framing

When submitting to opencode, the PR description should:
- Note the convention is Zed-proprietary (not ACP spec).
- Reference the two existing reference implementations (claude-agent-acp,
  codex-acp).
- Frame as "emit Zed-compatible `_meta` extension when client advertises
  `_meta.terminal_output`" — not "conform to ACP spec".
- Closes opencode #14034.
- Note the capability is gated; non-Zed clients see no behavioral change.

## Files we'd touch

- `packages/opencode/src/acp/agent.ts` — capability detection, `_meta`
  injection on tool_call/tool_call_update for execute kind.

That's it. One file. The bash tool itself doesn't change.
