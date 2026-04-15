# Decision log

Decisions with lasting implications. Recency first.

## 2026-04-15 — Phase 2 redirected to embedding server + Qdrant indexing

Original Phase 2 was a post-session observer (Phi-4 Mini on the 5700 XT extracting learnings into `~/.observer/`). Demoted after Phase 1 smoke test showed the real pain was not "forgetting across sessions" — it was Roo burning ~19% of a 32K context on exploratory full-file reads that were silently truncated at 100 lines. Phase 2 now stands up an embedding server on the 5700 XT and wires Roo's built-in Codebase Indexing (Qdrant backend) so the model retrieves relevant chunks instead of reading whole files. Observer pattern is not dead — may return if memory-bank + indexing prove insufficient. Plan rewritten in place; the "why" is in the Phase 2 intro paragraph.

## 2026-04-15 — Roo config managed via `autoImportSettingsPath`, not globalStorage edits

Roo stores provider profiles in VSCode's encrypted `secretStorage` (libsecret/gnome-keyring on Linux), not a plain file. Only supported programmatic path is Roo's export JSON + the `roo-cline.autoImportSettingsPath` setting, which re-imports on every editor start. Repo's `configs/roo-code-settings.json` is the source of truth; isolated VSCodium's `User/settings.json` points at it. Documented in `docs/roo-settings-management.md`.

## 2026-04-15 — Isolated VSCodium via `--user-data-dir`, not a second install

Second install (Insiders/flatpak) adds update burden with no isolation benefit. Built-in Profiles share the extension host. `--user-data-dir` + `--extensions-dir` gives true isolation. Launch via `scripts/codium-second-opinion.sh` + desktop entry "VSCodium (Second Opinion)". Roo Code installed into the isolated instance only; normal VSCodium stays Roo-free.

## 2026-04-15 — GPU pinning via `ROCR_VISIBLE_DEVICES=1` is required

`HSA_OVERRIDE_GFX_VERSION=11.0.0` alone made both GPUs report as gfx1100, and llama.cpp defaulted to device 0 (5700 XT, 8 GB) for an 18 GB model. Pinning to `ROCR_VISIBLE_DEVICES=1` makes ROCm see only the 7900 XTX, which also makes the HSA override truthful.

## Earlier decisions

See `docs/implementation-plan.md` for pre-smoke-test decisions: prebuilt llama.cpp tarball over source build, Qwen3-Coder-30B-A3B over Qwen3.5-27B, VSCodium + Roo over alternatives, Qwen3-0.6B as Phase 3 draft model.
