# private

Per-user workspace inside the umbrella. Everything here except this README
and `.gitignore` is gitignored at the repo root. Drop personal notes,
working memory, scratch files, machine-specific overrides here and the
umbrella will not commit them.

## What lives here on this machine

`memory-bank/` holds active working context: decision log, system
patterns, progress notes. The empty starting point that a fresh clone
inherits is at `../memory-bank-template/`.

## Adding things

If you start dropping files in this directory and want some of them
tracked (e.g., a cross-machine personal AGENTS.md override), add an
allowlist line to `../.gitignore` near the existing `!private/README.md`
entries.

## Why this directory exists at all

The umbrella exists to be public eventually. The personal context
that informs day-to-day decisions does not. Keeping a clearly-marked
private dir at the repo root is more honest than scattering gitignored
paths across multiple subdirectories.
