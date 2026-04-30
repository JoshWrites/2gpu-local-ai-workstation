# Project rules template

Copy to `<project-root>/.roo/rules/project.md` and edit. Applies to all
modes within the project.

## Scope
- One sentence on what this project is and who it serves.
- Primary language/runtime and baseline OS/hardware assumptions
  (e.g. "Python 3.12 on Ubuntu 24.04, AMD GPU via ROCm").

## Conventions
- Where configs live (e.g. `configs/`, `/etc/<service>/`).
- Where tests live and how they run (`pytest`, `go test`, etc.).
- Commit message style (default: imperative, Conventional Commits if used).

## Hard constraints
- Dependencies to prefer or avoid (e.g. "prefer stdlib; justify new deps
  in `private/memory-bank/decisionLog.md`").
- Things never to do (e.g. "never commit secrets", "never disable TLS verify",
  "never `systemctl enable` an Ollama unit on this box").

## Artifacts expected
- Which memory-bank files must stay current.
- Whether `docs/` is authoritative and what belongs there vs. in the repo
  root.
