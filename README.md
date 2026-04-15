# second-opinion

A private, local-first agentic coding environment built around the idea that a
small support model watching a large primary model produces better outcomes
than either one alone — a second opinion, always on.

**Status:** pre-alpha, private. Will eventually be public; until then, treat the
repo as personal workspace.

## The machine this is built for

- **CPU:** AMD Ryzen 9 5950X (16C/32T)
- **RAM:** 64 GB DDR4
- **GPUs:**
  - Primary: Radeon RX 7900 XTX — 24 GB, RDNA 3 (gfx1100), ROCm-supported
  - Secondary: Radeon RX 5700 XT — 8 GB, RDNA 1 (gfx1010), Vulkan fallback
- **Storage:** NVMe PCIe 4.0
- **OS:** Ubuntu 24.04, kernel 6.17

No reformats, no OS switch, no new hardware. Every design decision works
within that envelope.

## The idea

A single large model (Qwen3.5-27B or similar) runs the coding work on the
primary GPU. A smaller model (Phi-4 Mini or similar) runs permanently on the
secondary GPU as **support intelligence**: it watches the primary's conversation
stream, extracts learnings into a persistent knowledge base, and classifies
topic shifts. The CPU and the rest of RAM pick up validation, compression,
and embedding work that would otherwise block the GPU.

The name is the thesis: the secondary model exists to give the primary a
second opinion — from a persistent memory of past sessions, not from a second
expensive inference pass.

## Phased rollout

Each phase is independently useful. Later phases enhance earlier ones; nothing
is throwaway work. Plans are expected to shift as real pain points surface.

1. **Core stack** — llama-server on 7900 XTX, Qwen3.5-27B, Roo Code in VSCodium,
   rules files.
2. **Support GPU + manual observer** — Phi-4 Mini on 5700 XT, post-session
   extraction into a dual-scope index.
3. **Speculative decoding + parallel validation** — CPU draft model, file-change
   watcher running pytest/mypy/ruff in parallel with generation.
4. **Evaluate** — live with the above for 2–3 weeks before committing to
   forks or heavier machinery.

Phases beyond 3 (Roo Code fork, aspect-server, real-time observer, voice) are
deferred until the lived experience of phases 1–3 proves them necessary.

## Layout

```
second-opinion/
├── README.md          This file.
├── docs/
│   └── reference-guide.md   Full architectural reference (April 2026).
├── scripts/           Install, launch, and maintenance scripts (TBD).
└── config/            Systemd units, llama-server flags, rules files (TBD).
```

## License

Unlicensed while private. A permissive license will be chosen before the repo
is made public.
