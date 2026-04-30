# AGENTS.md

**Reinicorn** — agentic engineering harness. Scaffolding for AI-assisted
development: execution plans, cross-branch awareness, quality tracking.

## Knowledge Base

All project knowledge lives in `harness/` (git submodule, shared across branches).
**Never** place design docs, plans, decisions, or ideas outside `harness/`.

| What | Where |
|------|-------|
| Architecture & domains | `harness/{repo}/architecture/ARCHITECTURE.md` |
| Dependency rules | `harness/{repo}/architecture/dependency-rules.md` |
| Golden principles | `harness/{repo}/golden-principles.md` |
| Design documents | `harness/{repo}/design-docs/index.md` |
| Active execution plans | `harness/{repo}/exec-plans/active/` |
| Tech debt | `harness/{repo}/tech-debt/index.md` |
| Quality scores | `harness/{repo}/quality-scores.md` |
| Ideas | `harness/{repo}/ideas/index.md` |
| Product specs | `harness/{repo}/product-specs/index.md` |

Where `{repo}` is derived from `git remote origin` (e.g., `reinicorn`).

## CLI

Use `reinicorn` for all harness operations. Run via `uv run reinicorn`.

| Command | Purpose |
|---------|---------|
| `reinicorn sync` | Pull latest harness state |
| `reinicorn publish` | Push harness changes |
| `reinicorn plan create` | Create execution plan for current branch |
| `reinicorn plan status` | Show plan progress |
| `reinicorn status` | Show harness health + cross-branch overlap |
| `reinicorn idea "text"` | Quick idea capture |
| `reinicorn lint` | Run harness lint rules |
| `reinicorn attach` | Bolt reinicorn onto an existing repo (submodule + skills + hooks) |
| `reinicorn doc create <type> "title"` | Create a harness doc from template |
| `reinicorn feedback "text"` | Report a bug or idea (opens GitHub issue) |

## Hard Rules

1. **Check the plan first.** Read `harness/{repo}/exec-plans/active/{branch}/plan.md`
   before writing code. No plan? Ask the developer.
2. **Check for overlap.** Run `reinicorn status` before starting work. Flag
   conflicts with other branches immediately.
3. **Never create harness docs directly.** Use `reinicorn doc create <type> "title"`
   to create new docs in `harness/`. Never write, edit-to-create, or use shell
   commands (e.g. `echo >`, `printf >`, `cat >`) to create `.md` files under
   `harness/`. Editing existing harness docs is fine.
4. **Update touched-areas.** Every file you modify goes in
   `harness/{repo}/exec-plans/active/{branch}/touched-areas.md`.
5. **Follow golden principles.** Read `harness/{repo}/golden-principles.md`. Violations
   are CI errors.
6. **Run tests.** `uv run pytest` before marking work complete. Write tests for
   new behavior.
7. **Conventional commits.** `type(scope): description` — see git log for style.

## Testing

```
uv run pytest -v
```

## Progressive Disclosure

This file is a map. For details on any topic, read the linked harness document.
For maintenance procedures, run `reinicorn` subcommands — the CLI encodes the
workflows.
