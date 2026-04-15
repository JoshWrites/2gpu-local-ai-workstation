# Product context — second-opinion

Private local agentic coding stack for Josh. Everything runs on
`levine-positron`; nothing leaves the machine.

## What this is

A personal analog of the custom KB/agent tooling Josh builds at IRONSCALES:
own the layer, metrics-driven, build only what uniquely serves him. The
product is the *workflow*, not any one component — an editor + agent +
local model combo where Josh can direct technical work without writing
code himself.

## Who it serves

One user: Josh. Senior Tech Writer, non-traditional path into tech,
directs implementation via agents rather than coding directly. Not a CS-
trained engineer; relies on the agent catching his misconceptions. See
memory files for collaboration style — push back on bad premises, check
standard patterns before building bespoke, colorblind-safe viz required.

## What it is not

- Not a team tool. Pure single-user.
- Not a SaaS replacement for Claude.ai — this is a *second opinion*, a
  local peer for tasks where data sovereignty matters, cost matters,
  or the round-trip to a cloud model is too slow.
- Not a toy. Expected to be a daily driver for personal coding work.

## Core components

- **Primary model:** Qwen3-Coder-30B-A3B-Instruct (Unsloth Q4_K_M) on
  llama-server, pinned to the 7900 XTX. Prefix cache (`-cram`) verified
  at ~1028× speedup on stable prefixes.
- **Editor:** Isolated VSCodium instance (separate `--user-data-dir`) with
  Roo Code as the agent. Normal VSCodium is untouched.
- **Config:** Repo's `configs/roo-code-settings.json` is the source of
  truth, wired via Roo's `autoImportSettingsPath`.
- **Phase 2 planned:** 5700 XT as an embedding server for Roo's Codebase
  Indexing (Qdrant backend). Reduces context burn from full-file reads
  and cuts prompt-injection surface.
- **Phase 3 planned:** Speculative decoding with a Qwen3-family draft
  model; parallel validation runner.

## Success metric

Smooth daily use with minimal friction. Josh should be able to direct
technical work here the way he directs Claude at IRONSCALES — agent does
the implementation, Josh owns the architecture and the judgment.
