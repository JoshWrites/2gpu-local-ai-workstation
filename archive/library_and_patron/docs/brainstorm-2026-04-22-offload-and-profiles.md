# Brainstorm — Model-switcher on card 2? Profiles in opencode? What else can move to CPU/DRAM?

**Context:** late-evening brainstorm at the end of the Librarian V2 session. Three questions you asked before turning in. Answered here for tomorrow-morning reading. Nothing committed as a plan — this is a thinking document.

**Date:** 2026-04-22

---

## Q1. Is there room on card 2 for a model-switcher side by side?

**Measured state of card 2 (5700 XT, 8 GB) during full concurrent load in today's stress test:**

- Baseline (empty): ~12 MB
- Qwen3-4B loaded (llama-secondary): ~5.75 GB
- mxbai-embed-large loaded (llama-embed): added maybe +1 GB (confirmed peak was 5458 MB total with BOTH loaded)
- **Headroom:** ~2.7 GB

A "model-switcher" in the dispatcher sense needs a small LLM to classify/route incoming requests. Two ways it could land on card 2:

### Option A — Third model on card 2

A second Qwen3-1.7B or similar small model, ~2 GB loaded, for routing decisions. Would fit in the ~2.7 GB headroom but be tight — peak VRAM climbs to ~7.5 GB, which is within stress-test pass thresholds but leaves almost no margin for driver allocations, flash-attn working memory, or unexpected transient spikes.

**Concern:** we passed the 8 GB envelope stress test with 2.7 GB headroom explicitly because "a third specialist on card 2 is plausible if needed." A dispatcher model that's *always* loaded would consume that headroom permanently. Fine for steady-state, risky for edge cases (future large query, different model variant, driver update).

### Option B — CPU-hosted router (my actual recommendation)

A 1-4B model on CPU runs at ~10-15 tok/s on your 5950X. For routing decisions — which are tiny prompts with tiny outputs — that's more than fast enough. Zero VRAM cost on either card.

**Tradeoff:** CPU inference latency per routing decision is maybe 200-500ms vs 50-100ms on GPU. In absolute terms, still fast enough that nobody notices. You only lose against GPU-based routing if the router fires hundreds of times per turn, which it won't.

### Option C — Don't build a router at all

This is the honest third option. Below.

### Recommendation: Option C (don't build yet), fall back to B if needed

Real question: **do you need a dispatcher/router at all right now?** You have:
- One capable primary (GLM) that handles everything through the agent tool-selection
- A second specialist (Qwen3-4B) doing distiller summarization
- A third specialist (mxbai) doing embeddings
- Opencode handling tool-routing via its MCP surface

The "dispatcher" in the tightened handoff was meant to route between *different primary models* (coder vs. reasoner vs. reviewer). If you're not swapping primaries, the dispatcher pattern isn't doing work for you. It becomes complexity without capability gain.

Unless you specifically want to A/B test the dispatcher pattern against your current stack (see the earlier brainstorm — that test is worth running but expected to show the current stack is best), don't build a router yet.

**If you later decide to build one:** Option B (CPU). Card 2 headroom is a hedge for future needs (bigger embedder, reranker, binary-file parser), not to be spent on routing.

---

## Q2. Can we wire models to "profiles" in opencode and not agentically choose?

**Yes, and opencode already supports this.** This is a better frame than "dispatcher" for your use case.

### What opencode supports natively

Opencode has an `agent` config block where you can define named agents, each with their own:
- Model (`model: "provider/model-name"`)
- Permissions
- Tool restrictions (deprecated `tools` field; newer `permission` field)
- System prompt / instructions

The built-in agents are `Build` (full tool access) and `Plan` (restricted). You can define custom agents in `opencode.json` or as Markdown files.

**Operator switches between agents using Tab** — direct, no LLM reasoning about which to pick. That's your "not agentically choose" requirement, exactly.

### Concrete profile shape that fits your workflow

Based on the runs we saw today and what you use opencode for:

```json
"agent": {
  "build": { "model": "llama-primary/glm-4.7-flash" },
  "research": {
    "model": "llama-primary/glm-4.7-flash",
    "tools": { "bash": false, "edit": false, "write": false }
  },
  "quick": {
    "model": "ollama-infer/qwen3-coder:30b",
    "description": "Faster, narrower. For simple code questions."
  }
}
```

- **`build`** — default. Full tools, current GLM-based ops stack.
- **`research`** — read-only. For "explain this codebase" sessions where you don't want any accidental edits/runs. Still uses GLM because Librarian + distiller integration matters more than model choice.
- **`quick`** — smaller, faster primary for quick interactions where you don't need GLM's capability ceiling.

Tab-switching means you deliberately pick which mode you're in for the session or for the current task. No router, no LLM reasoning, just mode selection.

### Caveat worth knowing

Switching agents mid-session **changes the active model** but opencode doesn't restart the MCP servers — Librarian + distiller keep their state. That's desirable.

But switching to an agent with a different `llama-primary` model target when the server is serving something else (e.g., `quick` agent expects `qwen3-coder:30b` on :11434 but `llama-primary.service` is serving GLM) will fail gracefully because opencode just sends the request and gets whatever :11434 returns. The `Conflicts=` on your systemd units means only one primary model can be live at a time.

**Practical upshot:** profile switching works at the opencode level, but swapping primary *models* still requires stopping one llama-server and starting another (which your wrapper already does at launch). For true per-task model swapping, you'd need llama-swap or an equivalent proxy that hot-swaps models behind a single port. Worth knowing if you go further.

### Recommendation

**Start with 2-3 profiles** in `opencode.json`, Tab-switch manually when you want different behavior. Don't add more until you notice you want them.

If per-profile model swapping becomes important (it probably won't for a while), look at `llama-swap` as the proxy layer.

---

## Q3. What can we meaningfully offload to CPU and DRAM to stretch performance?

This is the richer question. You have **~30 GB of idle DRAM and 30 of 32 CPU threads mostly idle** during AI sessions. Plenty of silicon to trade against. Here's the honest inventory, ranked by ROI.

### Tier 1 — high value, straightforward builds

#### 1. MoE expert offload for a bigger primary model

**This is the biggest latent capability upgrade in your stack.** llama.cpp supports partial CPU offload of mixture-of-experts models via `--n-cpu-moe` — hot layers stay on GPU, cold expert FFN tensors live in DRAM, and activation vectors cross PCIe per token.

Relevant for:
- **Qwen3-Next-80B-A3B** or **gpt-oss-20b** or similar — 20-80B parameter MoE models that would never fit at Q4 in 24 GB VRAM alone, but *do* fit at ~18 GB on-GPU + ~20 GB in DRAM.
- Benchmarks from the ecosystem: 30-40 tok/s decode is plausible on your hardware for an 80B-A3B model with this setup.

**Why it's good for you:** capability ceiling. GLM-4.7-Flash is solid but occasionally hits limits on deep reasoning (we saw glimpses today with the hookscript confabulation). A bigger MoE model with MoE offload *would not cost you any more VRAM* and would live in the same 64K context envelope.

**Cost:** ~2-4 hours to test. Pull the GGUF, tweak `llama-primary.service` with `--n-cpu-moe N`, benchmark vs. current GLM. Decide based on real numbers.

**Caveat:** PCIe becomes the bottleneck, not CPU compute. Your rig has PCIe 4.0 x16 on the 7900 XTX, so this is fine. Also: longer load times (weights have to mmap from NVMe), maybe ~60s to first token on first invocation. Warm state is fast.

Sources for this [1][2][3].

#### 2. Deterministic tooling on CPU (no model, just code)

Not everything needs an LLM. Things you're currently doing on the primary or secondary card that should just be Python on CPU:

- **JSON schema validation** for MCP tool returns (currently we rely on the model producing valid JSON; a CPU-side validator could catch and retry)
- **Compose-file linting** (YAML parse + schema check before proposing changes)
- **SSH command safety analysis** (regex + AST-ish patterns for "rm -rf", "pct destroy", chained destructive verbs) — the `ssh<read>` vs `ssh<write>` classifier we discussed
- **Markdown section extraction** (the chunker's document strategy — already CPU)
- **File change detection / watching** (already CPU-ish via watchdog)

**Why this matters:** every LLM call to do work a regex can do is wasted compute. The ~1 token per char of embedder time for a 5 KB chunk is 50 ms; a regex over 5 KB is 50 microseconds.

**Cost:** grows organically. Add these as we notice LLM calls that shouldn't exist.

#### 3. Shared HTTP/URL cache in DRAM

Distiller and any future miner-of-web-content re-fetch the same URLs across sessions. A process-lifetime LRU cache in DRAM (say 4-8 GB, storing gzipped HTML) would eliminate the re-fetch cost for common URLs like Proxmox docs, Debian changelogs, etc.

**Why it's good:** distiller calls against already-seen URLs go from ~5s (fetch + summarize) to ~2s (cached fetch + summarize). Shaves 40% off the common case.

**Cost:** 2-4 hours. diskcache or redis or plain Python dict with bounds. Plug into distiller.py's fetch layer.

---

### Tier 2 — real capability, needs design

#### 4. CPU-hosted specialist for slow-but-thorough tasks

Not every task needs GPU latency. Things that could run on CPU at 5-15 tok/s and not bother anyone:

- **Reranker** — after Librarian returns top-K, a small reranker (e.g., `cross-encoder/ms-marco-MiniLM`) on CPU re-scores the K chunks against the query with a more expensive model. Slow but improves quality on ambiguous queries. Fits in ~500 MB RAM, runs at ~100 ms per pair.
- **Binary file parser** — when we build support for PDFs, ipynb, etc. The *parsing* (PDF → text) runs on CPU. Only the embedding step needs the GPU. Natural CPU work.
- **Structured-output validator/retry** — a very small model (1-3B) on CPU that sanity-checks distiller JSON outputs before returning them. Catches the `parse_json_error` class we saw today.

**Cost:** depends on which. Reranker is ~1 day. Binary parser is a week (lots of format edge cases). Validator is a day.

#### 5. Tmpfs for KV cache checkpoints

llama.cpp supports `--slot-save-path` for saving/restoring KV cache per-slot. Currently points at `/tmp/aspects/` which is disk-backed. Mounting a 4-8 GB tmpfs (RAM-backed) at that path makes restore much faster — 10+ GB/s from DRAM vs. 3-5 GB/s from NVMe.

**Why it's niche:** you don't swap models mid-session currently. If you start using the profile-switching idea from Q2, this becomes useful.

**Cost:** 10 minutes to set up. Zero marginal work beyond mounting the tmpfs.

---

### Tier 3 — worth knowing, not worth building yet

#### 6. CPU-hosted embedder fallback

If card 2 fills up with other specialists, mxbai on CPU runs at ~50 ms/chunk. Stated explicitly because it's the contingency path we discussed during the stress test. Not needed today; good to know.

#### 7. NVMe-backed embedding persistence

Currently Librarian's cache is in-memory. If you build `ingest_topic` with persistent indexes, the embeddings + metadata + chunk store all lives on NVMe. Zero CPU/DRAM cost day-to-day; fast re-load on session start.

**Cost:** part of `ingest_topic` work whenever you build that.

#### 8. Pre-computed embedding for entire repos

Long-dead-end direction (because we already rejected LanceDB-on-disk persistence for Librarian V1), but worth noting: with 30+ GB DRAM idle, you could cache embeddings for entire indexed repos in memory, not just per-file.

**Why we rejected:** Librarian V2 is scoped to ad-hoc files, not repos. When `ingest_topic` arrives, *then* this matters.

---

## Summary table: what to try, in order

| # | Item | Effort | Payoff | Dependencies |
|---|---|---|---|---|
| 1 | MoE primary upgrade test | 2-4h | Biggest capability upgrade available | Nothing; just bench |
| 2 | Opencode profiles (Q2) | 30min | Clean per-task behavior, no agentic routing | Nothing |
| 3 | CPU URL cache | 2-4h | 40% speedup on common distiller calls | distiller.py refactor |
| 4 | tmpfs KV cache | 10min | Faster model swaps if/when you swap | `/tmp/aspects/` already in use |
| 5 | Deterministic CPU tooling | Ongoing | Eliminates wasted LLM calls | Add as noticed |
| 6 | CPU-hosted reranker | ~1 day | Better retrieval quality on ambiguous queries | After measuring ambiguous-query failures |

My suggested next build in the morning: **#1 (MoE bench)** — highest expected value, cheapest to validate. You either confirm GLM is the right primary and move on, or you find a bigger MoE model that outperforms it within the same VRAM envelope, which changes everything.

Second suggestion: **#2 (profiles)** — already supported by opencode, you just haven't configured it. 30 minutes to wire and probably useful immediately.

Skip routing/dispatcher work unless something specifically pushes you toward it.

---

## Sources

- [llama.cpp MoE offload guide (Doctor-Shotgun on HF)](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide)
- [Two-tier GPU+RAM expert cache proposal — llama.cpp issue 20757](https://github.com/ggml-org/llama.cpp/issues/20757)
- [Qwen3-235B-A22B MoE config (Medium)](https://medium.com/@david.sanftenberg/gpu-poor-how-to-configure-offloading-for-the-qwen-3-235b-a22b-moe-model-using-llama-cpp-13dc15287bed)
- [HOBBIT: MoE expert offloading paper (arxiv)](https://arxiv.org/html/2411.01433v2)
- [opencode agents docs](https://opencode.ai/docs/agents/) — profile-switching reference
- [opencode models docs](https://opencode.ai/docs/models/) — per-agent model override
