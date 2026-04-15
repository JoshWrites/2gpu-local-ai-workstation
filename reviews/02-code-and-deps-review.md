# Second Opinion — Code & Dependency Review

**Date:** 2026-04-15
**Scope:** Custom scripts + unit files + Roo settings under `/home/levine/Documents/Repos/Workstation/second-opinion/` and upstream health of every tool we depend on.
**Audience:** future agents reading this cold.

---

## Executive Summary

- **Code quality is generally solid.** All bash scripts use `set -euo pipefail`, comments explain *why*, paths are centralized. No bugs that will break the stack as-is.
- **One latent defect:** `second-opinion-launch.sh` leaks a `journalctl -f` child when yad is absent (no fallback branch cleans up TAIL_PID because it's never set). Currently harmless because yad *is* installed and maintained upstream.
- **One fragile contract:** `primary-llama.sh` hardcodes the binary path `~/src/llama.cpp/llama-b8799/llama-server`. When you bump llama.cpp, this file and `bench-llama-startup.sh`'s phase regexes are both breakage points.
- **llama.cpp b8799 is already stale.** Upstream ships multiple tags per day; b8799 was current for ~5 hours on 2026-04-15. This is *fine* — llama.cpp has no "stable" channel, pin intentionally, upgrade on a schedule, not reactively.
- **Roo Code v3.52.1 is current** (released 2026-04-13, two days old). No action.
- **Unsloth Qwen3-Coder-30B GGUF has not been re-uploaded since 2025-08-08**, and that August release was the one that shipped the jinja tool-calling fix. We are on the correct, final artifact. No pending fix to chase.
- **VSCodium 1.112.01907 (2026-03-20) is current.** `--user-data-dir` / `--extensions-dir` remain supported; no deprecations.
- **yad is alive** — commits as recent as 2026-04-15. Not a dead dep.
- **Qdrant (Phase 2) healthy** — v1.17.1 on 2025-03-27 plus ongoing work; safe to plan against.
- **Biggest practical risk:** the Roo settings file pins `openAiModelId` to the GGUF filename and `contextWindow: 65536`, duplicating truth that also lives in `primary-llama.sh` (`-c 65536`). Drift between these two will silently truncate context.

---

## Code Findings

### `scripts/primary-llama.sh` (35 lines)

**Severity: medium**
- **L25 — hardcoded versioned binary path.** `~/src/llama.cpp/llama-b8799/llama-server`. Every llama.cpp bump requires editing this file *and* the benchmark script. Consider a `~/src/llama.cpp/current` symlink, with version pin recorded in a `VERSION` file in the repo.
- **L26 — glob-expanded model path** (`*Q4_K_M*.gguf`). Silently breaks if Unsloth ever re-uploads with a renamed file or you drop a second Q4_K_M variant in that directory. Cheap fix: use the exact filename that `bench-llama-startup.sh:23` already hardcodes, so both scripts reference the same literal.

**Severity: low**
- **L7-11 — ollama defensive stop** is correct and matches the 2026-04-15 boot cleanup baseline. Keep.
- **L21-24 — ROCm env vars** are well-commented; gfx1100 override is load-bearing and documented.
- No logging prefix; since stdout/stderr go to journal via the unit, that's fine.

### `scripts/codium-second-opinion.sh` (26 lines)

**Severity: low — all clean.**
- **L8-9** path conventions are inconsistent: `DATA_DIR` under `~/.config/`, `EXT_DIR` under `~/.vscodium-second-opinion/`. Works, but a future agent will wonder why. A one-line comment would save them.
- **L18** — the `--wait` single-arg special case is a load-bearing contract with the systemd unit (`ExecStart=... --wait`). Worth a comment pointing at `codium-second-opinion.service`.

### `scripts/second-opinion-launch.sh` (145 lines)

**Severity: medium**
- **L91-96 — "no yad" branch initializes `TAIL_PID=""` but no `journalctl` was started, so that's fine. However the *whole* splash/health-poll flow assumes yad. If yad is absent you get no progress UI *and* no `SPLASH_FIFO` cleanup is needed — but `L123` calls `rm -f` on `${SPLASH_FIFO:-}` which is unset in that branch; with `set -u` this would trip except the `:-` guards it. Correct but accidentally so. Add an explicit comment.
- **L100-115 — cancel detection by `kill -0 $YAD_PID`.** If yad exits for *any* reason (crash, WM kill, SIGPIPE when the FIFO closes), we treat it as user-cancel and tear llama down. Low probability, but a lost splash shouldn't kill the backend. Consider checking yad's exit code via `wait` instead.
- **L86, L101 — `grep -q '"ok"'`** on `/health`. llama.cpp's `/health` response format has changed twice upstream in the past; if the JSON key ever shifts to `"status":"ok"` vs `"ok":true` this silently fails. Safer: `grep -qE '"(ok|status)"'` or just check HTTP 200 with `curl -fs -o /dev/null`.

**Severity: low**
- **L26-36 — cold/warm thresholds.** Magic numbers with no reference back to the CSV that produced them. A comment like `# derived from bench-results.csv median + 1.5*IQR` would anchor them.
- **L130 — `touch "$BOOT_MARKER"`** happens only on success. If llama starts but codium fails to start, next launch is still treated as cold. Minor.
- **L137-139 — 2s poll on codium liveness.** Fine.

### `scripts/bench-llama-startup.sh` (142 lines)

**Severity: medium**
- **L23, L45 — GGUF path duplicated** between shell var and embedded Python heredoc. Pass it as an env var into the heredoc instead of baking it in twice.
- **L112-117 — phase regexes are brittle.** They match exact llama.cpp log strings (`"ggml_cuda_init: found"`, `"llama_context: constructing llama_context"`, `"llama_kv_cache: size ="`, `"srv    load_model: initializing slots"`, `"server is listening"`). Upstream log strings have rotated ~3× across 2025. When you bump llama.cpp, *first* run this script once, then fix any columns that show `?`. Worth documenting at the top.

**Severity: low**
- **L41-51 — posix_fadvise DONTNEED** for cache eviction is correct and nicer than `drop_caches` (no sudo). Good pattern, worth keeping.
- **L77-84 — the timestamp-prefix Python wrapper** is clever; a plain `ts` (moreutils) would be one external dep but more obvious. Either way.

### `scripts/install-roo-modes.sh` (54 lines)

**Severity: low — clean.**
- **L9 — hardcoded `rooveterinaryinc.roo-cline` extension directory name.** This is the historical publisher ID; Roo is still shipping under this slug as of v3.52.1. If they ever rename, this script silently writes to a stale directory. Worth an `if [[ ! -d ... ]]` guard with a clear error.
- **L18 — installs PyYAML on the fly.** Fine for a personal tool; a future agent should know this is intentional, not missing bootstrap.

### `~/.config/systemd/user/llama-second-opinion.service`

- Clean. `KillSignal=SIGTERM` + `TimeoutStopSec=10` is correct (llama-server flushes cleanly on SIGTERM).
- No `WantedBy=` is deliberate and documented. Good.

### `~/.config/systemd/user/codium-second-opinion.service`

- `Requires=` + `BindsTo=` + `After=` is the right trio. When llama dies, codium is pulled with it; when codium exits cleanly, the launcher script's `while is-active` loop notices and stops llama.
- **No `Type=notify`** — codium doesn't sd_notify, so `Type=simple` with `--wait` is the pragmatic choice. Document that.

### `~/.local/share/applications/codium-second-opinion.desktop`

- Good: `Actions=editor-only` provides an escape hatch (right-click launcher → run codium without llama). Keep.
- `StartupWMClass=VSCodium-second-opinion` is correct only if codium is launched with a matching app-id. If the taskbar grouping looks wrong, this is why.

### `configs/roo-code-settings.json`

**Severity: medium**
- **L8 — `openAiModelId` is the GGUF filename.** llama-server accepts anything here; the ID is cosmetic for this backend. Fine, but don't mistake it for real config.
- **L13 — `contextWindow: 65536`** must match `primary-llama.sh:28` (`-c 65536`). They currently agree. A future agent editing one may not edit the other. Worth a comment in both files pointing at the other.
- **L38-61 — `allowedCommands`** is permissive (`rm` absent, good; `mkdir`/`touch` present). `alwaysAllowExecute: true` (L208) overrides the allowlist in practice for agentic runs — the allowlist becomes advisory. If you want the allowlist to actually gate, flip `alwaysAllowExecute` to false.
- **L202 — `maxReadFileLine: -1`** means "unlimited". Combined with `alwaysAllowReadOnly: true`, a runaway agent can pull a multi-GB log into context. Consider a cap (e.g., 5000) once you're done experimenting.

### Consistency across scripts

- `set -euo pipefail`: all 5 scripts. Good.
- Comment style: all 5 use `# ` block comments at top explaining intent. Good.
- Logging: none standardized — half use `echo`, `second-opinion-launch.sh` uses `notify-send`. Acceptable for their different roles.
- Error exit codes: uniform `exit 1`. Good.

---

## Dependency Findings

### llama.cpp (pinned: b8799)

- **Cadence:** ~10 tags/day. b8802 was latest at 16:36 UTC on 2026-04-15; b8799 was shipped 11:02 UTC the same day. Effectively "current" in calendar terms, three tags behind in absolute terms.
- **Open issues relevant to us:**
  - [#19004 — Qwen3-Coder template parsing error when tools enabled](https://github.com/ggml-org/llama.cpp/issues/19004) — fixed upstream by the Unsloth August 2025 template; we already run `--jinja` against the fixed GGUF. Non-blocking.
  - [#19872 — "Template supports tool calls but does not natively describe tools"](https://github.com/ggml-org/llama.cpp/issues/19872) — warning-level; does not prevent tool use.
- **Recommendation:** pin intentionally. Bump quarterly unless a CVE or a Qwen-specific fix lands. Add `b8799` to a `VERSIONS.md` in the repo root.
- **Alternatives worth knowing:** [ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) (fork, faster CPU quants, smaller ROCm focus); not worth switching.

### Qwen3-Coder-30B-A3B-Instruct GGUF (Unsloth)

- **Repo:** [unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF)
- **Last upload:** 2025-08-08 (`imatrix_unsloth.gguf`); the main weight upload batch was 2025-08-05.
- **Known fix shipped:** [discussion #10 — "New Chat Template + Tool Calling Fixes as of 05 Aug, 2025"](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/discussions/10). This is the reason we use `--jinja`. We are on the corrected artifact.
- **ROCm-specific issues:** none reported that affect Q4_K_M on gfx1100.
- **Recommendation:** no action. Unsloth has moved on to `Qwen3-Coder-Next` (separate model family); watch that repo if you want a successor, but the 30B-A3B is a finalized deliverable.

### Roo Code (pinned: v3.52.1)

- **Latest:** v3.52.1 (2026-04-13). We are current as of two days ago.
- **Cadence:** ~weekly minors, daily CLI patches.
- **Relevant open issues:**
  - [#4962 — OpenAI-Compatible embedding settings not persisting across profiles](https://github.com/RooCodeInc/Roo-Code/issues/4962) — only affects codebase-indexing, which we haven't enabled.
  - [#5842 — Save fails for OpenAI-Compatible embedder](https://github.com/RooCodeInc/Roo-Code/issues/5842) — same scope.
  - [#12042 — OpenAI-compatible forces temperature=0 when UI temp is unset](https://github.com/RooCodeInc/Roo-Code/issues/12042) — **this affects us.** If you notice deterministic / too-rigid outputs, set a custom temperature in the profile. Workaround, not blocker.
- **`autoImportSettingsPath`:** no open issues; the feature is stable. Confirm our launcher's isolated user-data-dir picks it up via VSCodium settings rather than this flag (we use neither right now — settings land via `configs/roo-code-settings.json` import).
- **Recommendation:** stay current; Roo moves fast.

### VSCodium (system package)

- **Latest:** 1.112.01907 (2026-03-20).
- **`--user-data-dir` / `--extensions-dir`:** still supported, no deprecation signals. These flags come from upstream VS Code and are effectively permanent.
- **Recommendation:** no action.

### Qdrant (Phase 2, not deployed)

- **Latest:** v1.17.1 (2025-03-27), plus ongoing fixes.
- **Active, well-funded, correct choice for Phase 2.** No alternatives worth swapping in (Chroma is lighter but less featured; Weaviate is heavier).

### yad (splash dialog)

- **Active.** Commits as recent as 2026-04-15. Maintainer v1cont is responsive.
- **Alternatives if yad ever dies:** `zenity` (GNOME-official, simpler), `kdialog` (Qt), or a small Python+tkinter helper. None worth switching to pre-emptively.

### Unsloth (publisher)

- **Active.** `danielhanchen` + `shimmyshimmer` ship GGUFs within days of upstream weight releases. Their release cadence for Qwen3-Coder specifically ended in August 2025 once the model line stabilized.

---

## Recommendations (prioritized)

### Safety
1. **Flip `alwaysAllowExecute` to false** in `configs/roo-code-settings.json:208` once experimentation is over, so `allowedCommands` actually gates.
2. **Cap `maxReadFileLine`** (L202) to e.g. 5000; unlimited + auto-approve read is a context-bomb vector.

### Correctness
3. **Replace the `*Q4_K_M*.gguf` glob** in `primary-llama.sh:26` with the exact filename from `bench-llama-startup.sh:23`.
4. **Harden `/health` check** in `second-opinion-launch.sh:86,101` against response-format drift; prefer `curl -fs -o /dev/null http://127.0.0.1:11434/health`.
5. **Detect yad-crash vs user-cancel** via `wait` + exit code rather than `kill -0`.

### Clarity
6. **Add a `VERSIONS.md`** at repo root pinning: `llama.cpp=b8799`, `qwen3-coder=unsloth/...-Q4_K_M (2025-08-05)`, `roo-code=3.52.1`, `vscodium=1.112.01907`. One file to check before upgrades.
7. **Symlink `~/src/llama.cpp/current -> llama-b8799/`** and use the symlink in `primary-llama.sh:25`. Version lives in `VERSIONS.md`, not in the path.
8. **Cross-link the context-window contract** with a comment in both `primary-llama.sh:28` and `configs/roo-code-settings.json` (L13) — "keep these in sync."
9. **Document phase-regex brittleness** at the top of `bench-llama-startup.sh` — first thing to check after a llama.cpp bump.

### Nice-to-have
10. Consider `zenity` as a fallback when yad is absent, so the "no splash" path in `second-opinion-launch.sh` still gets progress feedback.
11. Move `openAiModelId` to a cosmetic string like `"qwen3-coder-30b-local"` so the filename isn't embedded in Roo's config (decouples from GGUF rename).

---

## Sources

- [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases) — b8802 latest 2026-04-15
- [llama.cpp #19004 — Qwen3-Coder jinja template](https://github.com/ggml-org/llama.cpp/issues/19004)
- [llama.cpp #19872 — Template tool-call warning](https://github.com/ggml-org/llama.cpp/issues/19872)
- [Unsloth Qwen3-Coder GGUF commits](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/commits/main) — last 2025-08-08
- [Unsloth discussion #10 — Aug 2025 template fix](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/discussions/10)
- [Roo Code releases](https://github.com/RooCodeInc/Roo-Code/releases) — v3.52.1 2026-04-13
- [Roo Code #12042 — OpenAI-compat temp=0 bug](https://github.com/RooCodeInc/Roo-Code/issues/12042)
- [Roo Code #4962 — embedding settings not persisting](https://github.com/RooCodeInc/Roo-Code/issues/4962)
- [VSCodium releases](https://github.com/VSCodium/vscodium/releases) — 1.112.01907 2026-03-20
- [Qdrant releases](https://github.com/qdrant/qdrant/releases) — v1.17.1 2025-03-27
- [yad commits](https://github.com/v1cont/yad/commits/master) — active through 2026-04-15
