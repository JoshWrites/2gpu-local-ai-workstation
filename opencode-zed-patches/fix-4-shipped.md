# Fix 4 - what shipped

Branch: `rules-refinement`. Built 2026-05-01 (build tag
`0.0.0--202605012010`). Supersedes the partial fix in
`fix-3-shipped.md`; both are part of the same investigation.

## What works now

- **Permission card for `write` and `edit` shows two distinct rows**,
  mirroring bash: `<tool> <path>` as the title, and the model-supplied
  description as a separate content block visible below. The card now
  answers both "what file" and "why" before the user clicks approve.
- **The description is mandatory.** Patched `write` and `edit` schemas
  declare `description` as a required field. llama.cpp's
  grammar-constrained sampling under `--jinja` enforces required
  fields at sample time - the model literally cannot emit a tool call
  without one. Where fix 3 was a graceful fallback for a missing
  field, fix 4 makes the field always present.

## How the description reaches the card

Initial attempt embedded the description in the title with `\n`,
mirroring the bash format. That worked for bash because bash gets a
separate visual treatment via `_meta.terminal_info` that honors
newlines. For non-execute tools, Zed's permission-card title
flattens `\n` to a space, so the description ran into the title
inline.

The actual ACP-shaped fix is to send the description as a separate
`content` block: `{ type: "content", content: { type: "text", text:
description } }`. Zed renders content blocks below the title as
distinct rows. The patch defines `deriveContentExtras(part)` for
this, called everywhere a tool_call/tool_call_update is emitted -
the approval prompt, the in-progress and completed updates, the
failed update, and both replay paths.

## Why fix 3 alone was not enough

Fix 3 added a path-based fallback so `write`/`edit` cards stopped
reading "write" and instead read "write /home/.../foo.py". That was
better but still showed only the path, not what the model intended
to do. Real-world UX gap: "edit /home/.../config.py" is more
informative than "edit" alone, but you still cannot tell whether the
agent is fixing a typo, refactoring a function, or rewriting the
whole file.

The right fix is the same one bash already had: declare a required
`description` parameter in the schema. Once required, the constrained
sampler will not let the model skip it, so the approval card always
has both fields available.

## How it surfaced

GLM sampler tuning (fix 3 era: temp 0.7, top-p 1.0, min-p 0.01) made
GLM emit terser tool calls and skip optional fields more often. Fix 3
let the card fall back to path-only. The user observed this and
asked for path + description always - which forced the actual fix:
schema-level enforcement.

## What changed

Three files, all in `our-patch-tools.diff`:

1. `packages/opencode/src/tool/write.ts` -
   `Parameters.description: Schema.String.annotate(...)` added with
   guidance text similar to bash's. Execute signature updated to
   accept the new field (the `execute` body does not use it; the
   value flows through to the title resolver in agent.ts via the
   message store).
2. `packages/opencode/src/tool/edit.ts` - same addition. Edit's
   execute signature uses `Schema.Schema.Type<typeof Parameters>`
   and updates automatically.
3. Test fixtures in `packages/opencode/test/tool/write.test.ts`,
   `edit.test.ts`, and `parameters.test.ts` - every call site of
   the two tools' schemas now passes a stub `description`. Added
   "rejects missing description" test cases for both schemas.

The `agent.ts` title resolvers (`promptTitle` and `deriveTitle`)
were updated to render the file-tool case symmetrically with the
execute case: `<tool> <path>\n<description>` when both are present,
gracefully degrading to single-line variants when one is missing.

## What this does NOT change

- Stock opencode upstream. This is a fork divergence we already
  accepted with the agent.ts and bash.ts patches; this just
  completes the schema half. Upstream reconciliation would mean
  rebasing this patch onto whatever version of the schemas
  opencode ships next.
- The `read` tool. Read calls do not produce permission prompts
  (read is auto-allowed in this stack), so the card-title problem
  does not apply to read. Adding a required description field
  would impose ongoing token cost on every read call for no UX
  benefit, so we deliberately skip it.
- MCP tools. Third-party MCP servers can decide for themselves
  whether to declare a `description` field. The agent.ts resolver
  still accepts `description` from any tool input, so MCP tools
  that opt in benefit; tools that do not still get the
  `<tool> <path>` fallback from fix 3.

## Verifying the fix

1. Open Zed in the isolated Second Opinion profile.
2. Ask GLM to write or edit a file.
3. Confirm the permission card title shows two lines: the tool +
   path on line 1, a 5-10 word description on line 2.
4. Confirm bash calls still show command + description (regression
   guard for fix 2).
5. Optional: try to manually craft a `write` call without a
   `description` field via the SDK. The schema parse should reject
   it. (`bun test test/tool/parameters.test.ts` exercises this.)

## Upstream concern

Adding a required schema field to a tool is a real divergence from
stock opencode's behavior. A non-patched client calling the patched
opencode with a write call lacking `description` will see a schema
validation failure. This is acceptable in this stack because
opencode is the only client and llama-server with the tool
definitions baked in via `--jinja` will always emit the field.
Anyone re-using these patches with a different client should weigh
this constraint.
