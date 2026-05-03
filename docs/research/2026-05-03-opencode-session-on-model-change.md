# opencode session handling on mid-conversation model change

**Date:** 2026-05-03
**Branch context:** `opencode-gpt-oss-120b`
**Question:** When the user changes model in Zed's footer dropdown
mid-conversation, what does opencode actually send to the new model on
the first request after the swap?

This question is load-bearing for the router-mode design (see
`2026-05-03-router-mode-validation.md`). Router mode with
`--models-max 1` enforces mutex at the inference layer: the previous
model's KV cache is destroyed when the new model loads. The opencode
session layer sits on top of that and decides what to replay.

The answer determines the real cost of a mid-session swap and shapes
the popup UX.

---

## Findings

Researched against opencode's source (anomalyco/opencode) at the time
of this writing. File and line references are from the agent's
investigation; verify against current upstream before relying.

### Conversation history: full replay every turn

The agent loop in `packages/opencode/src/session/prompt.ts` (around
line 1400) reloads **all** non-compacted messages from SQLite on
every iteration:

- `MessageV2.filterCompactedEffect(sessionID)` (line 1411) -- pulls
  the full session message history.
- `MessageV2.toModelMessagesEffect(msgs, model)` (line 1571) --
  projects the entire array into AI-SDK `ModelMessage[]`.
- The result is passed to `streamText` (line 1583) as
  `messages: [...modelMsgs, ...]`.

There is no last-turn-only path. There is no "model change" branch
that summarizes. Compaction only fires when token count exceeds the
target model's context window (line 1481, `compaction.isOverflow`).

**A model swap by itself does not trigger compaction. It triggers a
full replay against a cold KV cache.**

### Reasoning content cross-model: stripped of metadata, demoted to text

In `packages/opencode/src/session/message-v2.ts`, function
`toModelMessagesEffect`:

```ts
// line 840
const differentModel = `${model.providerID}/${model.id}` !==
                       `${msg.info.providerID}/${msg.info.modelID}`
```

For every assistant message authored by a *different* model than the
one currently being called:

- Lines 940-953: `reasoning` parts are downgraded -- if
  `differentModel` is true, the reasoning text is appended as a plain
  `text` part (only if non-empty), otherwise the reasoning entry is
  sent as-is with its `providerMetadata`.
- Lines 862, 900, 913, 923, 937: `providerMetadata` /
  `callProviderMetadata` are dropped on cross-model replay.

**Net effect:** GPT-OSS Harmony reasoning (the `analysis` channel)
becomes inline text content for GLM-4.7's view of the conversation.
The new model sees the prior model's chain-of-thought as if it were
normal output, which can mildly confuse the new model and inflates
the prompt -- but it does not get re-injected as
`reasoning_content` and Harmony channel markers are stripped.

For same-provider OpenAI-compatible models with Harmony-style
channels, `provider/transform.ts` lines 217-249 hoists reasoning into
`providerOptions.openaiCompatible.reasoning_content` (or whatever
`model.capabilities.interleaved.field` is). On a cross-model swap,
`differentModel` short-circuits this so the field isn't re-attached.

### Mid-tool-loop swap: deferred to next user message

Model selection is stored on the *user* message (`lastUser.model`,
line 1419) and re-read each loop iteration (line 1458). If the user
changes the model in Zed's picker mid-tool-call:

- ACP `unstable_setSessionModel` (`acp/agent.ts` line 1287) updates
  only the in-memory `ACPSessionState` -- it does NOT publish a
  `ModelSwitched` event yet.
- The current `streamText` call continues against the old model.
- `SessionEvent.ModelSwitched` is only published in
  `createUserMessage` (`prompt.ts` lines 973-985), comparing the new
  user message's model against `SessionTable.model`.
- Pending/running tool calls during the swap window are wrapped as
  errors (`message-v2.ts` lines 929-938:
  `errorText: "[Tool execution was interrupted]"`).

The swap effectively "lands" on the next user prompt, never
mid-loop. **This means there are no race conditions to worry about
in the swap popup design.** The popup can confidently fire on model
change because the side effects are already deferred to the right
moment.

### Session storage shape

- `~/.local/share/opencode/storage/` is **legacy**. Current state
  lives in SQLite at `~/.local/share/opencode/opencode.db`.
- Per-message: `MessageTable.data` includes `providerID` and
  `modelID` for assistant messages, and `model: {providerID,
  modelID, variant}` for user messages. This is what powers the
  cross-model reasoning stripping.
- Per-session: `SessionTable.model` holds the currently-selected
  model. Updated by `SessionEvent.ModelSwitched` projector in
  `session/projectors-next.ts` lines 132-145.

### keep_alive / backend pinning

Not propagated. anomalyco/opencode issue #2979 confirms
`"keep_alive": 300` in the provider options block is dropped.
opencode uses `@ai-sdk/openai-compatible` and only forwards a fixed
allowlist of fields; arbitrary body params for Ollama (and by
extension llama.cpp's similar long-poll knobs) aren't passed
through. Issue still open as of this research.

This is mostly background context; for our use case (router-mode
with `--models-max 1`) we don't *want* keep_alive to keep the old
model alive after a swap -- the mutex is what makes VRAM available
for the new one.

## Implications

### Real cost of a swap, depth-dependent

| Scenario | Load | Re-eval | Total |
|---|---:|---:|---:|
| Fresh OSS session, first turn | 240s | 0 | 4 min |
| Fresh GLM session, first turn | 35s | 0 | 35 s |
| Swap GLM->OSS at 30K context | 240s | ~90s @ 333 prompt-tok/s | ~5.5 min |
| Swap OSS->GLM at 30K context | 35s | ~30s @ ~1000 prompt-tok/s GLM est | ~1 min |
| Swap GLM->OSS at 100K context | 240s | ~210s | ~7.5 min |
| Swap OSS->GLM at 100K context | 35s | ~75s GLM est | ~110 s |

The asymmetry is significant: **swapping *to* OSS at depth is the
painful direction; swapping *from* OSS is cheap.** This shapes the
expected workflow -- GLM as default, dip into OSS for hard problems,
drop back when done.

### Re-eval cost is roughly equal to a fresh prompt of the same size

Because opencode replays the full message array (with reasoning text
demoted but still present), token count after the swap is essentially
the same as before. The new model has to prefill the entire history
through its prefill kernel. **No tricks reduce this** -- the only
actual context-saving behavior in opencode is overflow-triggered
compaction, which doesn't fire on swap.

### Implications for the swap popup

The popup should show **session-depth-aware time estimates**, not
just load time:

```
Switch from <current> to <target>?

  Conversation has ~32K tokens.
  Loading <target>: ~4 min.
  Re-evaluating conversation: ~90 sec.
  Total: ~5.5 min.

Memory check:
  GPU: 24 GB total, ~22.5 GB free after unload, target needs 18 GB OK
  RAM: 64 GB total, ~50 GB free after unload, target needs 46 GB OK

(Cancel) (Swap, keep history) (Swap, start fresh session)
```

The "Swap, start fresh session" path is cheap (just load time) and
gives the user an explicit choice when prior history isn't needed.
Implementation: after the swap, opencode's session-create endpoint
gets called to start a clean session, which Zed picks up on its
next prompt.

The session-depth number comes from opencode's own SQLite at
`~/.local/share/opencode/opencode.db` -- a small query before the
yad popup renders.

### Implications for model-pool design

- **No need to engineer a context-handoff mechanism.** opencode's
  full-replay-with-reasoning-demotion is competent. Tokens cost real
  re-eval time but the behavior is correct.
- **Consider a "preferred default" model.** If GLM is faster to swap
  to and from, making it the default and the OSS swap an explicit
  "I want deeper reasoning" gesture matches the cost asymmetry.
- **The pool can grow safely.** Adding more models doesn't change
  the swap mechanics -- they all share the same replay-on-swap path.

## What this validation does **not** answer

A separate question opened: **when GLM (64K context) is swapped IN
from a session that has accumulated more than 64K tokens on OSS
(128K context), what happens?** opencode's compaction fires at
overflow -- but does it fire *before* the request goes to GLM, or
does the request fail? Does it compact to fit GLM's 64K, or does
opencode reject the swap as impossible? This is the next question
to chase before designing the popup's overflow-warning path.

## Sources

- Agent investigation, 2026-05-03, with file:line citations from
  current opencode source tree.
- [anomalyco/opencode issue #2979 (keep_alive not propagated)](https://github.com/anomalyco/opencode/issues/2979)
- [llama.cpp router mode validation, 2026-05-03](2026-05-03-router-mode-validation.md)

Code references (verify against upstream before depending):
- `packages/opencode/src/session/prompt.ts` lines 1400-1590
- `packages/opencode/src/session/message-v2.ts` lines 729-992
- `packages/opencode/src/provider/transform.ts` lines 199-249
- `packages/opencode/src/session/projectors-next.ts` lines 132-145
- `packages/opencode/src/acp/agent.ts` lines 1287-1307, 1471-1482
