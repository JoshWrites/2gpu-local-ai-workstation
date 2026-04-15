# Active context

**Phase 1 complete as of 2026-04-15.** Stack is live and proven (see `progress.md`).

**Current focus:** Phase 1 wrap-up tasks before moving to Phase 2.
- Populate memory-bank files with real project content (this file, productContext, systemPatterns).
- Import custom Review and Spec modes from `.roo/modes/*.yaml` into the isolated VSCodium's `custom_modes.yaml`.

**Not in scope right now:** Phase 2 (embedding server + Qdrant). Plan written, direction set, but work begins after wrap-up.

**Live endpoints:**
- Primary chat: `http://127.0.0.1:11434/v1` (Qwen3-Coder-30B, 7900 XTX).
- Embedding: not yet stood up.
- Qdrant: not yet stood up.

**Launch:**
- llama-server: `scripts/primary-llama.sh` (foreground; Ctrl+C to stop).
- Editor: "VSCodium (Second Opinion)" desktop entry.
