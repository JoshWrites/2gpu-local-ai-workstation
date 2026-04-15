# System patterns

Conventions observed across this repo and this workstation.

## GPU addressing

- GPU 0 = RX 5700 XT (gfx1010), 8 GB. GPU 1 = RX 7900 XTX (gfx1100), 24 GB.
  This is the opposite of what the reference guide assumes.
- Any llama.cpp or ROCm process that must target a specific card uses
  `ROCR_VISIBLE_DEVICES=<n>` — without it, ROCm enumerates both and
  defaults to device 0 regardless of model size. `HSA_OVERRIDE_GFX_VERSION`
  alone is not enough.

## Config as code, not click-through

- Roo config: export JSON + `autoImportSettingsPath` pointing at a repo
  file. No hand-editing inside VSCodium once bootstrapped.
- Launcher scripts for every long-running process (`primary-llama.sh`,
  `codium-second-opinion.sh`). Desktop entries reference the scripts, not
  raw commands, so changes live in one place.
- Isolated VSCodium uses its own `--user-data-dir` and `--extensions-dir`;
  nothing about the agentic stack contaminates the normal editor.

## Services: never auto-start AI

- Per the 2026-04-15 boot-cleanup baseline, all `ollama*.service` units
  are disabled and must stay disabled. `systemctl start` only for the
  session — never `enable`.
- llama-server is launched manually via its script; no systemd unit.
- Qdrant (Phase 2) will run in Docker with `--restart=unless-stopped`,
  scoped explicitly to this project.

## Security defaults

- Auto-approve is on for this repo because it's trusted and local, but
  `allowedCommands` is bounded (read/write/git/lang runtimes; no `rm`,
  `curl`, `wget`, `sudo`).
- `.rooignore` excludes venvs, caches, and `models/` so the agent can't
  wander into dependency code or dump huge binaries into context.
- Read-only modes (Ask, Review) are the safety boundary for untrusted
  content. Rules alone are not security.

## Documentation flow

- `docs/implementation-plan.md` — authoritative plan, revised in place as
  decisions change. Includes explicit "why this changed" paragraphs.
- `docs/post-phase1-enhancements.md` — parking lot for real observed
  gaps, ordered by expected impact.
- `memory-bank/*.md` — lightweight working context; progress + active +
  decisions. No TODO stubs left in populated files.
- `docs/roo-settings-management.md` — operational doc on how Roo stores
  config and why autoImport is the only sane path.
