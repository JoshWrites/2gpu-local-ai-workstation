# Fix 1 -- replace `title: "bash"` with the description

## What the bug was

Even after our patches in `agent.ts` (state.input lookup) and `tool/bash.ts`
(populate metadata), Zed's permission card still rendered as just "bash".

Reading Zed's source -- `crates/agent_ui/src/conversation_view/thread_view.rs`
-- revealed why. The card label is whatever `requestPermission`'s
`toolCall.title` says. opencode was sending `title: permission.permission`
(line 208 of `agent.ts`), which is the literal permission *type*. For bash
calls, that's the string `"bash"` -- and that's what Zed dutifully displayed.

For a non-permission tool call, opencode sends the description as `title`
(see `tool/bash.ts:432` and elsewhere). Permission-asking takes a different
path that hadn't been updated.

## The fix

In `acp/agent.ts`, derive a useful prompt title from the populated tool
input (which our earlier patches now ensure is non-empty for bash):

```ts
const promptTitle = (() => {
  const md = (toolInput ?? {}) as Record<string, unknown>
  const desc = typeof md["description"] === "string" ? (md["description"] as string) : undefined
  const cmd = typeof md["command"] === "string" ? (md["command"] as string) : undefined
  return desc || cmd || permission.permission
})()
```

Then use it where `title` was set:

```diff
-                  title: permission.permission,
+                  title: promptTitle,
```

Preference order:
1. The LLM-generated description (best -- human-readable: "Check git status").
2. The literal command (fallback for tools that didn't generate a description).
3. The permission type ("bash") -- only as a last resort if nothing else.

## What this gives you

Permission card header now displays a one-line, informed-consent-grade
label instead of `"bash"`. For a `git status` call: "Check git status for
uncommitted changes." For arbitrary commands without a good description,
falls back to the command itself.

## What this does NOT give you

- Multi-line previews
- Verbatim command alongside the description
- Expandable detail
- Streaming output before approval

For execute-kind tools (bash), Zed's UI explicitly **does not** show its
"View Raw Input" expander. See `thread_view.rs:6334`:

```rust
let should_show_raw_input = !is_terminal_tool && !is_edit && !has_image_content;
```

The path to the rich expandable card the user spec'd ("2 lines verbatim
command + 1 line description, expandable to full output") is Zed's
`_meta` terminal convention -- `terminal_info`/`terminal_output`/
`terminal_exit` keys decoded at `crates/agent_servers/src/acp.rs:3340-3450`.
That's Fix 2, planned next.

## Files touched

- `packages/opencode/src/acp/agent.ts` -- the title derivation block
  (8 lines added, 1 line modified).

Combined diff against v1.14.28 across all three patches now totals 94 lines:
- `our-patch-agent.diff` -- 50 lines (state.input lookup + title fix)
- `our-patch-bash.diff` -- 44 lines (helper signature + metadata population)

## Verification

Manual: in Zed (Second Opinion), trigger a bash permission prompt. Card
should display the description string instead of "bash".

Headless smoke (Stages 1+2 of test-the-fix.sh): pass.

Stage 3 (the real test): user verification in Zed.
