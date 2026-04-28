# The race condition we found in production

After applying our `acp/agent.ts` fix and testing in Zed, the permission
prompt **did** appear (so the patch wasn't a total wash), but the bash
box still showed only "bash" with no command. Log inspection revealed why.

## The exact timeline

For a `git status` call, opencode's bash tool flow:

```
T+0ms     create tool part: state.input = {} (placeholder)
T+286ms   permission system evaluates patterns, fires `permission.asked`
T+0ms     OUR PATCH RUNS in agent.ts:
            sdk.session.message(...) → fetches part by callID
            part.state.input is still {} ← the input field hasn't been
                                           populated yet
            → fall back to permission.metadata, which is also {}
            → requestPermission sent to Zed with rawInput = {}
T+4ms     bash tool finally calls part.update with state.input =
            { command: "git status", description: "..." }
            (too late — the permission request is already on the wire)
```

So our `agent.ts` fix is **looking up `part.state.input` before it's
populated** for tools that ask for permission *before* setting their input.
At least bash does this, and likely others.

## Why the upstream PR #7374 looked like it worked

The "user confirmed it works" comment on PR #7374 didn't specify which
tool. Edit-class tools populate metadata directly in their `ctx.ask` calls
(see `tool/edit.ts:101`: `metadata: { filepath, diff, ... }`). For those,
the rawInput=metadata fallback already gave Zed something useful, and the
PR's lookup was redundant but didn't hurt.

For bash, the metadata is `{}` and the part input is also empty at ask
time. No path to a populated rawInput.

## The fix that works

Two layers:

1. **Keep the agent.ts fix** — it does the right thing for tools whose
   `state.input` IS populated before `ctx.ask`. We don't have to revert.
2. **Also patch tool/bash.ts** to populate `metadata: { command, description }`
   directly. Then `permission.metadata` arrives at the ACP layer non-empty,
   and our agent.ts fallback (`return permission.metadata` when the part
   lookup fails) becomes a clean fallback rather than a dead end.

Both patches together = bash works. agent.ts fix alone = race loses, prompt
shows empty box. bash.ts fix alone = bash works but generic fix for other
tools doesn't exist.

## Implications for upstream

The upstream PR for opencode should be **two changes**:
- The agent.ts logic (more or less PR #7374, but keeping the metadata
  fallback as the primary path, with `state.input` lookup as
  enhancement-for-future).
- Population of `metadata` in `tool/bash.ts` (and ideally a survey of
  other tools that might pass `metadata: {}`).

A reviewer looking at PR #7374 alone might have closed it precisely
because the fix-via-state-lookup approach is racy. Worth mentioning when
re-submitting.

## Patches preserved

- `our-patch-agent.diff` — the agent.ts change (42 lines)
- `our-patch-bash.diff` — the bash.ts change (44 lines including helper signature update)

Total upstream contribution candidate: 86 lines across two files.
