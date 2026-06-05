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

### Hebrew OCR — research outcome (2026-06-05): use docling + Tesseract(heb)

Background research agent (sources in DECISIONS_JOURNAL / agent transcript)
resolved the path forward, starting from our existing docling pipeline as
suggested:

- **First choice: docling + Tesseract** with the `tesseract-ocr-heb`
  language pack. CPU-only (zero VRAM), proven Hebrew text AND digit
  transcription (Tesseract transcribes pixels; it does NOT exhibit the
  VLM digit-zeroing failure mode). ~92-96% on clean Hebrew print. Config:
  `TesseractCliOcrOptions(lang=["heb","eng"], psm=6)`, `force_full_page_ocr`
  for scans, `TESSDATA_PREFIX=/usr/share/tesseract-ocr/5/tessdata`.
- **Upgrade path: Surya 2** via `docling-surya` plugin (650M VLM, 90.9%
  benchmarked Hebrew, best RTL + digit handling). vLLM backend runs on the
  7900 XTX (gfx1100) via ROCm; can also reduce batch to fit the 5700 XT.
- **docling-serve gotcha (#567):** the HTTP `/v1/convert/file` path SILENTLY
  IGNORES `ocr_engine`/`ocr_lang` and always runs RapidOCR (which has an
  RTL-order bug -> wrong Hebrew). Fix: call docling's Python library
  directly in a sidecar, OR set `DOCLING_SERVE_DEFAULT_OCR_ENGINE=tesseract_cli`
  + ensure `tesseract-ocr-heb` is in the container.
- **Medical safety:** add a digit-validation regex pass after OCR (dates,
  dosages `\d+\.?\d*\s*mg`, lab values) to flag any truncated/zeroed
  numeric sequence before it reaches the reasoner.
- **Ruled out:** EasyOCR (no Hebrew), PaddleOCR/RapidOCR (RTL order bug),
  general VLMs incl. gemma/GLM-OCR (digit-zeroing / Hebrew fail).

**Status:** path chosen, not yet implemented. Implementation = wire
Tesseract(heb) into the Library/docling OCR path + add the digit-validation
layer. Part of the medical-advocate workflow (memory TODO).

### Coder candidates trial (2026-06-05): both new Qwen coders fail on our build

Trialed two current-gen coders for the long-context agentic-coding workflow.
Both FAIL on our llama.cpp HIP build (b9518, gfx1100):

- **Qwen3.6-27B dense (Q4_K_M, ~17GB, GPU-only):** loads, but **crashes on
  first inference** -- hard HIP kernel fault, no error flushed (log dies at
  "initializing slots"). The dense Qwen3.6 arch appears unsupported on this
  build. (Also learned: standalone llama-server here must pin `--device
  ROCm1`; default multi-GPU split tries the unsupported gfx1010 5700 XT and
  silently dies.)
- **Qwen3-Coder-Next (80B MoE / 3B active, UD-Q4_K_XL, ~49GB):** loads fine
  via the router (80s, same n-cpu-moe path as our working qwen3-next-80b),
  chat format peg-native -- but **generates ZERO tokens** on any prompt
  (tool or plain, streaming or not). Loads but cannot generate on this build.

Common thread: very recent (Apr 2026) Qwen models hit build-level
incompatibilities on our HIP llama.cpp, even though the older Qwen3-Next-80B
(same MoE family as Coder-Next) runs fine. This is the THIRD recent-model-
vs-build wall this cycle (gemma4uv vision needed the rebuild; Qwen3-Coder-30B
XML tools unparsed; now these two).

**Conclusion:** neither new coder is usable here right now. **GLM-4.7-Flash
remains the working coder** (tools parse, fits GPU-only, ~59% SWE-bench);
its only weakness for the long-context use case is degradation past ~30K
context. Options for the long-context coding goal: (a) try a NEWER
llama.cpp build (these are fast-moving; a later commit may fix the Qwen3.6/
Coder-Next kernels) -- but weigh against re-validating the whole pool again;
(b) try a different quant/source of these models; (c) accept GLM for now and
revisit. GGUFs kept on disk pending a build bump.

**Status:** long-context coder unresolved; GLM-4.7-Flash is the coder.
Both candidate GGUFs on disk (qwen3.6-27b, qwen3-coder-next), not wired.

### Hebrew OCR: docling + Tesseract(heb) VERIFIED working (2026-06-05)

Implemented + tested the research recommendation. Installed `tesseract-ocr`
5.3.4 + `tesseract-ocr-heb`/`-eng` (apt) and `tesserocr` 2.10.0 into the
docling venv. Tested docling's Python pipeline (TesseractOcrOptions
lang=[heb,eng], force_full_page_ocr) on a Hebrew document image:

- Hebrew text: CORRECT ("טלפון:", "שעות פתיחה:").
- Digits: CORRECT ("03-1234567" exact; "9:00-17:00" read, with one minor
  doubled-digit glitch "99:00"). This is the key win -- digits, which
  gemma zeroed and GLM-OCR couldn't reach, now transcribe correctly.
- Minor: the title line dropped and one digit doubled -- likely synthetic-
  image artifacts (tight margins / display font), expected to be cleaner on
  real scans. Validate on a real (non-sensitive) Hebrew doc before relying
  on it for medical numbers; keep the digit-validation regex layer.

KEY CONFIG FACTS (for wiring docling-serve):
- `tesserocr` default datapath is './' and finds NO languages; MUST set
  `TESSDATA_PREFIX=/usr/share/tesseract-ocr/5/tessdata` (verified: surfaces
  heb+eng). This env var is mandatory in the docling-serve systemd unit.
- docling-serve 1.17.0 / docling 2.91.0. OCR kinds registered:
  easyocr, ocrmac, rapidocr, tesserocr, tesseract (NOT tesseract_cli).
- docling-serve HTTP `/v1/convert/file` IGNORES per-request `ocr_engine`/
  `ocr_lang` (confirmed: accepts a nonexistent engine without error and
  runs the default). Server-side default is the only lever: settings
  `default_ocr_kind` + `default_ocr_preset` (env prefix DOCLING_SERVE_),
  language via a custom OCR preset.

**Status:** capability VERIFIED. Remaining: wire docling-serve to default to
Tesseract+heb (TESSDATA_PREFIX + DEFAULT_OCR_KIND=tesseract + a custom
hebrew preset with lang=[heb,eng]) in its systemd unit, then re-test via the
Library HTTP path. Unit is not yet tracked in the repo -- capture it when wired.

### Hebrew OCR validated on a REAL medical record (2026-06-05)

Ran docling + Tesseract(heb,eng) on a real scanned Maccabi neurology
consult letter (dense Hebrew + embedded English + many numbers + barcodes
+ handwriting). Result: strong, workflow-viable.

- Dates ALL exact (DOB 23/06/1984; 4 visit dates; exam date). Phones, fax,
  mobile, postal code exact. Dosage "אלטרול 25 מ\"ג" exact. Embedded
  English (MIGRAINE, FIBROMYALGIA, MRI, EMG, SSRI, NSAID, GI) correct.
  Document structure (headers, numbered list, diagnosis bullets, "דף 1 מ 2")
  reconstructed well; barcodes skipped; handwriting dropped (expected).
- Hebrew body text largely accurate + readable; meaning preserved
  throughout with some word-level errors.
- ONE critical miss: patient ID 336540257 garbled to "/33694025". This is
  exactly the failure the digit-validation / human-confirm layer must catch
  -- a single wrong ID in an otherwise-excellent transcription.

**Conclusion:** docling+Tesseract is a viable Hebrew medical-OCR engine
(vastly better than gemma's digit-zeroing or GLM-OCR's Hebrew failure). It
is NOT perfect on every number -> the workflow MUST keep a digit-validation
pass + human/clinician confirmation; never blind-trust an OCR'd number.

### Hebrew OCR: SOLVED via the tesseract CLI (not docling-serve) — 2026-06-05

Final outcome. The usable answer is the **tesseract CLI run directly by the
agent**, NOT the docling-serve HTTP path.

- An agent (GLM/Gemma) runs, via its normal bash tool (no sudo):
  `tesseract "<image>" stdout -l heb+eng --psm 3`
  (PDFs: `pdftoppm -png -r 300 doc.pdf /tmp/p && tesseract /tmp/p-1.png stdout -l heb+eng --psm 3`)
  Verified on the real Maccabi record: clean Hebrew + EXACT id/dob/dates/
  dosage -- better than both docling-serve (mojibake) and docling's own
  Python pipeline (which garbled the ID).
- Wired for use: the recipe is in `prompts/shared-environment.md` (all
  models) + `tesseract *` / `pdftoppm *` are on the opencode bash allowlist
  so the agent runs them without a prompt.
- **docling-serve HTTP OCR is NOT used and was reverted.** On docling-serve
  1.17.0 the HTTP /v1/convert/file path does not apply the Hebrew language:
  per-request ocr_engine/ocr_lang are ignored (#567 family) and a server-
  side custom_ocr_presets entry parses in settings but never reaches the
  request-validation registry (custom preset "hebrew" reported "not allowed";
  registry only ever held the auto-registered kinds). Multiple lang formats
  all produced mojibake. Reverted the unit to its original (no OCR default).
  Revisit only if a newer docling-serve fixes HTTP OCR language handling AND
  structured (markdown/table) OCR output is actually needed; for plain text
  feeding a reasoner, the CLI is sufficient and reliable.

**Medical-safety reminder (unchanged):** OCR'd numbers (IDs, dates, dosages,
labs) are not perfect -- surface them as unverified for human/clinician
confirmation against the source image; never assert an OCR'd number.
