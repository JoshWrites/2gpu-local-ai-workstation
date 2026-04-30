# Tries and takeaways

A running log of meaningful experiments across the workstation's local-AI stack, and what was learned. Ordered newest-first.

Each entry has the same shape:
- **What we tried** (the concrete setup / prompt)
- **What we measured** (numbers, not impressions)
- **What it tells us** (the learning that applies beyond this one run)
- **What to do next** (if anything; often "nothing, just know this")

The goal is to avoid re-learning the same things every few weeks. When designing, consult this log first.

---

## 2026-04-29 — Local edit prediction on the 5700 XT: Qwen2.5-Coder-3B as a third co-resident sidecar

### What we tried

Replace Zed's hosted Zeta edit-prediction with a local OpenAI-compatible endpoint on the 5700 XT, running alongside the existing two sidecars (llama-secondary :11435, llama-embed :11437). Constraint: no swap-in design, no llama-swap orchestration, no Library code changes — coder must fit co-resident under sustained load.

Three experiments before deploying:
- **E1 — VRAM headroom audit.** Both existing sidecars warm; 10 samples idle, 10 under synthetic 16-batch embed load. Measured used / free / total via `rocm-smi --showmeminfo vram --json`.
- **E2 — Cold-load times for Qwen2.5-Coder Vulkan.** Stopped both production sidecars, launched llama-server on each of {1.5B, 3B, 7B} Q4_K_M three times, timed process-start → first `/v1/models 200`. Probe inference for tok/s.
- **E3 — 2-hour stability soak.** 3B co-resident with both sidecars; edit-prediction request every 2s (200-tok prefix → 60-tok completion), embed batch every 30s, VRAM sample every 60s, dmesg diff before/after.

### What we measured

**E1 — VRAM:** 8.57 GB total, 5.72 GB used by Qwen3-4B + multilingual-e5-large + KV caches + driver overhead, **2.85 GB free**. No movement under load (KV caches pre-allocated).

**E2 — Cold-load + throughput on 5700 XT (Vulkan, page-cache-warm):**
| Model | Load time | tok/s (chat) | tok/s (completion) |
|---|---|---|---|
| Qwen2.5-Coder-1.5B Q4_K_M | ~1.03 s | 150 | — |
| Qwen2.5-Coder-3B Q4_K_M  | ~1.52 s | 99  | 121 |
| Qwen2.5-Coder-7B Q4_K_M  | ~2.62 s | 57  | — |

Run-to-run variance under 30 ms on loads, sub-1% on tok/s.

**E3 — 2-hour soak with 3B co-resident:** 3,600 / 3,600 edit-prediction requests OK, 240 / 240 embed requests OK. **Zero failures.** Edit p50 / p95 = 777 ms / 814 ms. Embed p50 / p95 = 388 ms / 583 ms. VRAM start = end = max = 8.12 GB; delta over 2 hours = +0 MB. Zero new GPU-relevant dmesg lines (no SDMA fault, no ring reset, no GPU hang). One stderr "error" was llama.cpp's auto-fit probe message — benign, model loaded normally.

### What it tells us

1. **gfx1010 + Vulkan is production-grade for sustained inference**, at least on Qwen-family shapes. The whisper.cpp #3611 SDMA crash class did not surface in 3,600 requests across 2 hours of co-tenant load. Worth knowing for any future workload sizing on this card — it is *not* a "research only, expect crashes" environment if you stay on Vulkan + llama.cpp.

2. **The 5700 XT can host three concurrent llama-server processes if total VRAM stays under ~95% of card capacity**. Steady-state was 8.12 / 8.57 GB (95%) for a sustained 2 hours with no transient spikes. Vulkan does not appear to need significant headroom beyond what the model + KV claims explicitly. This is a *generous* envelope vs. our prior assumption that the card was full at two sidecars.

3. **Cold-load on Vulkan is ~1 sec per GB of weights**, page-cache-warm. 1.5B = 1.0 s, 3B = 1.5 s, 7B = 2.6 s. Useful for any future swap-in design — the latency cost of evicting one model and loading another is predictable and small enough to amortize behind any non-keystroke-driven workload.

4. **`/v1/completions` is faster than `/v1/chat/completions` on the same model and prompt size** (121 vs 99 tok/s for 3B), because there's no chat-template wrap. Worth knowing when a workload can pick either endpoint.

5. **`open_ai_compatible_api` in Zed targets `/v1/completions`**, not chat. Our entire E2/E3 throughput was measured on chat — the real-Zed numbers are higher than the soak suggested.

### What to do next

- **E5 (subjective quality eyeball, 3B vs 7B)** is the only remaining gate. Use 3B for normal editing for a few days; if next-edit prediction quality feels weak vs. hosted Zeta-7B's flagship behavior, the upgrade path is Shape B (sole-resident 7B with eviction-driven embed/summarize). 7B-as-third-tenant won't fit; numbers above prove that.
- **Consider an `ExecStartPost` healthcheck on each llama-server unit** that asserts the right device pinning held (e.g., `rocm-smi --showpids` filter). Today the trio relies entirely on the systemd unit's `--device VulkanN` flag taking effect; if a future llama.cpp build silently changes device-flag semantics, services would migrate to GPU 0 and contention with the chat model would be the only signal. Not blocking; worth adding before next major llama.cpp upgrade.
- **Aya-8B summarizer swap is now strictly more constrained** — the third tenant takes ~2 GB. Update the Library multilingual plan accordingly.

### References

- Bench scripts and CSVs: `Library/bench/e1-vram-headroom.sh`, `e2-cold-load-times.sh`, `e3-vulkan-soak.sh`, `vram-baseline-5700xt.csv`, `coder-load-times-5700xt.csv`, `e3-summary.txt`
- Research → spec doc: `Library/docs/edit-prediction-on-secondary-research.md`
- Deployed unit: `/etc/systemd/system/llama-coder.service`
- Lifecycle hooks: `Workstation/second-opinion/scripts/second-opinion-launch.sh` (LLAMA_UNITS array), `/usr/local/bin/llama-shutdown` (UNITS array)
- Ports registry: `Workstation/docs/ports-registry.md` row for :11438

---

## 2026-04-23 — Multi-user opencode: anny session standup, permission-classifier pivot, polite shutdown

### What we tried

Build out a workstation→laptop opencode session shape for anny (wife), running alongside levine's existing session. Goals stated at start:

1. Let anny run opencode on the workstation, operating on her laptop's filesystem (so performance reflects her real hardware)
2. Every file read/edit and command execution must target her laptop, not the workstation
3. Make destructive commands harder to approve accidentally (cat-on-keyboard threat)
4. Scale to two users sharing GPU services without manual "is she working?" checks

Touched many pieces. Notable path-switches and their reasons:

1. **SSH plumbing both directions** (anny's laptop → workstation for the session, workstation → anny's laptop for reach-back/SSHFS)
2. **Pi-hole DNS cleanup**: ghost `dhcp-host` entry for `josh-s-workstation` tied to retired MAC; `/etc/profile` had typo'd `$HOME/usr/bin` injected into every user's PATH; NetworkManager profile was manual IP instead of DHCP
3. **`/etc/fuse.conf` `user_allow_other`** enabled for SSHFS `allow_other` flag
4. **UID mismatch** between laptop-anny (UID 1000) and workstation-anny (UID 1003) breaking SSHFS `default_permissions`; fixed with `idmap=user` instead
5. **Permission-classifier plugin experiment** (opencode plugin via `tool.execute.before`): classified bash commands into read/write/remove tiers with SSH-prefix stripping; remove-tier throws error + routes through a new `confirm_destructive` MCP that requires a typed phrase (`yes <verb> <identifier>`). **Worked end-to-end on levine's session** — read-tier auto-allow, write-tier pass-through to opencode's native ask dialog, remove-tier throw → GLM asks for phrase → MCP verifies + executes
6. **Reverted** the plugin approach because the `tool.execute.before` hook can't auto-allow (only block); opencode.json ruleset still needs to handle read-tier friction. Research confirmed `permission.ask` hook is declared but never fires (upstream sst/opencode#7006). Kept the classifier logic + conventions doc; reverted the live integration
7. **llama-* services migrated from user scope to system scope** so anny can start them independently. Polkit rule grants levine + anny no-password access to those specific services
8. **`llama-status` and `llama-shutdown`** utilities written to coordinate shared service state without refcount complexity — `llama-shutdown` polls connection count, refuses to stop if anyone's connected, waits 30s grace before stopping
9. **`opencode-session.sh` and `work-opencode-launch`** updated to use polkit-enabled `systemctl start` and `llama-shutdown` for polite teardown

### What we measured

- **Permission classifier:** 40 unit tests + 66 JS smoke tests + 13 hook tests all passing. Live end-to-end remove-tier flow verified: `rm` on `/tmp/nonexistent` → plugin blocked → GLM asked for `yes rm nonexistent` → user typed → MCP executed. Cat-on-keyboard threat genuinely neutralized.
- **SSHFS laziness:** mounts her whole home but file bytes only transfer on actual reads. Directory listings fetch over the LAN in <10ms.
- **Service startup latency:** `llama-primary` takes 7-10s from `systemctl start` to HTTP-ready. Load tensors (4s), construct context + KV cache (1-2s), bind HTTP port.
- **Polkit activation:** instant. No daemon reload needed, rules hot-reload.
- **UID projection:** without `idmap=user`, `default_permissions` blocked traversal into the mount for workstation-anny even though the files are hers on the laptop side. With `idmap=user`, mount appears as local-anny owned.

### What it tells us

1. **The native opencode hook system is half-built.** `permission.ask` is the right-shaped hook but doesn't dispatch (upstream bug). `tool.execute.before` fires but can only block, not promote. Until one is fixed or we bypass both (safe_bash MCP — see `memory/project_safe_bash_todo.md`), permission-tiering via plugin is a sidegrade, not an upgrade, vs. static opencode.json ruleset curation.

2. **Two-user opencode on one workstation is viable with polkit + polite shutdown.** No refcount file, no shared lock — just "check connection count on stop request, refuse if nonzero." Works because both users are friendly and neither wants to nuke the other's session. The shape wouldn't scale to untrusted users, but it doesn't need to.

3. **SSHFS `idmap=user` is essential on any multi-user-hosted setup where UIDs don't match.** The `default_permissions` flag (which sounds safe) actively blocks the mounting user from traversing their own mount. `idmap=user` or skipping `default_permissions` are the real fixes; we chose `idmap=user` since it preserves the permission model for inter-user visibility.

4. **The permission classifier's core value is transport-invariant.** `ssh laptop -- rm -rf /foo` stripping to `rm -rf /foo` during classification is the right abstraction — it generalizes across SSH targets without enumerating every `ssh <host> ...` pattern. Salvage the classifier regex when safe_bash gets built.

5. **"Diagnose before destroy" saved us multiple times today:** (a) CT 100 restore agent caught that pre-existing GPU stack pre-dated v2 testing, didn't purge Jellyfin's hwaccel; (b) migration script caught system-scope smoke test failure (too-short `sleep 5` during KV cache alloc), didn't delete user-scope copies before verifying; (c) `work-opencode-launch` failed gracefully on UID mismatch, didn't proceed with a broken mount.

### What to do next

**Immediate (today-this-week):**
- **WoL (wake-on-lan) from anny's laptop** before SSH connect, so she can launch when workstation is asleep. Needs BIOS check + ethtool persistence + `wakeonlan` on her laptop + a small wrapper script that sends magic packet and polls port 22. Flagged earlier, not yet built.
- **Test anny's flow end-to-end with workstation asleep** — verify WoL → reach-back SSH → work-opencode-launch → mount → session start happens smoothly.
- **Her laptop's new alias is `work-opencode`** via `ssh -t anny@levine-positron /home/anny/.local/bin/work-opencode-launch`. Set during session. Absolute path avoids non-interactive SSH PATH issues.

**Medium-term (when current approach bites):**
- **`safe_bash` MCP** as the permanent replacement for built-in bash — see `memory/project_safe_bash_todo.md`. Scripted-CPU (no LLM), folded into `confirm_destructive.py`, includes SSH-prefix enforcement for remote-exec sessions. Build when V1 (AGENTS.md-trust) proves insufficient.
- **Refcount upgrade to `llama-shutdown`** if connection-count heuristic produces false positives (e.g., idle-between-turns sessions briefly having 0 connections). Not observed yet.

**Long-term:**
- **Auto-timeout shutdown**: if services idle for N minutes with no connections, stop them automatically. Good for "nobody remembered to llama-shutdown" case. Simple systemd timer calling `llama-shutdown` periodically.

### Session references

- Migration script and backup: `/tmp/migrate-llama-services.sh`, `~/llama-units-backup-20260423-194651/`
- Polkit rule: `/etc/polkit-1/rules.d/10-llama-services.rules`
- Utility scripts: `/usr/local/bin/llama-status`, `/usr/local/bin/llama-shutdown`
- Anny's launcher: `/home/anny/.local/bin/work-opencode-launch`
- Anny's opencode config: `/home/anny/.config/opencode/opencode.json`, `/home/anny/.config/opencode/AGENTS.md`
- Classifier plugin (not loaded, preserved for safe_bash port): `~/Documents/Repos/Workstation/second-opinion/opencode-plugins/permission-classifier/`
- MCP (not registered, preserved): `~/Documents/Repos/local-mcp-servers/confirm_destructive.py`
- Conventions doc: `~/Documents/Repos/Workstation/docs/opencode-conventions.md`
- TODOs logged: `memory/project_safe_bash_todo.md`, `memory/project_librarian_and_perms_todos.md`

---

## 2026-04-23 (late) — anny's MCPs independent via git-based sync; cwd-aware launch; longer MCP timeouts

### What we tried

Addressed the two remaining bugs in anny's `work-opencode` flow from the earlier two-user standup:

1. **Bug 1 (cwd lost):** launching `work-opencode` from a project directory on her laptop landed the opencode session at `/home/anny/laptop-home/` (mount root) regardless of where she was. GLM then did expensive filesystem searches looking for the project she'd asked about.

2. **Bug 2 (MCP EACCES):** both distiller and librarian MCPs failed at session-start with `EACCES: posix_spawn '/home/levine/.local/bin/uv'`. Her user couldn't traverse levine's home to reach the shared `uv` binary.

Took the bug 2 diagnosis further: even if `uv` were accessible, anny still couldn't read the MCP project dirs (`/home/levine/Documents/Repos/local-mcp-servers/` and `.../library_and_patron/`) because levine's home is mode 750. Three options considered:

- **Open `/home/levine` to 755** — simple but widens exposure
- **Copy MCPs to her user space** — causes drift between his dev versions and her stable copies
- **Git-based sync** — her clones from remotes, pulls updates when he pushes to main

Chose git-based sync. Built a `phase1-anny-unblock.sh` script implementing it end-to-end: commit+push local-mcp-servers (no remote before; created private `JoshWrites/local-mcp-servers`), push library_and_patron main (fast-forwarded from `v2-document-retrieval`), clone both as anny using her `gh` token (HTTPS via `gh repo clone`), `uv sync` per clone, update her opencode.json paths, revert `/home/levine` to 750.

Also wrote a planning doc at `docs/restructure-plan.md` capturing the full intended layout (Workstation out of Repos/, per-MCP repos under local-mcp-servers/, symlinks at Repos/ level) with phase 1 marked done, phases 2-5 deferred.

### What we measured

- **Script idempotency:** first run failed at clone step because `uv` wasn't installed at `/usr/local/bin/uv`. Fixed, re-ran; failed again at clone step because `[[ -d "$target/.git" ]]` check evaluated false from levine's shell (can't stat into `/home/anny` at mode 750). Fixed to `sudo -u anny test -d`, re-ran; succeeded end-to-end.
- **Permission model validated:** anny can now reach GitHub via her stored `gh` token, clone private repos she's a collaborator on, build per-user venvs, and access everything through her own clones. `/home/levine` back to 750 (private).
- **Cwd fix:** launcher now accepts a laptop-native absolute path as `$1`, translates `/home/anny/<rest>` to `$MOUNT_POINT/<rest>` via string prefix substitution. Her alias became a function (not alias) to capture `$PWD` through SSH. Required a `unalias work-opencode` before sourcing the updated `.bashrc` — bash expands existing aliases during function-definition parsing, causing a misleading syntax error otherwise.
- **MCP timeouts bumped:** distiller 90s → 180s, librarian 60s → 120s. Accommodates cold-start first-call latency (uv cache refresh, Python import, card-2 model warmup).

### What it tells us

1. **Git-as-sync is the right primitive for shared-infra MCPs between friendly users.** Anny gets her own copies that she pulls updates to on demand. Levine's dev branches don't affect her until he chooses to push them to main. Boundary is clean, no filesystem permission dance required, no drift because main is the source of truth for both. Cost: `gh auth login` per machine, collaborator invite per repo, one-time SSH key setup — we'd already done the auth setup for gh, so actual overhead was minimal.

2. **The `[[ -d /home/other-user/... ]]` gotcha matters in multi-user scripts.** A bash script running as user A checking for files under user B's 750-home returns silently false. No error, no explanation, just "path not found" where a path exists. Fix: do the permission-sensitive check via `sudo -u <owner>`. Low-friction addition, high-value clarity.

3. **`gh repo clone` beats hand-rolled HTTPS auth for private repos.** Uses the stored gh token transparently. No token-in-URL, no ~/.netrc, no PAT rotation. The only prerequisite is `gh auth login` on the target machine. Pairs well with the collaborator-invite model — she gets pull access via her GitHub account, not a shared credential.

4. **`work-opencode()` function vs alias:** functions let you pass `$PWD` through the SSH boundary, aliases can't do shell math. The migration (`unalias` then define function) needs an explicit unalias because of bash's alias-expansion-during-parse behavior. Easy to miss in docs.

5. **Path translation between machines is mechanical when home directories have the same name.** Both machines' anny has `/home/anny` as her home. The launcher's `/home/anny/... → $MOUNT_POINT/...` rewrite is a trivial prefix substitution. If we ever have a user whose laptop and workstation usernames differ, this would need config, not hardcoded paths.

### What to do next

**Immediate:**
- **WoL launcher variant for anny** — when workstation is asleep, her `work-opencode` call hangs until SSH timeout. Logged as `memory/project_wol_todo.md`. Fix = wrap her function to send magic packet + poll port 22 before SSH.

**Medium-term:**
- **Phases 2-5 of the restructure plan** (docs/restructure-plan.md). Specifically: move Workstation out of Repos/, nest library_and_patron under local-mcp-servers/, split local-mcp-servers into per-MCP repos via clone-and-delete.
- **Fix the LSP "access denied" on secondary GPU** in anny's session if it's still happening — we weren't sure whether that was resolved by the git-based fix or still pending.

**Long-term:**
- **safe_bash MCP** remains the right permanent solution for permission classification + SSH-prefix enforcement. Still paused pending evidence of AGENTS.md-trust insufficiency.

### Session references

- Phase 1 script: `/tmp/phase1-anny-unblock.sh`
- Restructure plan: `~/Documents/Repos/Workstation/docs/restructure-plan.md`
- Anny's clones: `/home/anny/Documents/Repos/{local-mcp-servers,library_and_patron}/`
- GitHub remotes: `JoshWrites/local-mcp-servers` (new, private), `JoshWrites/library_and_patron` (existing, main now = V2)
- Anny's `~/.bashrc` function: `work-opencode() { ssh -t anny@levine-positron /home/anny/.local/bin/work-opencode-launch "$PWD"; }`
- Updated launcher (with cwd translation): `/home/anny/.local/bin/work-opencode-launch`
- TODOs added: `memory/project_wol_todo.md`

---

## 2026-04-23 — Multi-user opencode: anny session standup, permission-classifier pivot, polite shutdown

### What we tried

Walked the decision tree from yesterday's brainstorm (`library_and_patron/docs/brainstorm-2026-04-22-offload-and-profiles.md`, Tier-1 item #1 — MoE expert offload for a bigger primary). Pulled Qwen3-Next-80B-A3B-Instruct UD-Q4_K_XL (~46 GB, Unsloth Dynamic Quant), built sibling systemd units with full-offload `--cpu-moe`, benched three runtimes against the GLM baseline:

1. **Upstream llama.cpp b8799** (existing Vulkan build, `/home/levine/src/llama.cpp/llama-b8799-vulkan/`)
2. **ktransformers** — desk-researched only; didn't build
3. **ik_llama.cpp** — cloned, built with `GGML_VULKAN=ON` (needed the `glslc` apt package, `glslang-tools` ships only `glslangValidator` which cmake doesn't accept as substitute)

Same bench prompt across runtimes: `"In the security-plan.md file, how do I control server access?"`, `max_tokens=600`, direct `/v1/chat/completions` (no agent framework). Model can't read the file — we're measuring throughput + coherence, not correctness.

### What we measured

| Runtime | Prefill tok/s | Decode tok/s | Result |
|---|---|---|---|
| **upstream llama.cpp b8799, `--cpu-moe`** | **43.9** | **18.8** | 600 tokens, coherent security-plan template |
| ktransformers | N/A | N/A | eliminated by research; hardware mismatch |
| **ik_llama.cpp 4433, `--cpu-moe`** | **—** | **—** | **crashed during KV-cache init: `radv/amdgpu: Not enough memory for command submission` → VkDeviceLost** |

**ik_llama crash details:** load succeeded (Vulkan0 buffer 1.39 GB, CPU buffer 42.5 GB). Thrashed disk paging for ~2.5 min mmap'ing 40 GB — RAM peaked at 56 GiB used + full 8 GiB swap against a 62 GiB total envelope with ~17 GiB already pinned by desktop/tmpfs. KV-cache alloc then failed on the GPU side. Systemd: `status=6/ABRT, 18.6 GB memory peak, 836 MB swap peak, 44.7s CPU`. GLM cleanly restored after. The failure was pure memory pressure, not the ik_llama README's flagged `_XL`/split-graph risks — it just wanted more host headroom at init than upstream for the same flags, and our envelope couldn't give it. ik_llama init flags observed in journal: `fused_moe=1, fused_up_gate=1, fused_mmad=1, graph_reuse=1` — features upstream lacks, which probably inflate command-buffer staging.

**ktransformers eliminated without building**, via thorough research task (see `Workstation/docs/ktransformers-eval-2026-04-23.md` if that gets saved, or relevant GitHub issues: kvcache-ai/ktransformers#423 open 14 months, #1178 Marlin on ROCm broken, #1514/#1826 Qwen3-Next FP8 path broken). Three killers for our hardware: (1) no AMX on Zen 3 — their headline kernels unreachable, (2) Marlin GPU kernels disabled on ROCm with a documented suboptimal fallback, (3) their Qwen3-Next tutorial wants ~320 GB RAM (BF16), no documented GGUF path through their injection rule. Reality check: a user on i5-12600K + RTX 4070 + **DDR5-6000** gets 40 tok/s on comparable Qwen3-Coder-Next with plain llama.cpp `--cpu-moe`. We got 47% of that on DDR4-3200 — which matches the memory-bandwidth ratio almost exactly (DDR4-3200 is ~55% of DDR5-6000).

### What it tells us

1. **Upstream llama.cpp with `--cpu-moe` is the correct MoE path on this hardware.** b8799 handles Qwen3-Next cleanly at 64K ctx, flash-attn on. No other runtime bench-tested was even viable — ktransformers wrong hardware fit, ik_llama OOMs.

2. **DDR4-3200 memory bandwidth is the binding constraint on MoE decode, not the runtime.** No software switch fixes it. Runtime swaps can move the decode number a few tok/s in either direction, but the ceiling is the bus. The same Qwen3-Next stack on Zen 4/5 + DDR5 would likely hit 30-40 tok/s on identical flags. This is the clean case for "platform upgrade > software optimization" when decode is limiting.

3. **18.8 tok/s decode is usable for drafting, slow for interactive.** GLM-4.7-Flash fully on-GPU is ~50-70 tok/s for comparison. Qwen3-Next MoE is roughly 3× slower for the capability uplift. Acceptable for ceiling-break turns ("I'm stuck, need deeper reasoning on this specific thing"), not for default flow.

4. **HOBBIT-style dynamic expert caching has no realistic shortcut today.** No reference implementation published. llama.cpp's attempts (issue #20757, PRs #21609/#21614/#21620) stalled and were closed in April. Issue #21067 (tensor-override prefetch primitive) still open — foundation a future impl could build on. Until that lands, static `--cpu-moe` is the ceiling.

5. **`_XL` Unsloth quants were NOT the ik_llama failure mode.** Model parsed and loaded fine. Worth remembering so we don't avoid `_XL` variants elsewhere without cause.

6. **ik_llama.cpp's Vulkan backend is maintainer-unsupported** per their README (`"do not enter issues related to ROCm, Vulkan, Metal"`). This bench confirms that in practice — the same flags that work upstream break on ik_llama here. ik_llama may still be competitive for CUDA users; we can't benefit without a Nvidia card.

### What to do next

- **Ship upstream MoE as an opencode profile**, not as default. Tab-switchable per-task (per yesterday's brainstorm Q2). Default stays GLM for speed; reach for Qwen3-Next when GLM hits its ceiling. ~30 min to wire.
- **Don't revisit ik_llama or ktransformers** on this stack until hardware changes or upstream status changes (e.g., ik_llama gets official ROCm/Vulkan support, or ktransformers publishes working AMD benchmarks on issue #423).
- **Revisit the whole MoE question after any platform upgrade to Zen 4/5 + DDR5.** At that point re-run the same bench; DDR5 should unlock ~30-40 tok/s decode on the same flags without touching anything else.
- **The 5700 XT as secondary CPU-path offload target** was never tested — it's a hedge if we ever want to run primary GLM + secondary Qwen3-4B + *tertiary* MoE large model simultaneously. Not a near-term experiment.

### Session references

- Bench responses: `/tmp/moe-bench-response.json` (upstream, coherent), `/tmp/ik-smoke-response.json` (ik_llama never got to inference)
- Systemd unit: `~/.config/systemd/user/llama-primary-moe.service` (upstream, kept)
- ik_llama unit + drop-in cleaned up post-bench: removed, not in tree
- Build: `/home/levine/src/ik_llama.cpp/build-vulkan/bin/llama-server` (version 4433, kept for future use if the situation changes)
- Model: `/home/levine/models/qwen3-next-80b-a3b-instruct/Qwen3-Next-80B-A3B-Instruct-UD-Q4_K_XL.gguf` (46 GB, kept)

---

## 2026-04-23 — CT 100 pre-test restore: scope was wrong, minimal purge sufficed

### What we tried

Asked a subagent to "fully restore CT 100 to pre-test state" — assumed the v2 GPU stack test on 2026-04-22 had added significant packages that needed removal. Jellyfin usage OK to interrupt.

### What we measured

- Agent investigated apt history before acting (guardrail saved us).
- Pre-test baseline: CT 100's Nvidia container toolkit + CUDA keyring + LXC passthrough + `daemon.json` with nvidia runtime was installed **2026-02-13**, two months before v2 work. Jellyfin compose declares `runtime: nvidia` as its baseline — **CT 100 has GPU-transcoded since February, not CPU**.
- Actual v2 residue from 2026-04-22: one meta-package (`nvidia-container-runtime`, 3.14.0-1, docs-only) + a failed `nvidia-driver-535` install (no dpkg residue) + a `daemon.json` mtime bump (content functionally identical to Feb toolkit output).
- Minimal purge performed: `dpkg --purge nvidia-container-runtime libnvidia-compute-580 nvidia-kernel-common-580`. Post-purge Jellyfin: `Up 14 hours (healthy)`, HTTP 200 on `/System/Info/Public`, `jellyfin-ffmpeg` reports nvenc/nvdec/cuda still functional.
- **Pre-existing, out-of-scope issue surfaced:** CT 100's `dpkg` is in `iHR` (half-installed) state because the LXC config bind-mounts `/etc/alternatives` read-only from the Proxmox host (needed for GPU passthrough). `dpkg --purge` works (that's how the agent completed); `apt upgrade` will fail on pending dpkg 1.22.6ubuntu6.5 until the mount is addressed.

### What it tells us

1. **Verify pre-test assumptions via apt history before purging.** The v2 work looked more invasive in memory than it was in reality — a failed driver install + a docs meta-package, against what we assumed was a full Nvidia stack addition.
2. **Guardrail "stop and report if state contradicts brief" paid for itself.** Would have broken Jellyfin's GPU transcode if the agent had followed the original brief literally.
3. **CT 100 GPU stack is pre-existing production infra**, documented in `memory/project_ct100_gpu_stack.md` — do not conflate with v2 test residue.

### What to do next

- **Nothing immediate.** State is clean, Jellyfin healthy.
- **Separate TODO:** CT 100's read-only `/etc/alternatives` bind mount blocks `apt upgrade` on the pending dpkg update. Needs a carve-out (maybe a temporary unmount + upgrade + remount during a Jellyfin maintenance window). Not load-bearing until a security update arrives for a package that touches `/etc/alternatives`.

---

## 2026-04-22 — Session close, open threads for next time

Winding down for the night. Captured here so next session picks up clean.

**Shipped:**
- Librarian v2 working, v1 archived under `library_and_patron/archive/v1-code-oriented/`, `v1-code-oriented` tag points at pre-archive commit.
- `mine_file` + `release_file` MCP tools live in opencode via stdio MCP.
- `opencode` shell alias = full preflight + teardown (pkill rogues, start three services, wait for endpoints, stop on exit).
- AGENTS.md + rewritten docstring routes GLM to librarian for question-shaped file access.
- Two-stage stress test passed (card-2 coexistence + full three-way concurrent).
- Verbatim opencode responses preserved at `library_and_patron/docs/opencode-responses-2026-04-22.md`.

**Not pushed anywhere tonight.** Pending remote-exposure decision (see memory `project_remote_exposure_decision_todo.md`).

**Open threads:**
1. **Workstation-root docs not under version control.** Ports registry + tries-and-takeaways live in `~/Documents/Repos/Workstation/docs/` which isn't a git repo. Durability = home backups only until decided.
2. **CT 100 GPU stack still has v2-installed packages** (`nvidia-container-runtime`, `nvidia-driver-cuda`, Docker `daemon.json` edits). Config reverted from backup, packages still sitting there. Decide whether to purge or leave.
3. **Watcher visibility TODO before teeth** — separate memory (`project_watcher_visibility_todo.md`). Opencode plugin API can't host persistent panels; four workaround paths documented.
4. **Adaptive top-K (Design A)** deferred; GLM's iterative-query behavior makes it not-yet-justified.
5. **A/B vs multimodel dispatcher** deferred; passive-offload has evidence it works, dispatcher is hypothesis. Worth running eventually.
6. **Blog post** — separate memory (`project_blog_post_todo.md`). Write after stabilization + A/B, ~3h drafting.

**Known rough spots:**
- Wrapper's `rocm-smi GPU[0]` vs `GPU[1]` mapping assumes current card order. Could break if drivers reorder cards post-reboot.
- Librarian chunker is conservative (400-char target, 500-char cap) — may produce *more* chunks than strictly needed for dense prose. Acceptable tradeoff vs. 512-token overflow, but worth re-tuning if retrieval quality issues appear.
- Opencode's `tool.registry` doesn't log MCP-provided tools; diagnostic greps need to look at permission lines or MCP stderr bridges instead.

---

## 2026-04-22 — Drilldown: iterative mine_file is cheap; GLM exploits it naturally

### What we tried

After the first Librarian-path answer (Run B below, 26% context), user asked: *"You researched top 5. Are there more answers to find in 6-10?"* then *"synthesize that full picture for me."*

Same session, same file, same cached embeddings. No new file read.

### What we measured

- 4 additional `mine_file` calls, all cache-hits (no re-embed; each ~50–100ms of card-2 time):
  - `top_k=10`, query `"access control authentication methods"`
  - `top_k=8`, query `"firewall rules network security authentication"`
  - `top_k=5`, query `"local authentication TOTP break-glass admin"`
  - `top_k=6`, query `"port forwarding rules network segmentation"`
- Post-drilldown context: **37%** (up from 26% — **+11 points for a 5-layer comprehensive synthesis that added Auth0 OIDC flow, firewall architecture, port-forwarding table, network segmentation, and threat-model constraints**).
- Final answer was the most detailed of the session — structurally organized, multi-layered, with specific config file references.

### What it tells us

1. **Iterative querying on cached embeddings is essentially free.** Once the file is in the cache, additional `mine_file` calls with different query phrasings cost ~50–100ms each (similarity ranking only; no re-embed, no re-chunk, no file read). In the `Read`-path, an equivalent drilldown would either re-read the full file (another ~14K tokens) or be stuck with whatever the first read pulled.

2. **GLM adaptively deepens via different queries, not bigger top-K.** Faced with "not enough answer," GLM didn't ask for top-K=20; it asked *different questions*. This is semantically better — different phrasings surface different facets. Caller-driven adaptive retrieval, emergent.

3. **"Second-order win" — context efficiency enables iterative synthesis.** Cheaper per-query cost → more queries per answer → better synthesis. The architecture wasn't designed for this but produced it as a behavior.

4. **11 percentage points for a 5× richer answer is an excellent trade.** Even with drilldown, total consumption (37%) is less than the control (Run A, 46%) for an *inferior* answer.

### What to do next

- **Adaptive top-K on the server (Design A): hold.** Log scores in future runs; only build if we see clear "obvious chunk 6 missed after top-5" cases that GLM's iterative-query pattern doesn't catch.
- **Streaming-deepening (Design B): don't build.** GLM's iterative-query pattern already does it, better, with no protocol complexity.
- Document the drilldown pattern in the AGENTS.md rule if attended operators want the behavior to be reliable (e.g., "when your first mine_file answer feels incomplete, fire a second with a re-phrased query before asking the user").

---

## 2026-04-22 — Librarian vs. Read on `security-plan.md`

### What we tried

Single prompt, copy-pasted verbatim, run against opencode + GLM-4.7-Flash (Q4_K_XL, 7900 XTX, 64K ctx) on the same repo (`~/Documents/Repos/LevineLabsServer1`):

> *"In the security-plan.md file, how do I control server access?"*

**Run A (control, no Librarian):** opencode with `distiller` MCP only, no Librarian registered. AGENTS.md absent. GLM reached for built-in `Read` because `mine_file` wasn't in the tool registry.

**Run B (treatment, Librarian enabled):** opencode with `distiller` + `librarian` MCP. AGENTS.md at `~/.config/opencode/AGENTS.md` instructs GLM to prefer `librarian_mine_file` over `read` for question-shaped file access. `mine_file` docstring rewritten to lead with the routing rule.

### What we measured

| Metric | Run A (Read) | Run B (Librarian) | Δ |
|---|---|---|---|
| Context used after answer | **46%** (≈ 29.4K / 64K) | **26%** (≈ 16.6K / 64K) | **−20 pts / −12.8K tokens** |
| Wall time | 3m 3s | comparable (not measured cleanly) | ≈ same |
| Tool calls | 2 (glob + read) | 4 (mine_file × 3, glob × 1) | +2 |
| Output quality | 7 categories, accurate, general | 5 categories, accurate, with specific Auth0 role names | Librarian richer in specificity |

File under test: `docs/security-plan.md`, 981 lines, 43 KB, ~10.7K tokens.

### What it tells us

1. **Librarian saves ~44% of context on a question-about-a-file**. The baseline (Run A) spent ~14K tokens loading the full file into primary; Run B spent ~1–3K on the 3× top-5 chunk returns combined. The file content was the dominant variable, and it's the variable Librarian controls.

2. **Answer quality didn't degrade — it got sharper.** Because Run B could iterate queries cheaply against the cached embeddings, GLM fired three mine_file calls with different framings (`"how do I control server access"`, `"access control authentication methods"`, `"VPN access requirements authentication"`) and synthesized from all three. Each additional query was ~50ms (cache hit, no re-embed) vs. the cost of a second file read. **This is a second-order win the architecture wasn't designed for but delivered anyway: context efficiency enables cheap iteration, which improves synthesis.**

3. **Tool selection requires explicit guidance.** First attempt (before AGENTS.md + docstring rewrite) had GLM default to `Read` even with Librarian registered. The fix — a single-rule AGENTS.md plus a docstring that explicitly says "PREFER THIS OVER `read`" — flipped the behavior cleanly on the next run. Without the guidance, GLM picks the tool it recognizes from training (`read`), not the unfamiliar but better-fitting MCP tool.

4. **Relative-path fumble is minor but real.** Run B's first mine_file call used `path=security-plan.md` (relative, didn't exist at cwd), fell back to `glob`, then retried with the absolute path successfully. One wasted tool call; no damage. Not worth tuning yet.

### What to do next

- Nothing to build here immediately — the win is real and the architecture works.
- Keep baseline numbers in mind: roughly 20pp context savings per long-file question. Use when deciding whether to tune embedder-side knobs (batch size, chunk size).
- If the relative-path fumble starts costing real time, consider: (a) Librarian resolves relative paths against workspace root + HOME, or (b) AGENTS.md instructs GLM to pass absolute paths.
- Future comparison: run the same control with a file that's 2× larger (security-plan.md is ~10K tokens; something 20K tokens would be a harder test of Librarian's proportional savings).

### Session references

- Control run: opencode session `ses_2493624e1ffemutbWTejnVLNis`, log `/home/levine/.local/share/opencode/log/2026-04-22T200138.log`
- Treatment run: next session after exit; same log dir, timestamp after 20:07:47
