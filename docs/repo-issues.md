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

**Investigation 2026-06-04 (after the llama.cpp rebuild) — narrowed, still unfixed:**

1. **Rebuilt llama.cpp-hip 0929436 -> b9518 (7c158fb).** Did NOT fix it.
   The current build still classifies the coder as chat format
   `peg-native`, which does not parse the `<function=>` XML. (The rebuild
   DID fix gemma vision -- so it was worth doing -- but not this.)
2. **Official Qwen3-Coder `--chat-template-file`.** Did NOT fix it. The
   template loads (log shows the ChatML `example_format`) but llama.cpp
   still picks `peg-native` for tool parsing -- on this build the tool
   parser is not selected from the template.
3. **On-disk `Q4_K_M` unsloth quant** (vs the `UD-Q4_K_XL` we run): tested
   standalone but the run stalled in warmup; inconclusive, not pursued
   further given the next point.

**Revised root cause:** upstream llama.cpp issue #15012 ("Qwen3-Coder Tool
Call Parser") is still OPEN. Native parsing of Qwen3-Coder's custom XML
tool format likely is NOT in mainline -- so this is not a config we are
missing, and neither a rebuild nor a template selects a parser that does
not exist. A GGUF swap (mradermacher / ggml-org official) MIGHT carry a
template that coaxes a working path, but that is unverified and the payoff
is uncertain.

**Practical consequence + recommendation:** the coder cannot drive agentic
file edits on this stack. Per the 2026-06-04 redundancy finding, GLM-4.7-
Flash already covers functional agentic coding (its tool calls parse, code
quality is good, SWE-bench ~59%). So the coder's headline strength is
currently better served by GLM. Options going forward: (a) wait for
upstream #15012 to merge, then retest; (b) try a different-source GGUF as
a one-off experiment; (c) accept GLM as the coding agent and treat the
coder as an inline-code generator only -- or drop it (see the pool report).

**Status:** Prompt-level tool discipline (inline-by-default, call-don't-
narrate) is fixed and verified in `prompts/qwen3-coder-30b.md`. The
agentic tool-calling fix is BLOCKED on upstream llama.cpp support.

## Hebrew OCR: GLM-OCR fails Hebrew; gemma reads words but mangles digits

**Context:** evaluating a Hebrew OCR path for the medical-advocate workflow
(bilingual He/En records). Tested 2026-06-05 on a synthetic Hebrew sign
image (known content: "ספרייה ציבורית", "שעות פתיחה: 9:00-17:00",
"טלפון: 03-1234567"), via standalone llama-server (Vulkan build 8799, which
has glm4v projector support).

Findings:
- **GLM-OCR (zai-org, 0.9B, ggml-org GGUF):** loads fine on the 5700 XT
  (~1.4GB, glm4v projector OK). EXCELLENT English OCR -- read a dense
  invoice perfectly including every digit (better than gemma on digits).
  But **completely fails Hebrew** -- returns repeated garbage
  ("הפרוטקסט קריאי") unrelated to the image. Its "109 languages" claim
  does not extend to usable Hebrew.
- **gemma-4-12b (our pool vision model):** reads Hebrew WORDS accurately
  (correct text + transliteration + translation) but **zeros out the
  digits** -- rendered "9:00-17:00" as "00:00-00:00" and the phone number
  as "00-0000000", even though its hidden reasoning channel had read
  "09:00-17:00" correctly. Same digit weakness as on English, worse here.

**Conclusion:** neither is a reliable Hebrew-OCR solution as-is. For
MEDICAL documents this is disqualifying -- dates, dosages, and lab values
are exactly the digits both models mangle. GLM-OCR is, however, a strong
English OCR engine worth keeping in mind for the English half of a
bilingual corpus.

**Status:** Hebrew OCR unsolved. The medical-advocate TODO should treat
Hebrew document OCR as an open research problem (try a Hebrew-specialized
OCR, or a larger VLM, or a hybrid: gemma/larger-VLM for words + a
digit-focused pass). GLM-OCR GGUFs kept on disk for now (English OCR
value); revisit. Do not assume any current model handles Hebrew numbers.
