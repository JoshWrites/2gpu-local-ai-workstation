# Fix 3 - what shipped

Branch: `rules-refinement`. Built 2026-05-01 (build tag
`0.0.0--202605011943`).

## What works now

- **Permission card shows the file path for write/edit/read.** Before
  approval, the user sees `write /home/levine/.../foo.py` instead of
  bare `write`. No more guessing what file the model is about to
  touch when GLM omits the optional `description` field in tool
  arguments.
- **The fallback chain is consistent across both code paths.** Both
  `requestPermission` (the pre-approval modal) and `deriveTitle`
  (the in-progress / completed tool card) go through the same
  description -> command -> path -> bare-name precedence.

## The bug, in one sentence

When GLM-4.7-Flash emits a `write`/`edit`/`read` call without the
optional `description` argument, the patched ACP layer's title
resolver fell through to bare `part.tool` ("write"), giving the user
a permission card with no indication of what file was about to be
written.

## How it surfaced

Sampler tuning on `llama-primary` (temp 0.7, top-p 1.0, min-p 0.01)
shifted GLM toward more deterministic, terser tool calls -
specifically, GLM started skipping the optional `description` field
more often. The bug had always been there; the sampler change made
it visible. `bash` was unaffected because the execute-kind path uses
the verbatim `command` argument as its title.

## The fix, in one sentence

Add a path-based fallback (`filePath`, then `path`, then
`file_path`) to both title resolvers; if the model gave us a path,
the card shows `<tool> <path>`.

## Where the fallback lives

Two functions in `packages/opencode/src/acp/agent.ts`:

1. `requestPermission` IIFE (the pre-approval modal title). Order:
   - execute + command -> command (+ description on line 2 if present)
   - description (any tool)
   - command (any tool)
   - filePath / path / file_path (any tool) -> `<tool> <path>`
   - bare `permission.permission`
2. `deriveTitle` (in-progress / completed card titles). Same order
   for symmetry.

The two lookups intentionally accept three field-name variants:

- `filePath` - opencode's built-in `write`, `edit`, `read` schemas.
- `path` - common in MCP tool conventions.
- `file_path` - snake_case alternative used by some MCP servers.

## What this does NOT change

- Bash tool behavior. `bash` was already correct - the execute-kind
  branch reads `command` directly, which is required by the schema.
- Tools with no path and no description (e.g. tools that take only a
  search query). These still fall through to bare tool name.
- Stock opencode. The patch only touches the ACP layer's title
  derivation; everything else is upstream behavior.

## Verifying the fix

1. Open Zed in the isolated Second Opinion profile.
2. Ask GLM to write or edit a file.
3. Confirm the permission card title shows the file path, not the
   bare tool name.
4. Confirm bash calls still show the verbatim command (regression
   guard for fix 2).
