# Code mode rules template

Copy to `<project-root>/.roo/rules-code/implementation.md`. Applies only
when Roo is in **Code** mode.

- Read the project's plan or spec (typically `docs/implementation-plan.md`,
  `docs/plan.md`, or `docs/spec.md`) if one exists before writing code.
  Note its absence and proceed — do not fabricate one.
- Do not modify spec or plan files from Code mode. If you spot an issue,
  add a brief `TODO(spec):` comment where you hit it and keep going.
- After each file is written or meaningfully edited, run the project's
  test command (e.g. `pytest`, `go test ./...`). Fix failures before
  moving on unless the user has explicitly told you to defer.
- Commit after each logical unit of work. Use the project's convention
  (default: `feat: …` / `fix: …` / `chore: …`).
- Prefer the standard library. If a dependency is necessary, prefer a
  well-maintained package and record the choice in
  `private/memory-bank/decisionLog.md`.
- Python: type hints on public signatures; docstrings on public functions.
- No comments that merely restate the code. Comments are for non-obvious
  *why*, not *what*.
