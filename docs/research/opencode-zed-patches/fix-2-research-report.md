# Background research report -- `_meta` terminal synthesis precedent

Verbatim record of the research subagent's report, run 2026-04-28.
Preserved here so the Fix 2 plan has its source of record.

---

## TL;DR

The `_meta.terminal_info` / `terminal_output` / `terminal_exit` shape is
**a Zed-specific extension, not in the official ACP spec**. The official
ACP spec defines a *client-driven* terminal model (`terminal/create`,
`terminal/output`, `terminal/wait_for_exit`) where Zed runs the command.
The `_meta` convention is the alternate path for agents that run commands
themselves and want Zed to render a "display-only" terminal of the streamed
bytes. **Two reference implementations exist**: `@zed-industries/claude-agent-acp`
(TypeScript) and `zed-industries/codex-acp` (Rust). Their wire shapes are
identical and you should follow them verbatim.

## 1. Capability negotiation (do this first)

Zed advertises support during `initialize` (Zed `crates/agent_servers/src/acp.rs:820-830`):

```rust
.meta(acp::Meta::from_iter([
    ("terminal_output".into(), true.into()),
    ("terminal-auth".into(), true.into()),
])),
```

Both reference agents gate the `_meta` emission on this capability.
- Claude Code: `clientCapabilities?._meta?.["terminal_output"] === true` (`acp-agent.js:1377`, also `:699`).
- Codex-acp: `client_capabilities.meta.get("terminal_output").as_bool()` (`thread.rs:2462-2473`).

If absent, both fall back to a fenced code block. **Implement the fallback**
-- non-Zed ACP clients (formulahendry/vscode-acp, gemini-cli-desktop,
obsidian-agent-client) do not advertise this meta key.

## 2. Wire shape -- verbatim from claude-agent-acp 0.23.1

### A. Announce (`tool_call`, status `pending`) -- `acp-agent.js:1503-1517`:

```js
update = {
  _meta: {
    claudeCode: { toolName: chunk.name },
    ...(chunk.name === "Bash" && supportsTerminalOutput
      ? { terminal_info: { terminal_id: chunk.id } } : {}),
  },
  toolCallId: chunk.id,
  sessionUpdate: "tool_call",
  rawInput,
  status: "pending",
  ...toolInfoFromToolUse(chunk, supportsTerminalOutput, options?.cwd),
};
```

`toolInfoFromToolUse` for Bash returns `title: input.command`,
`kind: "execute"`, `content: [{ type: "terminal", terminalId: toolUse.id }]`
(`tools.js:36-50`). That `content` block of `type: "terminal"` is the
in-spec ACP `ToolCallContent::Terminal` variant -- Zed sees it and the
`_meta.terminal_info` together and creates the display-only terminal
entity (Zed `acp.rs:3349-3385`).

### B. Output (`tool_call_update`)

Claude Code sends it as a *separate* notification before the completion
update (`acp-agent.js:1542-1556`):

```js
output.push({ sessionId, update: {
  _meta: { terminal_output: toolMeta.terminal_output },
  toolCallId: chunk.tool_use_id,
  sessionUpdate: "tool_call_update",
}});
```

The shape is `{ terminal_id, data: <string> }` (`tools.js:349-352`).

### C. Exit (`tool_call_update`, status `completed`/`failed`) -- `acp-agent.js:1557-1569`, `tools.js:353-358`:

```js
_meta: { terminal_exit: { terminal_id, exit_code, signal: null } }
```

## 3. Codex-acp emits the same shape

`codex-acp/thread.rs:1870-1894` (announce), `:1911-1922` (output),
`:1981-1992` (exit). Identical key names and nesting. Codex-acp
additionally puts `cwd` inside `terminal_info`:
`{"terminal_id": call_id, "cwd": cwd}`. Zed reads this on `acp.rs:3354-3356`.
Claude Code does **not** send `cwd` and Zed handles `None` fine.

## 4. terminal_id generation: just reuse the tool-call id

Both impls use the existing tool-call id verbatim:
- Claude Code uses Anthropic's `chunk.id` (`acp-agent.js:1509`).
- Codex-acp uses Codex's `call_id`.

**No UUIDs, no hashing.** This implies a 1:1 binding between tool call and
terminal -- Zed treats them as the same identity. For opencode, use the
bash tool-call id you already emit.

## 5. Streaming vs. batched

- Claude Code is **batched, not streamed** -- it emits `terminal_output`
  once with the full captured stdout+stderr after the tool result arrives
  (`tools.js:330` joins them).
- Codex-acp **streams chunk-by-chunk** via `ExecCommandOutputDeltaEvent`
  (`thread.rs:1897-1944`), sending many `tool_call_update` notifications
  with appended `data`.

Zed's decoder appends each one (Zed `acp.rs:3406-3411` calls
`TerminalProviderEvent::Output { data }`). **Streaming works and is
preferred** for the live-output UX in your spec -- opencode already has
streaming bash output internally, just route it through `terminal_output`
deltas.

## 6. Spec status -- Zed-proprietary

Searches of `agentclientprotocol/agent-client-protocol`: zero hits for
`terminal_info`. The spec's `docs/protocol/terminals.mdx` describes only
the client-driven `terminal/*` RPCs. The `_meta` extension is undocumented
outside Zed source. Your opencode PR should be framed as *"emit
Zed-compatible `_meta` extension when client advertises
`_meta.terminal_output`"*, not *"conform to ACP spec"*.

## 7. Failure modes from the trackers

- **anomalyco/opencode#14034** -- exact issue you're fixing. Confirms the
  title currently shows `description` not `command`. Set
  `title: input.command` (matches `tools.js:38`).
- **anomalyco/opencode#7370** -- `rawInput` gets cleared on permission
  requests: opencode sends `tool_call` with `rawInput: {}` then
  `tool_call_update` with the real input. Zed's permission card reads
  from the first emission. Make sure `rawInput` and `terminal_info` are
  both populated on the **first** `tool_call`.
- No "encoding" gotchas in trackers, but codex-acp uses
  `String::from_utf8_lossy` (`thread.rs:1909`) -- Zed expects `data` as a
  JSON string, so non-UTF8 bytes must be lossy-decoded before emission.
- No race-condition reports. Zed's pre-handler creates the terminal
  *before* forwarding the update (Zed `acp.rs:3348-3398`), so
  `terminal_output` arriving in the same tick as `terminal_info` is safe.

## Recommendation

Follow Claude Code's pattern verbatim for shape, codex-acp's pattern for
streaming cadence. Ship a single `tool_call` (with `_meta.terminal_info`,
`content: [{type:"terminal", terminalId}]`, `kind:"execute"`,
`title: command`, `rawInput: {command, description}`), N `tool_call_update`s
with `_meta.terminal_output` deltas, and one final `tool_call_update` with
`_meta.terminal_exit` plus terminal status. Gate everything on
`clientCapabilities._meta.terminal_output === true` and keep the
markdown-fenced fallback for other clients.

## Key file references

- claude-agent-acp `tools.js` (lines 36-50, 315-376) and `acp-agent.js` (lines 699, 1377, 1500-1569)
- codex-acp `thread.rs` (lines 1860-1995, 2462-2473)
- Zed `crates/agent_servers/src/acp.rs` (lines 820-830 capability advertisement, 3340-3450 decoder)
