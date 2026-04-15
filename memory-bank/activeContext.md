# Active context

**Phase 1 complete as of 2026-04-15.** Stack is live and proven (see `progress.md`).

**Current focus:** Phase 1 fully closed. Next: real use, then Phase 2 (embedding server + Qdrant).

**Last added (2026-04-15):** lifecycle management via systemd user units + yad splash. Editor close now stops llama-server automatically; launcher shows live phase progress during startup with thresholds based on benchmark data.

**Not in scope right now:** Phase 2 (embedding server + Qdrant). Plan written, direction set, but work begins after wrap-up.

**Live endpoints:**
- Primary chat: `http://127.0.0.1:11434/v1` (Qwen3-Coder-30B, 7900 XTX).
- Embedding: not yet stood up.
- Qdrant: not yet stood up.

**Launch:**
- Normal: "VSCodium (Second Opinion)" desktop entry → splash → editor. Close editor → VRAM freed.
- Editor only (no llama): right-click desktop entry → "Editor only".
- Llama only: `systemctl --user start llama-second-opinion.service` from a terminal.
