# Implementation Plan — Phases 1–3

**Scope:** Phases 1–3 only (Phase 4+ deferred per `--cram` simplification noted in the reference guide)
**Hardware:** Ryzen 9 5950X, 62 GB RAM, RX 7900 XTX (gfx1100, ROCm working) + RX 5700 XT (gfx1010, unconfigured), Ubuntu 24.04, kernel 6.17

---

## Pre-Phase-1 Gate

**Purpose:** Verify the starting state before disturbing anything. No installs, no reboots, no writes to system config.

### Gate checks (all read-only)

1. **ROCm sanity on 7900 XTX**
   - `rocminfo | grep -E "Name:|gfx"` — confirm gfx1100 and gfx1010 present.
   - `rocm-smi --showproductname --showmeminfo vram` — confirm both cards visible.
   - **Confirmed device indices on this box (2026-04-15):** GPU 0 = 5700 XT (gfx1010), GPU 1 = 7900 XTX (gfx1100). This is the **opposite** of what the reference guide assumes. All `ROCR_VISIBLE_DEVICES` and `cuda:N` references in this plan use the confirmed ordering.
   - **Baseline VRAM on 7900 XTX is ~2 GB** — KDE Plasma X11 rendering the desktop. This is expected, not a leak. Leaves ~22 GB for inference, which fits Qwen3.5-27B Q4_K_M + 32K context comfortably.
   - PyTorch verification uses the existing vLLM venv, not system Python:
     `/home/levine/.local/share/vllm-env/bin/python -c "import torch; print(torch.version.hip, torch.cuda.device_count(), [torch.cuda.get_device_name(i) for i in range(torch.cuda.device_count())])"`
     This venv has torch 2.9.1+hip7.0 and is the "when I need torch" environment going forward — no system-wide torch install.
2. **Ollama baseline verification** — the 2026-04-15 boot cleanup disabled all three `ollama*.service` units. Verify the cleanup still holds before building on top of it:
   - `systemctl is-enabled ollama.service ollama-gpu0.service ollama-gpu1.service` — all three must report `disabled`. Any `enabled` result means something re-enabled autostart and the cleanup regressed.
   - `systemctl is-active ollama.service ollama-gpu0.service ollama-gpu1.service` — all three must report `inactive`. If active, nothing to worry about functionally, but note it so the launch script's stop loop runs instead of starting cold.
   - `ls -la ~/.ollama/ && du -sh ~/.ollama/models` — record model cache contents; these are reusable on the 5700 XT in Phase 2.
3. **Disk space**
   - `df -h /` — need ≥ 60 GB free after model downloads (Qwen3.5-27B Q4_K_M ≈ 17 GB, draft 0.5B ≈ 0.5 GB, Phi-4 Mini ≈ 3 GB, build artifacts ≈ 2 GB, headroom for KV save paths and observer store). User reports ~1.1 TB free → pass.
4. **Kernel / amdgpu boot-hang risk assessment**
   - `uname -r` (expect 6.17.x), `dmesg | grep -iE "amdgpu|drm" | tail -50` — look for prior hang/timeout/ring-reset entries.
   - `cat /etc/default/grub | grep GRUB_CMDLINE` — record current cmdline.
   - Confirm at least one prior-working kernel entry exists: `ls /boot/vmlinuz-*`.
5. **Snapshot the clean baseline** (no changes, just capture) to `~/second-opinion-backups/pre-phase1/`:
   - `systemctl list-unit-files 'ollama*' 'llama*' 'vllm*' > enabled-ai-units.txt` — should show all disabled.
   - `systemctl list-units --type=service --state=running > running-services.txt` — baseline for drift detection.
   - `ollama list > ollama-models.txt` (works whether or not the daemon is running, reads the on-disk manifest).
   - Copy `/home/levine/Documents/Repos/Workstation/boot-cleanup-2026-04-15.md` into the backup dir for provenance.
6. **Reboot policy** — default posture for Phases 1–3: **no reboots**. If a reboot becomes necessary (kernel module reload for `render`/`video` group membership on a fresh user, etc.), the gate requires:
   - A tested GRUB fallback entry selected and verified bootable via `grub-reboot` (one-shot) rather than editing default.
   - `amdgpu.dc=1 amdgpu.gpu_recovery=1` already present or explicitly added as rescue options ready to paste at grub menu.
   - Since ROCm already works on 7900 XTX, user is already in `render`/`video` groups → no reboot needed for Phase 1. Flagged as lookup: verify `groups | grep -E "render|video"`.

### Gate exit criteria
All six checks pass and outputs captured in `~/second-opinion-backups/pre-phase1/`. If any fail, stop and triage before Phase 1.

---

## Phase 1 — Core stack on 7900 XTX

### 1. Goal
User can say "write and test a trivial Python project" to Roo Code in VSCodium and the agent completes it end-to-end against a local Qwen3.5-27B served by llama-server.

### 2. Prerequisites
- Pre-Phase-1 gate passed.
- Build toolchain for llama.cpp: `cmake`, `git`, `hipcc`, ROCm dev headers. Lookup step: confirm package names on Ubuntu 24.04 ROCm repo (likely `rocm-hip-sdk` or `hip-dev`; user's existing ROCm install should already provide these — verify with `which hipcc` before installing anything).
- Working directory: `~/src/llama.cpp` for build, `~/models/` for GGUFs.

### 3. Concrete steps

**Decision 1.a — Ollama cohabitation on 7900 XTX.**
Chosen: **Keep Ollama binaries installed. All Ollama system units stay disabled (as they already are per 2026-04-15 boot cleanup). Start Ollama only on demand, never at boot.** Do NOT uninstall.
Rationale: (a) Phase 2 repurposes Ollama for the 5700 XT on port 11435; the binaries and model cache are reusable; (b) a manually-startable Ollama on 11434 is a useful fallback if llama-server build breaks; (c) Ollama and llama-server both want VRAM on gfx1100 — they cannot run concurrently on the primary GPU.

**Current reality (as of boot-cleanup-2026-04-15):** three Ollama system units exist and are all disabled — `ollama.service`, `ollama-gpu0.service`, `ollama-gpu1.service`. None autostart. The launch script below is defensive: it stops any that happen to be running (e.g. manually started earlier in the session) without enabling or re-enabling anything on exit. The "restart Ollama on exit" behavior from the original plan is dropped — we do not resurrect a service the boot cleanup intentionally disabled.

Operational rule: **never `systemctl enable` any ollama*.service on this workstation.** If Ollama is needed, start it for the session only (`systemctl start ollama`) and stop it when done.

**Step 1.1 — Build llama.cpp with ROCm.**
```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100 -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(nproc)
```
Flag as lookup: exact CMake flag for `--cram`/host-memory prefix cache is recent — inspect `build/bin/llama-server --help | grep -iE "cram|cache-ram"` after build to confirm flag name in the installed version.

**Step 1.2 — Download Qwen3.5-27B text-only GGUF.**
Lookup: exact HF repo path for Qwen3.5-27B text-only Q4_K_M GGUF is not known at plan time. Use `huggingface-cli` to search: `huggingface-cli search Qwen3.5-27B gguf`. Pick the repo explicitly marked text-only (no `mmproj` file) to sidestep the multimodal slot-save bug. Download to `~/models/qwen3.5-27b-text-q4_k_m.gguf`.

Also download draft model (for Phase 3, but convenient to get now): `Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf` → `~/models/`.

**Step 1.3 — Write launch script `scripts/primary-llama.sh`.**
Stops any running Ollama unit (defensive — none should be running after boot cleanup), launches llama-server in the foreground, and does NOT restart Ollama on exit (the boot cleanup intentionally disabled all three ollama*.service units; we honor that).

```bash
#!/usr/bin/env bash
set -euo pipefail

# Defensive: stop any ollama unit that might be running this session.
# All three are disabled at boot per 2026-04-15 cleanup; this only matters
# if one was manually started earlier.
for unit in ollama.service ollama-gpu0.service ollama-gpu1.service; do
  if systemctl is-active --quiet "$unit"; then
    sudo systemctl stop "$unit"
  fi
done

mkdir -p /tmp/aspects

HSA_OVERRIDE_GFX_VERSION=11.0.0 \
GPU_MAX_HEAP_SIZE=100 \
GPU_MAX_ALLOC_PERCENT=100 \
exec ~/src/llama.cpp/build/bin/llama-server \
  -m ~/models/qwen3.5-27b-text-q4_k_m.gguf \
  -ngl 99 \
  -c 32768 \
  --flash-attn \
  -ctk q8_0 -ctv q8_0 \
  --jinja \
  --slot-save-path /tmp/aspects/ \
  --numa distribute \
  --host 127.0.0.1 --port 11434
```
Phase 1 intentionally omits `-md` / `-devd none` / `--draft-max` — those are Phase 3.

`exec` replaces the shell with llama-server so Ctrl+C goes straight to the server and there's no lingering bash wrapper. No `trap` needed since we deliberately don't resurrect Ollama on exit.

**Step 1.4 — Install VSCodium + Roo Code.**
- VSCodium: Ubuntu has it via `apt` (after adding their repo) or Flatpak. Lookup: confirm current install method preference.
- Roo Code: install from Open VSX inside VSCodium (search "Roo Code") or sideload VSIX.
- Configure provider: "OpenAI Compatible", Base URL `http://localhost:11434/v1`, Model name = GGUF filename stem.
- Apply auto-approve settings per reference-guide Part 5 (reads on, writes on with 2000 ms delay, mode switch on, subtasks on, terminal allowlist/denylist as specified, request limit 70).

**Step 1.5 — Scaffold rules and memory bank in `second-opinion` repo.**
Create (agent writes, not this plan):
- `~/.roo/rules/personal.md` — global rules from reference-guide Part 6.
- `rules-templates/project.md`, `rules-templates/rules-code-implementation.md`, `rules-templates/rules-architect-planning.md`, `rules-templates/rules-code-memory.md` — template copies for new projects.
- `memory-bank-template/` directory with empty `productContext.md`, `activeContext.md`, `progress.md`, `decisionLog.md`, `systemPatterns.md`.

**Step 1.6 — Custom modes.** Add Review and Spec modes per reference-guide Part 5 via Roo Code's mode UI (exported to `~/.roo/custom_modes.yaml` — lookup: confirm exact filename/location in installed Roo Code version).

**Step 1.7 — End-to-end smoke test.** In a scratch directory, ask Roo Code (Code mode) to: "Create a Python project with a function that reverses a string, add pytest tests, run them, and commit." Observe entire flow unattended save for terminal-command approvals (or pre-approved via allowlist).

### 4. Success checkpoints
- `curl -s http://127.0.0.1:11434/v1/models | jq '.data[].id'` returns the Qwen3.5-27B model id.
- `curl -s http://127.0.0.1:11434/v1/chat/completions -d '{"model":"<id>","messages":[{"role":"user","content":"say hi"}]}' -H 'Content-Type: application/json'` returns a completion.
- `rocm-smi` during generation shows 7900 XTX VRAM at ~17–18 GB and GPU utilization spike.
- Smoke test completes: tests pass, git commit made, total wall time < 3 minutes after model is loaded.
- Generation benchmarks at ≥ 18 t/s on a 500-token completion (native, no spec decode yet). Measure via llama-server logs or the `--verbose` timing output.
- `POST /slots/0/save?filename=test.bin` succeeds and `/tmp/aspects/test.bin` exists and is > 0 bytes (text-only GGUF mitigates the multimodal slot bug).

### 5. Failure modes and recovery
- **llama.cpp ROCm build fails (hipcc missing / header mismatch).** → Install `rocm-hip-sdk` (lookup exact package), rerun. If still failing, try building with `-DGGML_HIPBLAS=ON` fallback flag (lookup: currently supported flag name varies by version).
- **llama-server starts but crashes on first completion.** → Check `HSA_OVERRIDE_GFX_VERSION=11.0.0` is set; check dmesg for ring timeouts; drop `--flash-attn` as first mitigation.
- **Slot-save returns error even with text-only GGUF.** → Confirm no `mmproj` in the GGUF (`llama-server --help` + inspect model metadata via `llama-gguf`); if bug persists, disable slot save for Phase 1 (drop `--slot-save-path`), defer to Phase 4 `--cram` approach.
- **Roo Code cannot see the server.** → Verify base URL includes `/v1`; test with `curl` first; check Roo Code's "API Provider" is exactly "OpenAI Compatible" not "Ollama".
- **VRAM OOM at model load.** → Drop `-c 32768` to `-c 16384`; if still OOM, confirm Ollama is actually stopped (`rocm-smi` shows 0 MB used before launch).
- **Generation < 10 t/s.** → Check for layer spillover in log ("offloaded X/Y layers"); verify `-ngl 99` was honored; inspect `--numa` effect.
- **Agent loops or produces garbage.** → Rules file not loaded — check `~/.roo/rules/personal.md` path; check `--jinja` flag present; drop temperature to 0.3.

### 6. Abort criteria
- llama.cpp ROCm build fails twice after two remediation attempts within 2 hours → abort Phase 1, reassess (consider prebuilt binary from llama.cpp releases).
- Slot-save fundamentally broken on text-only GGUF and blocks Roo Code flow → abort the slot-save portion only, continue the rest of Phase 1.
- 7900 XTX exhibits ring timeouts / driver hangs during inference → stop, do not reboot without explicit user decision; capture dmesg and stop.

### 7. Time budget
Estimated: 4–6 hours. Hard cap: **10 hours**. If not done by cap, stop and re-plan.

---

## Phase 2 — 5700 XT online + manual observer + dual-scope indexes

### 1. Goal
A session started after Phase 2 begins with prior-session context automatically loaded from observer indexes — the agent references past learnings without being told.

### 2. Prerequisites
- Phase 1 complete and stable for at least one real session.
- `ollama` binary installed (from pre-phase backup — it already is).
- 5700 XT physically present and visible in `lspci | grep -i vga` (confirm before starting).

### 3. Concrete steps

**Step 2.1 — Make 5700 XT inferenceable. Time-boxed: 3 hours.**
Note: 5700 XT is at `ROCR_VISIBLE_DEVICES=0` on this box (not =1 as the reference guide assumes). Try in order, stop at first that works:
1. **ROCm with override = 10.1.0:** `HSA_OVERRIDE_GFX_VERSION=10.1.0 ROCR_VISIBLE_DEVICES=0 rocminfo` → confirm only gfx1010 visible. Then test with a small model via Ollama (see 2.2).
2. **Override = 10.3.0** if 10.1.0 produces runtime errors but not detection errors.
3. **Vulkan fallback:** install `mesa-vulkan-drivers` + `vulkan-tools`; confirm `vulkaninfo | grep "deviceName"` lists the 5700 XT. Then run Ollama with `OLLAMA_VULKAN=1` (lookup: confirm this env var name — it may instead require a Vulkan-enabled Ollama build; flag as lookup step).

**Step 2.2 — Configure secondary Ollama systemd unit on port 11435.**
Create `/etc/systemd/system/ollama-secondary.service` (needs sudo — user-approved):
```
[Service]
Environment="ROCR_VISIBLE_DEVICES=0"
Environment="HSA_OVERRIDE_GFX_VERSION=10.1.0"   # or Vulkan equivalent
Environment="OLLAMA_HOST=127.0.0.1:11435"
Environment="OLLAMA_FLASH_ATTENTION=0"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
ExecStart=/usr/local/bin/ollama serve
```
The primary Ollama service (still installed, used as fallback when llama-server is down) keeps its default config on port 11434; it is only run when llama-server is stopped, so there's no port conflict.

Pull Phi-4 Mini: `OLLAMA_HOST=127.0.0.1:11435 ollama pull phi4-mini` (lookup: exact Ollama tag for Phi-4 Mini 3.8B Q5_K_M, may be `phi4-mini:3.8b-q5_K_M` or similar — confirm via `ollama search`).

**Step 2.3 — Write observer extraction script `scripts/observer-extract.py`.**
Inputs: path to a Roo Code conversation export (JSON). Process: chunk to fit Phi-4 Mini's 128K window (comfortably the whole session), call `POST http://127.0.0.1:11435/v1/chat/completions` with the extraction prompt from reference-guide Part 2, parse returned JSON array, emit new observation files.
Output: one markdown file per observation in `~/.observer/refs/g####.md` or `<project>/.observer/refs/p####.md`; append index line to respective `index.md`.
ID assignment: read current max ID from `~/.observer/refs/` and `<project>/.observer/refs/`, increment.
The script is a manual post-session tool — user runs it explicitly or the agent runs it via a Roo Code command at session end.

**Step 2.4 — Scaffold the dual-scope stores.**
- Create `~/.observer/index.md` with section headers (`## Patterns`, `## Mistakes to avoid`, `## User preferences`) and empty body.
- Create `~/.observer/refs/` directory.
- Create per-project stubs `second-opinion/.observer/index.md` and `.observer/refs/`.
- Add `.observer/` to projects' `.gitignore` patterns for global scope only (`~/.observer/` is never in any repo); per-project `.observer/` IS git-tracked (per reference-guide).

**Step 2.5 — Add the session-start global rule.**
Append to `~/.roo/rules/personal.md`:
```
At session start, read ~/.observer/index.md and .observer/index.md (if it exists in the project root).
Before architectural decisions, tool choices, or when encountering errors, consult both indexes for relevant entries.
For relevant entries, read the full content at:
  - ~/.observer/refs/{id}.md for g-prefixed IDs
  - .observer/refs/{id}.md for p-prefixed IDs
```

**Step 2.6 — Conversation export workflow.**
Lookup step: determine current Roo Code conversation export format (JSON file location in VSCodium extension storage, likely `~/.config/VSCodium/User/globalStorage/rooveterinaryinc.roo-cline/tasks/<task-id>/`). Document the export path in `scripts/README.md` so future agents can find it.

**Step 2.7 — Between-session debrief prompt.**
Add canned prompt to `prompts/debrief.md`:
> Review what we accomplished this session. Then: (1) update `memory-bank/activeContext.md`, `progress.md`, `decisionLog.md` as appropriate; (2) list observations worth extracting (decisions, mistakes, user corrections, patterns) in a summary at the end. Do not write to `.observer/` directly — the observer script handles that.

### 4. Success checkpoints
- `curl -s http://127.0.0.1:11435/v1/models` returns `phi4-mini`.
- `rocm-smi` shows both GPUs; running Phi-4 Mini on 11435 does not affect 7900 XTX VRAM usage.
- Phi-4 Mini generates at ≥ 12 t/s (Vulkan acceptable) or ≥ 20 t/s (ROCm) on a 300-token completion.
- Running `scripts/observer-extract.py` on a captured session JSON produces ≥ 1 observation with valid schema (category, scope, summary, context, tags), written to correct refs directory, indexed.
- Starting a fresh Roo Code session in a project with non-empty `.observer/index.md`: the agent's first response references at least one observation id OR explicitly acknowledges having read both indexes.
- The two Ollama / llama-server endpoints are on different ports and don't conflict (`ss -ltnp | grep -E "11434|11435"` shows both).

### 5. Failure modes and recovery
- **5700 XT not detected by rocminfo even with override.** → Try the second override value; then Vulkan. Do not reboot to "fix" — the card is either PCIe-visible or it isn't.
- **Ollama starts on secondary but Phi-4 Mini crashes on load (ROCm kernel fault).** → Fallback to Vulkan. Log the exact error to `~/second-opinion-backups/phase2/rocm-5700xt-fail.log` for future reference.
- **Vulkan works but generation is < 5 t/s.** → Acceptable for post-session batch observer (not latency-critical). Document and move on.
- **Phi-4 Mini extraction returns malformed JSON.** → Tighten the extraction prompt with a worked example; add a schema-validation pass in the script that retries on malformed output up to 2 times; fall back to logging the raw output for manual review.
- **Agent ignores observer index at session start.** → Rule file path wrong; rule too long and truncated; rule conflicting with mode-specific rules. Verify by asking the agent "what files did you read at session start?" at the start of a test session.
- **`.observer/` accidentally committed with sensitive info.** → Per-project `.observer/` is intentionally committed; if the user later wants privacy, flip it to `.gitignore`. Global `~/.observer/` is never in a repo.

### 6. Abort criteria
- Neither ROCm override nor Vulkan gets the 5700 XT to generate tokens within the 3-hour time-box → abort 5700 XT portion, continue with observer running on CPU via llama-server (Phi-4 Mini on CPU is ~3 t/s; still workable for post-session batch).
- Observer extraction quality is so poor that observations are actively misleading after 3 sessions → pause extraction, revise the prompt, do not feed garbage into the index.

### 7. Time budget
Estimated: 6–10 hours (driven by 5700 XT surprise risk). Hard cap: **16 hours**. If capped out, abort the 5700 XT piece and fall back to CPU Phi-4 Mini.

---

## Phase 3 — Speculative decoding + parallel validation

### 1. Goal
The agent generates noticeably faster on code tasks AND the GPU never waits for tests to run — CPU validation runs in parallel with the next edit.

### 2. Prerequisites
- Phases 1 and 2 stable.
- Draft model `Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf` already downloaded in Phase 1.
- `pytest`, `ruff`, `mypy`, `watchdog` (Python) available system-wide or in a venv.

### 3. Concrete steps

**Step 3.1 — Add speculative decoding flags to `scripts/primary-llama.sh`.**
Add:
```
  -md ~/models/qwen2.5-coder-0.5b-q8_0.gguf \
  -devd none \
  --draft-max 16 --draft-min 4 \
```
Stop + restart the script. Verify via server log line reporting draft model loaded and running on CPU (no additional VRAM consumed on 7900 XTX).

**Step 3.2 — Benchmark spec-decode delta.**
Script `scripts/bench-generation.py`: sends the same 3 fixed prompts (one code-heavy, one prose, one JSON-structured) with `stream=true`, measures tokens/sec. Run once with `-md` disabled (spawn a second llama-server on port 11436 without the flag) and once with enabled. Record results to `docs/benchmarks/phase3-specdecode.md`.

**Step 3.3 — Build validation runner `scripts/validation-runner.py`.**
Stack: `watchdog` for file events + `subprocess` for test runners + JSON output file.
Behavior:
- Watches configured project roots (passed via CLI or config file at `scripts/validation-runner.yaml`).
- On any `.py` file save, debounces 500 ms then runs in parallel: `pytest <tests-for-that-module> -x --tb=short`, `ruff check <file>`, `mypy <file>`.
- Writes results atomically to `<project-root>/.validation/results.json` with fields: `{file, timestamp, pytest: {rc, stdout_tail}, ruff: {rc, stdout}, mypy: {rc, stdout}}`.
- Never blocks; always overwrites with latest.

**Step 3.4 — Teach agent to consult validation results.**
Append to `rules-templates/rules-code-implementation.md`:
```
After writing or editing any .py file:
1. Wait 2 seconds (Roo Code write-delay already covers this).
2. Read .validation/results.json if it exists. If the file you just edited appears there with non-zero rc in any of pytest/ruff/mypy, fix those issues before proceeding to the next file.
3. If .validation/results.json does not exist or is older than your edit, continue without blocking — validation has not caught up yet; it will be checked after the next edit.
```

**Step 3.5 — Systemd user unit for validation runner** (optional, convenient): `~/.config/systemd/user/validation-runner.service`, started per project or as a user-level service pointed at a config file listing active project roots.

**Step 3.6 — Benchmark parallel-validation delta.**
Run a fixed 5-file refactor task twice: once with validation runner off (agent runs pytest in terminal sequentially), once with it on. Measure wall time. Record to `docs/benchmarks/phase3-parallel-validation.md`.

### 4. Success checkpoints
- `curl http://127.0.0.1:11434/health` (or equivalent) reports draft model loaded.
- Spec-decode benchmark shows ≥ 30% throughput improvement on the code-heavy prompt (reference-guide predicts 1.3–1.8×; anything ≥ 1.3× passes).
- During generation, `htop` shows CPU threads running the draft model; `rocm-smi` shows 7900 XTX VRAM unchanged from Phase 1.
- Saving a `.py` file produces `.validation/results.json` within 3 seconds.
- Parallel-validation benchmark: wall-time delta ≥ 20% faster on a multi-file task.
- End-to-end: asking the agent to build a 5-file Python project with tests completes without the agent ever saying "waiting for tests" or running pytest sequentially in terminal.

### 5. Failure modes and recovery
- **Draft model fails to load ("architecture mismatch" or similar).** → Qwen2.5-Coder-0.5B and Qwen3.5-27B must share tokenizer/vocab for spec decode. If they don't, switch to Qwen3-family 0.5B draft (lookup: confirm available draft model matching Qwen3.5-27B's tokenizer — possibly the guide's advice is now stale and a Qwen3 draft is required).
- **Spec-decode throughput is neutral or negative.** → Acceptance rate < 30% means the draft isn't predicting well. Check log for acceptance stats; lower `--draft-max` to 8; if still bad, disable and accept native rate.
- **Validation runner fires too often / thrashes CPU.** → Increase debounce to 1500 ms; ignore `__pycache__/` and `.venv/` via watchdog patterns.
- **`.validation/results.json` write races.** → Write to `.validation/results.json.tmp` then `os.replace()` — atomic on POSIX.
- **Agent reads stale results.json and "fixes" things that are already fixed.** → Include edit timestamp in results; agent's rule already requires results to be newer than its edit.
- **CPU contention between draft model and validation runners starves llama-server prompt processing.** → `taskset` / `cpuset`: pin draft model to cores 0–3, validation to cores 4–9, leave 10–15 for OS + llama-server coordination.

### 6. Abort criteria
- Spec-decode produces negative throughput after two tuning passes → disable `-md` permanently, document and move on; Phase 3 still ships the validation runner.
- Validation runner causes data races or test-result corruption that misleads the agent → disable, revert to sequential validation, reassess.

### 7. Time budget
Estimated: 4–6 hours. Hard cap: **8 hours**.

---

## Between-phase evaluation

Before advancing from N to N+1, answer all:

1. **Did the Phase-N success checkpoints pass and are they still passing a day later?** (Ephemeral success doesn't count.)
2. **Was any failure mode hit, and is it documented in `docs/phase-notes/`?**
3. **Did a real end-to-end use (not a contrived smoke test) happen in Phase N?** E.g., between Phase 1 and Phase 2, the user built at least one real small project with Roo Code.
4. **What pain point in Phase N most needs addressing — and is the next phase the right place to address it, or has the priority shifted?** (Per the "expect plans to shift" constraint.)
5. **Is the GRUB fallback still intact, the working Ollama backup still in place, and disk headroom still ≥ 30 GB?** (Environmental drift check.)
6. **Are any emergent needs better served by a Phase 4+ capability that should be pulled forward (e.g., `--cram` if slot-save proves persistently flaky)?**

If any of 1, 2, 5 fails: fix before advancing. If 3 fails: use Phase N more before advancing. If 4 or 6 suggests reordering: re-plan.

---

## Files and directories added to the `second-opinion` repo

```
docs/
  implementation-plan.md              ← this document
  phase-notes/                        ← running log per phase
  benchmarks/
    phase3-specdecode.md
    phase3-parallel-validation.md
scripts/
  primary-llama.sh                    ← Phase 1 launcher (stops Ollama, runs llama-server)
  observer-extract.py                 ← Phase 2 post-session extractor
  bench-generation.py                 ← Phase 3 throughput benchmark
  validation-runner.py                ← Phase 3 watchdog + pytest/ruff/mypy
  validation-runner.yaml              ← per-project config for the runner
  README.md                           ← conventions, export paths, how to run
rules-templates/
  project.md
  rules-code-implementation.md
  rules-architect-planning.md
  rules-code-memory.md
memory-bank-template/
  productContext.md
  activeContext.md
  progress.md
  decisionLog.md
  systemPatterns.md
prompts/
  debrief.md                          ← end-of-session debrief prompt
  observer-extraction.md              ← the extraction system prompt
systemd/
  ollama-secondary.service            ← Phase 2 unit (installed to /etc/systemd/system by hand)
  validation-runner.service           ← Phase 3 user-level unit (template)
.observer/
  index.md                            ← project-scope observer index for this repo itself
  refs/                               ← .gitkeep
```

Not added to the repo but created on the system (outside repo):
- `~/.roo/rules/personal.md`
- `~/.observer/index.md` and `~/.observer/refs/`
- `~/models/qwen3.5-27b-text-q4_k_m.gguf`, `~/models/qwen2.5-coder-0.5b-q8_0.gguf`
- `/etc/systemd/system/ollama-secondary.service` (copied from repo)
- `~/second-opinion-backups/pre-phase1/` (backup of pre-existing Ollama state)

---

## Lookup steps flagged for the executing agent

These are items the plan could not resolve without web/package introspection and must be confirmed at execution time, not assumed:

1. Exact Ubuntu 24.04 package names providing `hipcc` and HIP dev headers under current ROCm release.
2. `llama-server`'s `--cram` / `--cache-ram` flag name and default in the built version (relevant for Phase 4 foreshadowing; not blocking for Phases 1–3).
3. HuggingFace repo path for Qwen3.5-27B text-only Q4_K_M GGUF.
4. HuggingFace / Ollama tag for Qwen2.5-Coder-0.5B-Instruct Q8_0 GGUF and confirmation its tokenizer matches Qwen3.5-27B (required for spec decode to work at all).
5. Ollama tag string for Phi-4 Mini 3.8B Q5_K_M on the Ollama registry.
6. Ollama Vulkan activation mechanism on current version — env var vs. separate build.
7. Roo Code conversation export / storage location in the installed VSCodium extension.
8. Roo Code's `custom_modes.yaml` filename/location in the installed version.
9. Current `HSA_OVERRIDE_GFX_VERSION` value(s) that actually work for gfx1010 on ROCm — 10.1.0 first, 10.3.0 as fallback, per guide.
