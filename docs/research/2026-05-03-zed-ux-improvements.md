# Zed UX improvements via opencode patches

**Date:** 2026-05-03
**Audience:** future-us evaluating which of these to take upstream;
opencode and Zed maintainers reading the cover letter for an
upstream PR.

This document describes the **user-facing improvements to the Zed
agent panel** produced by a small set of patches to opencode. Zed is
the surface a user touches; opencode is the agent server it talks to
over ACP. Some of the fixes are pure-opencode; others would benefit
from a complementary Zed-side change. Where the cleanest upstream
home is opencode, this doc names that. Where Zed is the better venue,
this doc says so.

The five patches live in
[`opencode-zed-patches/`](../../opencode-zed-patches/) at the repo
root. They are applied to a local fork installed at
`/usr/local/bin/opencode-patched`. None has been submitted upstream
as of this writing.

---

## Patch 1: tool-call permission cards show what's actually happening

**File:** `opencode-zed-patches/our-patch-agent.diff`
**Touches:** `packages/opencode/src/acp/agent.ts`

### The Zed pain

Stock opencode in Zed pops a permission card before any tool runs.
For `bash`, the card was an empty box -- no command shown. For
`write` / `edit`, the card was a bare tool name with no path. The
user had to approve "do something" with no idea what.

The proximate cause: opencode sends the permission request before
looking up the actual tool input. The richer info exists -- the
input has been stored in the message -- but the ACP
`session/request_permission` payload was a thin shell with just the
tool id.

### The patch

`agent.ts` resolves the request title from the message store. It
extracts the verbatim subject -- the command for `bash`, `<tool>
<path>` for write/edit -- and uses it as line 1 of the card title.
Line 2 is the model-supplied `description` field (when present).

After the patch, the Zed permission card shows:

```
bash:  cd ~/Projects/foo && pytest tests/test_auth.py -v
       Run pytest on the auth tests
```

instead of:

```
bash:  (empty)
```

### Upstream prospects

**Strong PR candidate to opencode.** The fix doesn't depend on Zed
internals; any ACP client benefits. The only design choice is the
two-line title format, which is harmless for clients that render the
title as a single string (they see a `\n`).

---

## Patch 2: bash permission card behaves like a terminal

**File:** `opencode-zed-patches/our-patch-bash.diff`
**Touches:** `packages/opencode/src/tool/bash.ts`

### The Zed pain

Even after Patch 1 puts the command on the card, the card itself was
inert: a static text block. Output streamed to a separate stdout pane,
and `cwd` was invisible. For long-running commands, the user couldn't
tell what was happening from inside the agent panel.

### The patch

Uses the ACP `_meta.terminal_info` convention -- a Zed-recognized
extension that turns the permission card into a live terminal panel.
`bash.ts` populates `_meta.terminal_info.cwd` with the resolved
working directory and streams stdout/stderr back to Zed during
execution rather than only on completion.

After the patch, the bash card shows the cwd at the top, the command
in the middle, and a streaming terminal pane below it.

### Upstream prospects

**PR candidate to opencode, but with a Zed dependency.** The
`_meta.terminal_info` convention is documented (Zed reads it when
present) but isn't part of the ACP spec. An upstream PR should land
behind a feature-detect or capability check so non-Zed clients don't
break.

---

## Patch 3: small models reliably emit `description` on tool calls

**File:** `opencode-zed-patches/our-patch-tools.diff`
**Touches:** `packages/opencode/src/tool/edit.ts`,
`packages/opencode/src/tool/write.ts`, plus tests.

### The Zed pain

Patch 1 surfaces `description` as line 2 of the card. But
`description` was an *optional* field on `write` and `edit` (it's
required on `bash`). Small local models -- the kind that motivate
this stack at all -- skip optional fields when the prompt is tight.
GLM-4.7-Flash and Qwen2.5-Coder are particularly prone. Result:
even after Patch 1, half the cards still showed only the path with
no human-readable explanation.

### The patch

Marks `description` as **required** in the `write` and `edit` tool
schemas. With `--jinja on` (default in our llama-router.ini),
llama.cpp's grammar-constrained sampling forces the model to emit a
description on every call. The model can't skip the field even on
turns where it would have liked to.

After the patch, every write/edit permission card has a meaningful
second line. The schema change costs ~10 tokens per call and makes
the permission UX consistent across model sizes.

### Upstream prospects

**Mixed.** The schema change is a breaking-ish change for any
existing tool definitions that rely on `description` being optional.
A PR would probably need to land as opt-in via a tool-definition
flag rather than a global default. Worth opening a discussion before
a PR.

---

## Patch 4: skill-load permission cards show what skills are about to load

**File:** `opencode-zed-patches/our-patch-skill-permission.diff`
**Touches:** `packages/opencode/src/tool/skill.ts`,
`packages/opencode/src/acp/agent.ts`

### The Zed pain

opencode's `skill` system loads small specialized prompts on demand
to extend the agent's capabilities. Each skill load goes through the
permission gate by default. But the permission card was useless: a
bare "skill" title with no name, no description, no token cost.
Users either approved blindly or denied blindly.

### The patch

Two-part:

1. **`skill.ts`** enriches the `ctx.ask({...})` call with
   `{name, description, location, tokens_estimated}`. Token estimate
   is a `chars / 4` heuristic on the skill source.
2. **`agent.ts`** extends the title resolver to recognize
   `permission: "skill"` and render
   `"Load skill: <name> (~<N> tokens)"` on line 1 and the
   description on line 2.

After the patch, a skill-load card shows the user exactly what's
about to be loaded into context and how much it costs.

### Upstream prospects

**Strong PR candidate to opencode.** No Zed dependency, no schema
change, no breaking change for existing tool definitions. The
`tokens_estimated` heuristic is opinionated but harmless -- a
displayed estimate is better than no estimate at all.

---

## Patch 5: model swap fires when user selects a not-loaded model

**File:** `opencode-zed-patches/our-patch-router-swap.diff`
**Touches:** `packages/opencode/src/session/prompt.ts`,
`packages/opencode/src/acp/agent.ts`

### The Zed pain

Mainline llama.cpp's
[router mode](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp)
(PR #16653, Dec 2025) lets one llama-server host multiple models in a
preset INI and load them on demand. The mechanic is upstream and works
fine.

The user-experience problem: opencode in Zed has no idea any of this
is happening. If the user picks a not-loaded model in the footer
dropdown, opencode sends the message and llama-server returns
`{"error":{"code":400,"message":"model is not loaded"}}`. The Zed
chat shows a generic "request failed" with no user feedback during
the 3-minute interval where the user could be doing something else.

### The patch

In `prompt.ts`, just after the model is resolved for a turn, check
the local llama-server router's `/models` endpoint for the target's
`status`. If `unloaded` or `loading` and the model points at
`http://127.0.0.1:<port>`, fork
`scripts/model-swap.sh <model-id>` (path from
`OPENCODE_MODEL_SWAP_SCRIPT` env var) and wait for its exit. The
script shows a yad confirm dialog (`--center --on-top --sticky` so
it always claims focus), polls `/models` for `status=loaded`, and
returns 0 on success or non-zero on cancel/error. On non-zero,
opencode emits a `Session.Event.Error` so the user sees "Model swap
cancelled or failed for X. Send another message to retry." in the
chat.

The patch also adds a hook at `acp/agent.ts:unstable_setSessionModel`
intended to fire the swap **at picker-change time** rather than at
message-send time -- but Zed's current dropdown UI doesn't call
that ACP RPC. The hook is dead code awaiting a Zed-side change. See
the **Zed-side opportunity** section below.

After the patch, the user picks a model, types a question, hits
send, sees a popup, confirms, watches a progress dialog, gets an
answer. The flow is reliable end-to-end -- the only friction is the
"type before popup" step that picker-change-time fire would remove.

### Upstream prospects

**Two PRs, two venues:**

- **Opencode PR**: the on-message check + swap-script fork. Generic
  enough to land behind an env-var gate. The dead-code
  `unstable_setSessionModel` hook should not ship to opencode
  upstream until Zed (or another ACP client) actually calls it --
  no point shipping dead code.
- **Zed PR or feature-request**: have the footer model picker call
  `unstable_setSessionModel` over ACP when the user changes the
  selection. This is the load-bearing change for picker-change-time
  swap UX -- without it, opencode can never know about a picker
  change until the next message. The opencode side is ready and
  trivially gated.

---

## What this collection of patches says about Zed's agent UX shape

Three observations worth flagging upstream:

### 1. The permission card is the load-bearing UX surface

For local-model agentic work, the permission card is *the* thing the
user looks at most. Stock opencode treats it as a generic "ask the
human" mechanism; in practice users develop a fast read of the card
to decide approve/deny in <2 seconds. Anything that hides the
relevant content (empty bash card, missing description, generic
"skill" title) gets the user into a habit of approving blindly --
which defeats the point of having a permission gate at all.

Patches 1, 2, 4 are all variations of "make the card show what
matters." A unified PR theme would be: **enrich every permission
request payload with the human-meaningful subject, before sending
it over ACP.**

### 2. Picker changes need an RPC

Patch 5's dead-code hook is the symptom. Zed's footer model picker
is purely client-side; the new selection arrives at opencode bundled
in the next message. For instant feedback (loading dialog, swap
progress, validation), the picker needs to send an ACP RPC at
selection time. The RPC exists (`unstable_setSessionModel`); Zed
just doesn't call it from this code path.

This is a Zed PR. Cheap. The wins compound across any ACP server
that wants to react to picker changes.

### 3. ACP `_meta` extensions are quietly load-bearing

Patch 2 uses `_meta.terminal_info` which is a Zed extension. It
works well; the experience is good. But it's not in the ACP spec,
which means non-Zed clients silently lose the experience. Either
Zed should propose `_meta.terminal_info` for ACP standardization, or
opencode should detect Zed specifically and only emit the metadata
when the client supports it. Today's behavior (always emit) is fine
in practice but spec-wise muddy.

---

## Status

- All five patches are running in production on this workstation.
- None has been submitted upstream.
- Patches 1, 4 are the cleanest opencode PR candidates (no Zed
  dependency, no breaking change).
- Patches 2, 3, 5 each have a complication that's worth surfacing
  in an upstream discussion before a PR (Zed dependency, schema
  change, dead-code hook respectively).

The patches are each <150 lines. The cumulative effect on the user
is large: the same hardware, the same model, the same architecture
becomes substantially more pleasant to use.
