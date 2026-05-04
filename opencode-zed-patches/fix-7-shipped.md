# Fix 7 - what shipped

Branch: `swap-confirm-card`. Built and deployed live on 2026-05-04
(build tag `0.0.0--202605041505`). Replaces fix-6 (which never
deployed — its picker-handler approach hit a runtime bug).

## What works now

- **`/models` slash command** is the canonical entry point for model
  swaps. Three forms typed in chat:
  - `/models` (bare) lists all router-known models with status,
    description, and a "⚠ not in registry" annotation when the router
    knows about a model that `primary-pool.json` doesn't.
  - `/models <id>` raises a permission card if `<id>` is unloaded;
    short-circuits with "<id> is already loaded." if it's the current
    model; emits "<id> is not in the model registry. Edit
    primary-pool.json to register it." if not registered.
  - Picker picks SHOULD emit a synthetic `/models <id>` chat message,
    but in practice this is silent. See "Known limitations" below.
- **Card layout** unchanged from the v2 design: title `current →
  target`, content blocks for description, resource lines (✓/⚠/✗
  glyphs), optional soft-block warning, optional compaction
  recommendation, trailer reminder.
- **Allow** spawns `model-swap.sh --execute <id>` and streams stdout/
  stderr into a foldable terminal block in chat (same plumbing as
  the bash tool). On success, `sessionManager.setModel` commits the
  forward state change. On failure, reverts to previous.
- **Deny** reverts the picker to the previous model and emits a
  `Cancelled — staying on <previous>.` message.
- **Anny's path** is the same handler. Her `model-swap-remote.sh`
  forwards `--list`/`--preflight`/`--execute` flags to the underlying
  `model-swap.sh`, so the slash-command handler works uniformly for
  both users.

## Why this design (over v2)

v2 split the swap flow across the picker handler
(`unstable_setSessionModel`) and the on-message check
(`session/prompt.ts`) because `permission.ask` is only available
inside session-scoped Effect generators, and the picker is an RPC
handler outside that scope. v2 stashed preflight state on a
module-level Map and read it in the prompt loop.

In live testing (2026-05-04 morning), the on-message check didn't
find the stashed entry and the v1-fallback `else if (swapScript)`
branch fired instead, producing the legacy yad popup. The exact bug
was never diagnosed because the architectural split was the
underlying issue.

v3 collapses the design: the `/models` slash command runs in the
slash-command dispatch (`switch (cmd.name)` in `acp/agent.ts`), which
is inside the prompt loop's session scope. Everything happens in one
handler with `this.connection`, `this.sessionManager`, and `this.sdk`
all in scope. No cross-package state. The picker just emits a
synthetic chat message that hits the same handler.

## Two-step slash command registration

Adding a built-in slash command to opencode requires TWO edits in
`packages/opencode/src/acp/agent.ts`:

1. **Register the name in `availableCommands`** (around line 1615,
   alongside the existing `compact` registration). Without this,
   opencode's slash-command parser produces:

       The /<name> command is not supported by opencode.

   v3's first build had only the switch case and rejected `/models`
   for exactly this reason; the registration was added at commit
   `2c03414`.

2. **Add the dispatch case** in the `switch (cmd.name)` block
   (around line 2044). This is where the actual handler logic goes.

The `if (!names.has(...))` check on the registration lets a
user-defined MCP-prompt command of the same name take precedence —
only register the built-in if the registry doesn't already have one.

## How the picker integrates without Zed changes

`unstable_setSessionModel` calls `this.prompt({...})` (NOT
`this.sdk.session.prompt({...})`) with `parts: [{ type: "text", text:
"/models <id>", annotations: { audience: ["assistant"] } }]`. The
`audience: ["assistant"]` translates to `synthetic: true` on the part
at `this.prompt`'s entry point (around line 1707), which keeps the
part out of LLM context. The slash-command parser detects the
`/models` prefix and routes to the handler.

Crucially, the picker handler does NOT call `sessionManager.setModel`.
The forward commit happens once, after Allow + load success, inside
the slash-command handler. On Deny or load failure,
`sessionManager.setModel(previous)` runs to revert Zed's local picker
UI (which had updated client-side at pick time).

## Anny's path

Anny's launcher hardcodes `OPENCODE_MODEL_SWAP_SCRIPT` to
`scripts/model-swap-remote.sh`. v3 unconditionally calls `--preflight`
and `--list` on whatever script is configured. To make anny work with
v3, `model-swap-remote.sh` was updated (commit `af9787c`) to forward
all flag-mode args to `model-swap.sh`. This is the Stage 2 cutover
that the v2 spec said could be deferred — but v3's design forced it
to ship together.

Net for anny: she gets the new card UX too. No more silent
fire-and-forget.

## Verifying the fix

1. Open Zed in the 2GPU isolated profile.
2. Type `/models` — see the listing with status + descriptions.
3. Type `/models <currently-loaded>` — see "<id> is already loaded."
4. Type `/models <unloaded>` — see the card. Click Reject — see cancel
   message; picker eventually reverts.
5. Re-type `/models <unloaded>` — see card again. Click Allow once —
   see the terminal block stream `[swap]` lines through to `✓ loaded`.

All five paths verified in build `0.0.0--202605041505`. Plus the
bonus path `/models <not-in-registry>` returning the registry
guidance message.

## Known limitations

### Zed picker label stale after swap

After a `/models` swap completes, Zed's footer dropdown still shows
the OLD model name. The chat itself routes to the new model
correctly (router is single-endpoint), and the context-window tooltip
updates correctly (the `usage_update` ACP notification carries
`size`). Only the picker label is wrong.

Cause: ACP exposes `configOptions` with `currentModelId` only in
**RPC responses** (e.g. `setSessionConfigOption`) — never via
push notification. opencode-patched calls `sessionManager.setModel`
internally but has no message type to push the change back to Zed.

Workaround: re-pick from the dropdown to refresh the label. The
slash-command handler short-circuits with "already loaded" (no
actual swap fires) and the picker UI snaps to match.

### Picker pick is silent

Selecting a different model in Zed's footer dropdown produces
nothing — no chat message, no card, no swap. The synthetic-prompt
dispatch via `this.prompt({...})` apparently isn't reaching the
slash-command handler. Possible causes (not diagnosed):

- `this.prompt()` doesn't go through the slash-command parser the
  way the typed-`/models` path does.
- The `audience: ["assistant"]` → `synthetic: true` translation isn't
  firing, so the part is filtered as already-handled.
- The async lifecycle drops the promise before dispatch.

Workaround: type `/models <id>` instead. All four typed paths work
fully.

Investigation deferred to a future fix-8.

### Cancellation mid-load

If the user aborts the agent thread mid-`--execute`, the spawned
child isn't killed — same shape as the bash tool's existing
limitation. Fix path: wrap the spawn in `Effect.acquireRelease` with
`child.kill('SIGTERM')` in the release callback. Mirror the bash
tool's eventual fix here. Out of scope for this patch (TODO comment
preserved in the diff).

## What this does NOT change

- The bash data layer (`--preflight`, `--execute`, `--list`) — same
  scripts, same JSON shape.
- The `swap` permission card renderer — lifted verbatim from v2.
- The model-swap script's bare-invocation yad path — still works for
  terminal use during incidents. Removed in Stage 3 (deferred).

## Files changed

This patch:
- `opencode-zed-patches/our-patch-router-swap-v3.diff` (new, 501 lines)
- `opencode-zed-patches/test-router-swap-v3.sh` (new)
- `opencode-zed-patches/install-and-wire.md` (apply order)
- `opencode-zed-patches/README.md` (patch table)
- `opencode-zed-patches/fix-7-shipped.md` (this file)

Co-shipped Stage 2:
- `scripts/model-swap.sh` (added `--list` mode)
- `scripts/model-swap-remote.sh` (forward flag-mode args)
- `tests/model-swap-modes/test_list.sh` (new)
