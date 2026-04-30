# The fix - what we changed and why

This is the human-readable companion to the patch. Anyone (including future-us) should be able to read this and understand the change without re-deriving it from the diff.

## The bug, in one sentence

When opencode's ACP layer asks the connected client (Zed) for permission to run a tool, it sends `rawInput: permission.metadata` - but the bash tool calls the permission system with `metadata: {}`, so Zed receives a permission request with no command to display, has no way to render an approval prompt, and silently denies.

## The fix, in one sentence

Before sending the permission request to Zed, look up the actual tool input from the message store using `(messageID, callID)` and use that as `rawInput` instead of the empty metadata.

## Where the change lives

Single file: `packages/opencode/src/acp/agent.ts`, in the `permission.asked` case of `handleEvent` (around line 200 in v1.14.28).

## What the change looks like

Inserted before the `requestPermission` call:

```ts
const toolInput = await (async () => {
  if (!permission.tool) return permission.metadata
  const message = await this.sdk.session
    .message(
      {
        sessionID: permission.sessionID,
        messageID: permission.tool.messageID,
        directory,
      },
      { throwOnError: true },
    )
    .then((x) => x.data)
    .catch(() => undefined)
  if (!message) return permission.metadata
  const part = message.parts.find((p) => p.type === "tool" && p.callID === permission.tool!.callID)
  if (!part || part.type !== "tool") return permission.metadata
  return part.state.input
})()
```

Then in the `requestPermission` call, the two fields that previously read `permission.metadata` now read `toolInput`:

```diff
-                  rawInput: permission.metadata,
+                  rawInput: toolInput,
                   kind: toToolKind(permission.permission),
-                  locations: toLocations(permission.permission, permission.metadata),
+                  locations: toLocations(permission.permission, toolInput),
```

## Why this is safe

Four nested fallbacks make this a no-op when anything goes wrong:

1. If the permission has no `tool` reference (`permission.tool` is undefined) -> use `permission.metadata` (current behavior).
2. If the SDK call fails to fetch the message -> use `permission.metadata`.
3. If the fetched message has no parts at all -> use `permission.metadata`.
4. If no part with the matching `callID` exists, or it's not a tool part -> use `permission.metadata`.

Only when all four checks pass do we substitute `part.state.input` for the empty metadata. So in the worst case, behavior matches today's broken state - never worse.

## Why we didn't fix it in `tool/bash.ts` instead

The `bash.ts` fix would be one line - populate `metadata: { command: params.command, description: params.description }` instead of `metadata: {}`. We considered this (Path C in the decision log).

We chose the ACP-layer fix instead because:

- **Tool-agnostic.** The same metadata-empty pattern could occur in MCP tools or future built-in tools. The ACP-layer fix catches all of them.
- **Doesn't depend on tool author discipline.** Tools no longer need to remember to populate metadata for the prompt UI to work - the ACP layer always provides real input.
- **Fits a class of bugs, not just one tool.** If the bash tool ever stops being the only one with this issue, this fix is already in the right place.

The tradeoff: one extra SDK round-trip per permission request (local HTTP, sub-millisecond). Negligible compared to the human approval click that follows.

## Verification

- **Typecheck:** `bun run typecheck` passes cleanly across all 13 workspace packages on the patched tree.
- **Targeted typecheck:** `bun run typecheck` inside `packages/opencode` passes with no output.
- **Build:** see `decision-log.md` for the build status and any complications.
- **End-to-end:** test plan documented in `e2e-test-plan.md` once the build is in hand.

## Provenance

This is the same logic as PR #7374, ported forward from `v1.14.x` (where the patch was authored, January 2026) to `v1.14.28` (the build target). The structural changes between those versions:

- The permission handler moved into a `handleEvent` switch statement.
- `directory` is now defined inside the `.then` block rather than at the top of the case.
- `this.sdk` is now accessed directly (was `this.config.sdk` in old code).

The transformation logic itself - fetch message, find part by callID, use `part.state.input` - is unchanged.

## Files touched

- `packages/opencode/src/acp/agent.ts` - the fix itself, ~20 lines added, 2 lines modified.

That's it. Single file, single function, surgical change.
