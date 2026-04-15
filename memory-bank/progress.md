# Progress

## 2026-04-15 — Phase 1 complete

**Stack running end-to-end:**
- llama-server b8799 (prebuilt ROCm 7.2) serving Qwen3-Coder-30B-A3B-Instruct
  Q4_K_M on 127.0.0.1:11434, pinned to 7900 XTX via `ROCR_VISIBLE_DEVICES=1`.
  VRAM footprint ~22.8 / 25.7 GB.
- VSCodium isolated instance at `~/.config/VSCodium-second-opinion/` launched
  via `scripts/codium-second-opinion.sh` + desktop entry "VSCodium (Second
  Opinion)". Roo Code 3.52.1 installed into it only.
- Roo provider config: OpenAI Compatible → `http://127.0.0.1:11434/v1`,
  model `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`. Config lives in
  `configs/roo-code-settings.json`; autoImport wired via
  `roo-cline.autoImportSettingsPath` so the repo is the source of truth.
- Smoke test passed: Roo listed files, created `tests/planet_greeting.sh`,
  made it executable, and ran it producing random planet greetings.

**`-cram` proven** (2026-04-15):
- 9,792-token prompt, identical resend.
- Cold: 22.9s prompt eval. Warm: 22 ms, 9,791 tokens from cache.
- **~1028× speedup on prompt evaluation.**
- Prefix caching is not theoretical — it's the main reason Phase 2's
  embedding-index value has to be evaluated against stable-prefix scenarios,
  not just token counts.

**Key fixes and gotchas captured during Phase 1:**
- `HSA_OVERRIDE_GFX_VERSION=11.0.0` alone made both GPUs report as gfx1100;
  without `ROCR_VISIBLE_DEVICES=1` llama.cpp loaded the 18 GB model onto the
  8 GB 5700 XT. Fix committed in primary-llama.sh.
- `--flash-attn` now requires an explicit `on`/`off` value in b8799.
- Roo stores provider profiles in VSCode's encrypted `secretStorage`, not
  in plaintext files. Only programmatic path is the export JSON +
  `autoImportSettingsPath`. Documented in `docs/roo-settings-management.md`.
- Roo's default `maxReadFileLine: 100` silently truncates — set to `-1`
  in the autoImport settings.
- `.rooignore` added to exclude `.venv/`, `node_modules/`, `models/`, etc.
- Auto-approve toggled on for read, write, execute, mode-switch, subtasks,
  with a bounded `allowedCommands` list. Review periodically.

**Phase 2 direction set (not started):**
- 5700 XT repurposed from "post-session observer" to "embedding server for
  Roo's Codebase Indexing" after the smoke test showed Roo burning ~19% of
  a 32K context on exploratory reads. Old observer design demoted, may
  return later if memory-bank + indexing prove insufficient.
- See `docs/implementation-plan.md` Phase 2 section for the revised steps.

**Outstanding Phase 1 work:**
- Task #4: populate memory-bank files with actual content (stubs currently).
- Task #5: import `.roo/modes/review.yaml` + `spec.yaml` into the isolated
  VSCodium's `custom_modes.yaml`.

**Post-Phase-1 enhancements captured** in `docs/post-phase1-enhancements.md`:
SearxNG MCP for web access (top priority), prompt-injection guardrail,
auto-approve audit cadence, llama-server desktop entry.

## 2026-04-15 — Lifecycle management added (late Phase 1)

**Problem:** earlier flow left llama-server resident (~23 GB on 7900 XTX)
whenever the editor wasn't explicitly killed. Wanted: click desktop entry
→ agent ready; close editor → VRAM released.

**Built:**
- `~/.config/systemd/user/llama-second-opinion.service` (wraps
  `primary-llama.sh`; never enabled, started on demand).
- `~/.config/systemd/user/codium-second-opinion.service`
  (`Requires`+`BindsTo` llama; runs `codium --wait` so systemd blocks
  until window close).
- `scripts/second-opinion-launch.sh` — orchestrator with yad splash
  that tails the llama journal, shows live phase progress, warns on
  threshold breach, then launches the editor and waits.
- Desktop entry updated to point at the launcher; added an
  "Editor only" action for times you don't need the model hot.

**Startup benchmarks captured** (3 cold + 7 warm via
`scripts/bench-llama-startup.sh`). Results committed as
`bench-results.csv`:
- Cold (GGUF evicted from page cache): **~36s**, ±0.65s across 3 runs.
- Warm: **~3.3s**, ±0.02s across 7 runs.
- Tensor load dominates (>95% of total in both states). Post-tensor
  phases are sub-second and deterministic.
- Thresholds in the launcher: cold 55s warn, warm 10s warn — ~50% slack
  above observed max.

**Context bump:** llama-server now runs at `-c 65536` (was 32768). VRAM
at 24.3 / 25.7 GB; ~1.4 GB headroom. Roo's
`providerCustomModelInfo.contextWindow` updated to match.
