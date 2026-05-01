# Source-walk findings -- opencode 1.14.25 ACP layer

Done by sparse-cloning `anomalyco/opencode` and reading the relevant files directly. Date: 2026-04-28.

## File map

```
packages/opencode/src/
├── acp/
│   ├── agent.ts       # 1838 lines -- main ACP message handler
│   ├── session.ts     # 116 lines -- session manager
│   └── types.ts       # 24 lines -- small type defs
├── cli/cmd/
│   └── acp.ts         # 70 lines -- the `opencode acp` entrypoint
├── tool/
│   ├── bash.ts        # the smoking gun
│   ├── edit.ts, write.ts, ...  # other tools that ask for permission
│   └── ...
└── permission/
    ├── arity.ts, evaluate.ts, index.ts, schema.ts
```

## Permission flow, end to end

1. **Tool decides it needs permission.** `tool/bash.ts:258-279` -- the bash tool has an `ask()` helper that calls `ctx.ask({ permission, patterns, always, metadata })`. The metadata field is what eventually becomes `rawInput` in Zed's UI.

2. **`bash.ts` passes empty metadata.** Lines 264-269 (external_directory) and 273-278 (bash):
   ```ts
   yield* ctx.ask({
     permission: "bash",
     patterns: Array.from(scan.patterns),
     always: Array.from(scan.always),
     metadata: {},   // <-- the bug
   })
   ```
   `params.command` and `params.description` are in scope at the caller (line 602: `yield* ask(ctx, scan)` -- `params` is closed over) but are not passed in.

3. **The permission system emits a `permission.asked` event.** Code path goes through `permission/index.ts` -> SDK event bus.

4. **ACP layer picks up the event.** `acp/agent.ts:190-250` -- `handleEvent` switches on `event.type` and for `permission.asked` it builds an ACP `requestPermission` RPC:
   ```ts
   const res = await this.connection.requestPermission({
     sessionId: permission.sessionID,
     toolCall: {
       toolCallId: permission.tool?.callID ?? permission.id,
       status: "pending",
       title: permission.permission,
       rawInput: permission.metadata,    // <-- the empty {} arrives here
       kind: toToolKind(permission.permission),
       locations: toLocations(permission.permission, permission.metadata),
     },
     options: this.permissionOptions,
   })
   ```

5. **Zed receives `requestPermission` with empty `toolCall.rawInput`.** Zed's UI has `title: "bash"` and `kind: "execute"` but no command text. Per the maintainer's note on Zed#53249, Zed considers this opencode's job to fix and silently denies / fails to display.

## Why edit prompts may work but bash doesn't

Looking at `acp/agent.ts:239-249`, the **post-approval** logic for edits reads `permission.metadata.filepath` and `permission.metadata.diff`. So opencode's edit tool DOES populate metadata (probably in `tool/edit.ts`). That's why edit prompts have content while bash prompts don't.

The simplest fix -- populating `metadata: { command, description }` in `tool/bash.ts` -- would also work, but PR #7374 took a more general approach: ignore `permission.metadata` entirely for `rawInput` and instead look up the actual tool input from `part.state.input` by `(messageID, callID)`. That's tool-agnostic and right.

## Tool-call lifecycle on the wire

From `acp/agent.ts:1116-1135` and surrounding:

1. `sessionUpdate { sessionUpdate: "tool_call", toolCallId, title, kind, status: "pending", locations: [], rawInput: {} }` -- initial announce, **rawInput intentionally empty here.**
2. `sessionUpdate { sessionUpdate: "tool_call_update", toolCallId, status: "...", rawInput: part.state.input }` -- multiple updates with the **actual** input.
3. (If permission needed) `requestPermission { toolCall: { toolCallId, rawInput: {} } }` -- **empty again, the bug.**
4. After approval/rejection: more `tool_call_update` messages with status changes.

So the shim's job is unambiguous:
- Watch every `tool_call_update` message; cache `rawInput` keyed by `toolCallId` whenever it's non-empty.
- Intercept every `requestPermission` message; if `toolCall.rawInput` is empty and `toolCall.toolCallId` is in the cache, splice the cached value in.
- Pass everything else through.

This is genuinely a small piece of code.

## Transport: stdio only

`cli/cmd/acp.ts` builds the ACP connection from `process.stdin` and `process.stdout` via `ndJsonStream` from `@agentclientprotocol/sdk`:

```ts
const input  = new WritableStream<Uint8Array>({ write(chunk) { process.stdout.write(chunk, ...) } })
const output = new ReadableStream<Uint8Array>({ start(controller) { process.stdin.on("data", ...) } })
const stream = ndJsonStream(input, output)
new AgentSideConnection((conn) => agent.create(conn, { sdk }), stream)
```

There is **no flag** for TCP or socket transport -- the stdio binding is hardcoded.

But note line 26: `const server = await Server.listen(opts)` and lines 28-30: it creates an SDK client pointed at that local HTTP server. So opencode's own architecture is: HTTP server inside, stdio JSON-RPC adapter on top. The HTTP server is what `withNetworkOptions(yargs)` exposes (`--hostname`, `--port` flags presumably). That's already network-capable.

**For the shim's remote-serving phase:** the shim itself becomes the network boundary. Either via SSH (cheap, matches `work-opencode`'s existing pattern) or via a TCP listener mode in the shim itself. SSH first is the right call.

## On `_meta` terminal cards (Zed#53249's actual root cause for the empty UI)

Searched `acp/agent.ts` for `_meta` and `terminal_info` -- only one hit: line 544 `params.clientCapabilities?._meta?.["terminal-auth"]` for auth flow.

opencode's ACP layer **never** emits `terminal_info`/`terminal_output`/`terminal_exit` `_meta` events. So Zed's rich terminal card UI never lights up regardless of approval. This is the polish item -- separate from the rawInput bug, but related (same architectural lag in opencode's ACP adapter).

For Phase 1.5, the shim could synthesize these by watching `tool_call` events with `kind: "execute"` and the corresponding tool result text. Not tonight's problem.

## Summary

The shim is a 30-line transform problem (plus framing/process plumbing). Source confirms the strategy is correct and minimal. Upstream fix is small and uncontroversial -- PR #7374's diff is preserved here for reference and re-submission.
