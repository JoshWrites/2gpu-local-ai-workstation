# Repo Issues

Issues found while onboarding a second/remote user that need to be addressed in the repo.

## polkit rule hardcodes usernames

**File:** `systemd/polkit/10-llama-services.rules`

The live rule at `/etc/polkit-1/rules.d/10-llama-services.rules` hardcodes usernames directly in the JS rule (`subject.user === "<admin>" || subject.user === "<user2>"`). The repo template uses an `allowedUsers` array placeholder but still requires manual editing per user.

**Problem:** Adding/removing users requires editing the polkit rule directly. The rule is owned by root and not user-configurable. Username list is not derived from any env file.

**Proposed fix:** Read allowed users from `/etc/workstation/system.env` (e.g. `WS_ALLOWED_USERS="user1 user2"`) and either:
- Parse it in the polkit JS rule via an external helper, OR
- Have `install-systemd-units.sh` template the rule from `system.env` at install time (simpler, no runtime parsing)

The simpler approach: `install-systemd-units.sh` reads `WS_ALLOWED_USERS` from `system.env` and generates the rule with the correct usernames baked in at install time. Re-run the script to update.

## Library submodule (resolved — public 2026-05-06)

The Library submodule was previously a private GitHub repo, blocking
`git clone --recurse-submodules` for any user without explicit access.
Resolved on 2026-05-06: a parallel portability review against the
Library repo (templatize sidecar URLs, sharpen tool docstrings, add
LICENSE + LICENSES.md, standalone-readable README) was completed and
the repo was made public. New users can now clone the umbrella with
`--recurse-submodules` directly.

## Library submodule uses SSH URL (fixed)

**File:** `.gitmodules`

`Library` submodule was configured with `git@github.com:JoshWrites/Library.git` (SSH), requiring a GitHub SSH key for any user cloning the repo. Changed to `https://github.com/JoshWrites/Library.git` so any user can clone without credentials.

**Status:** Fixed in `.gitmodules`. Needs commit and push.

## Proxmox SSH target is a hard requirement in opencode-session.sh

`opencode-session.sh` aborts if `secrets.env` is missing, and the template requires `WS_PROXMOX_USER` and `WS_PROXMOX_HOST`. These are only used in opencode.json permission rules for read-only Proxmox queries — not needed for basic coding work.

**Fix:** Make secrets.env optional, or give `WS_PROXMOX_USER`/`WS_PROXMOX_HOST` empty-string defaults so the stack works for users without Proxmox access.

## Live polkit rule ahead of repo

The live `/etc/polkit-1/rules.d/10-llama-services.rules` diverged from `systemd/polkit/10-llama-services.rules` in the repo. The live version should be committed back to the repo.

## qwen3-coder-30b tool calls not parsed (agentic file-editing blocked)

**Files:** `configs/workstation/llama-router.ini` (`[qwen3-coder-30b]`),
the coder GGUF.

Qwen3-Coder emits its native XML tool format (`<function=name>`
`<parameter=x>...`). On the current llama.cpp HIP build the call is NOT
parsed into `message.tool_calls` -- it leaks into `message.content` as
raw text and `tool_calls` stays empty (`finish_reason: stop`). Verified
2026-06-04 at the raw `/v1/chat/completions` level (bypassing opencode):
gemma/glm/qwen3-next tool calls parse fine on the same build, so this is
specific to Qwen3-Coder's XML format. Effect: the coder can produce
inline code but CANNOT drive agentic file edits (read -> edit -> test) --
its headline strength.

Root cause is the unsloth GGUF's embedded Jinja template hitting
llama.cpp bug #18852 ("Value is not callable: null", template row 62).
This was flagged as an untested risk in the Phase 12 writeup
(`docs/research/2026-05-03-from-one-model-to-an-agentic-stack.md`,
"What Phase 12 didn't prove") and never validated until the 2026-06-04
model battery surfaced it. NOT a regression -- the coder never had
verified tool-calling.

Adding `--chat-template-file` with the official Qwen template did NOT
fix it (the embedded-template bug is upstream of template override on
this build).

**Fix options, cheapest first (to work through):**
1. Try the other on-disk unsloth quant `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`.
2. Download a different-source GGUF: issue #18852 reports mradermacher's
   `Qwen3-Coder-30B-A3B-Instruct.i1-Q4_K_M.gguf` works on recent commits.
3. Rebuild llama.cpp-hip to a version with the qwen3-coder autoparser
   (the `pwilkin/llama.cpp:autoparser` work / PR #18675 Autoparser
   refactor), per the Phase 12 note.

**Status:** Prompt-level tool discipline (inline-by-default, call-don't-
narrate) is fixed and verified in `prompts/qwen3-coder-30b.md`. The
build-level parsing fix is parked pending the GGUF-swap experiments above.
