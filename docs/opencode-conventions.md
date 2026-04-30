# Opencode conventions

Shared conventions for opencode sessions on the Workstation stack. Both users' `~/.config/opencode/AGENTS.md` files reference this doc for meta-rules so the source of truth is one file, not many.

This doc is prescriptive for agents (GLM and friends) and explanatory for humans. If you're a developer reading to understand how things work, welcome.

---

## Who uses this stack and in what shape

Two users share one workstation: `levine` (Josh, owner) and `anny` (Nili, wife, developer in her own right). Opencode runs under whichever user launched it; both users hit the same GPU-hosted services.

### Session shapes in use

| Who | UI origin | Where work happens | Launch path |
| --- | --- | --- | --- |
| levine | workstation | workstation | `opencode-session.sh` via shell alias |
| anny | laptop (SSHes in) | laptop (via SSHFS + `ssh laptop --` for execution) | `work-opencode` alias → SSH → `work-opencode-launch` on workstation |

Future shapes (not built):
- anny running opencode directly on her laptop (for offline work or when workstation is unavailable)
- either user operating against CT 100 / Proxmox server from their existing session
- mobile-origin sessions from outside the LAN

When those arrive, see `memory/project_safe_bash_todo.md` for the `SESSION_ROUTING` / `SESSION_EXEC_ORIGIN` env-var scheme designed to make sessions self-describing.

---

## Shared services, polkit, polite shutdown

### How the llama services are managed

Four services run on the workstation and serve both users over localhost HTTP:

- `llama-primary.service` — GLM-4.7-Flash on `:11434` (7900 XTX)
- `llama-secondary.service` — Qwen3-4B (distiller's summarizer) on `:11435` (5700 XT)
- `llama-embed.service` — multilingual-e5-large (Librarian) on `:11437` (5700 XT)
- `llama-coder.service` — Qwen2.5-Coder-3B (Zed edit prediction) on `:11438` (5700 XT)

Service files live at `/etc/systemd/system/`. **Not enabled at boot** — they start on demand when either user's launcher runs them, stay up as long as anyone is using them, stop when explicitly shut down.

A polkit rule at `/etc/polkit-1/rules.d/10-llama-services.rules` grants both users the ability to `systemctl start/stop/restart` these specific services without a sudo password.

### Coordinating shutdown (the two-user problem)

Because services are shared, "when is it safe to stop them?" matters. The solution:

- **`llama-status`** — read-only, prints each service's state, connected clients, last activity time. Run anytime.
- **`llama-shutdown`** — polite stop. Counts active TCP connections, refuses to stop if anyone is connected, waits 30 seconds of continuous idleness before stopping. `--force` overrides (use sparingly); `--grace=N` overrides the default 30s grace.

Both scripts at `/usr/local/bin/`, available to both users.

Normal exit path:
- levine's `opencode-session.sh` calls `llama-shutdown` on exit
- anny's `work-opencode-launch` does NOT stop services on exit (the other user might still be working)
- Either user can run `llama-shutdown` manually to trigger the polite shutdown

### When anny's session starts

Her launcher checks whether all three services are responsive. If yes, reuses them (no restart). If no, starts them (polkit allows without password) and waits up to 60 seconds for HTTP readiness. Fails loudly with a useful error if anything's broken.

---

## How anny's session operates on her laptop

Her opencode session runs on the workstation. Her files live on her laptop. The bridge is SSHFS.

### SSHFS mount

When her launcher runs, it mounts her laptop's `/home/anny` at `/home/anny/laptop-home/` on the workstation via SSHFS. Key options:

- **`idmap=user`** — maps laptop-anny's UID (1000) to workstation-anny's UID (1003). Without this, `default_permissions` would block traversal into her own mount.
- **`allow_other`** — lets levine's user inspect the mount from his session for debugging. Requires `user_allow_other` in `/etc/fuse.conf` (enabled on 2026-04-23).
- **`reconnect` + `ServerAliveInterval`** — survives transient network blips.

File reads through the mount feel local. Only bytes for files actually opened cross the wire; directory listings are cheap.

### Cwd context from her laptop

Her laptop's `work-opencode` is a bash function (not an alias, so it can use `$PWD`):

```bash
work-opencode() {
  ssh -t anny@levine-positron /home/anny/.local/bin/work-opencode-launch "$PWD"
}
```

The launcher receives her laptop's current directory as `$1`. If the path starts with `/home/anny/`, it's rewritten to `$MOUNT_POINT/...` (both machines have the same home path so prefix replacement works). She can `cd` into a project on her laptop, type `work-opencode`, and land in opencode at the mounted equivalent. If she passes a relative path, it's treated as relative to the mount root. A path outside `/home/anny` falls back to mount root with a warning.

### MCPs live in her own clones

Anny has her own clones of the MCP code, not symlinks or references to levine's:

- `/home/anny/Documents/Repos/local-mcp-servers/` — from `JoshWrites/local-mcp-servers` (private)
- `/home/anny/Documents/Repos/library_and_patron/` — from `JoshWrites/library_and_patron` (private)

Her opencode.json points `distiller` and `librarian` MCP command paths at her clones. `uv run --project` uses her own venv, her own cached deps. When levine pushes an update to `main`, she runs `git pull` in the relevant clone to pick it up. No drift, no shared filesystem reading into levine's home.

This requires:
- `gh auth login` as anny on the workstation (she's already logged in on her laptop as `Nili-L`, token persisted in `/home/anny/.config/gh/hosts.yml`)
- Collaborator invite accepted on each private repo

Her session's MCP timeouts are bumped vs. defaults:
- `distiller`: 180s (accommodates web-fetch + summarization on secondary card)
- `librarian`: 120s (accommodates cold-start chunk + embed for first mine on a new file)

### Read via mount, execute via SSH

Her AGENTS.md tells GLM the invariant:

- **Reads** (`read`, `grep`, `ls`, librarian): use the mount path `/home/anny/laptop-home/...`. File content flows through SSHFS.
- **Writes** (`edit`, redirect-to-file, `sed -i`): also through the mount. Writes land on her laptop's filesystem because that's where the files live.
- **Execution** (`bash`, `npm`, `pip`, `docker`, `systemctl`, anything that mutates state or has runtime behavior): **prefix with `ssh laptop --`**. The workstation doesn't have her project's runtime, dependencies, or dev environment; running execution there gives false performance signals and often fails outright.

This is a **convention, not an enforced rule** in current V1. GLM reads the AGENTS.md at session start and respects it. If GLM drifts and runs `npm test` unqualified, it fails on the workstation because Node isn't there; GLM self-corrects. If drift becomes a problem in practice, `safe_bash` (see `memory/project_safe_bash_todo.md`) would enforce it.

---

## Prefer `librarian_mine_file` over `read` for question-shaped file access

When the user asks a question *about* a file's contents ("how does X work?", "what does the plan say about Y?", "summarize the security policy"), call `librarian_mine_file(path, query)` instead of `read`.

The librarian chunks the file, embeds it on the secondary GPU, and returns only the chunks relevant to the query. Reading the whole file costs primary-model context proportional to file size; the librarian costs ~1-5K regardless.

Use `read` only when:
- The user wants the whole file verbatim
- You need to edit the file
- The file is tiny (< 100 lines)
- The librarian is unavailable

Mine iteratively on ambiguous questions. Different query phrasings surface different facets (Librarian caches embeddings per-file, so additional mines after the first are nearly free). A drilldown of 3-4 queries typically delivers a materially better answer than a single broad query.

---

## Use `distiller_research` for web research

When you need current information from the web — docs, changelogs, forum posts, GitHub issues, Stack Overflow, package READMEs — call `distiller_research(question)`. It runs a search-and-summarize pipeline so only the distilled answer hits your context.

Use `webfetch` directly only when:
- You know the exact URL
- The user has explicitly pointed you at a URL
- `distiller_research` returned thin results

Use `distiller_research` liberally — local, free, cheap. Better than guessing at APIs from memory.

---

## Diagnose before destroy

When something looks broken, state what you believe is wrong and why *before* proposing destructive or reset-style fixes. A fix that destroys state also destroys diagnostic signal. If a symptom has multiple possible causes, check the cheap observable one first before reaching for the nuclear option.

Examples of destroying signal:
- `docker rm` a crashlooping container before you've read the logs from the start of the crash
- `git reset --hard` a broken branch before you've read what's actually wrong
- `rm -rf node_modules && npm install` before you've identified the specific missing or conflicting package
- Recreating a systemd service before you've checked why it failed

---

## Command tiering (conceptual, not enforced in V1)

Commands conceptually fall into three tiers by blast radius. Current V1 of the stack does NOT enforce these tiers — opencode's static ruleset in `opencode.json` handles most gating, with specific destructive patterns listed as `deny` or `ask`. The tiers are documented here as the shape any future gating mechanism (the paused `safe_bash`, or a successor to `tool.execute.before` if upstream fixes `permission.ask`) should follow.

- **Read:** idempotent, non-mutating. `ls`, `cat`, `grep`, `docker ps`, `git status`, etc.
- **Write:** reversible with work. `mkdir`, `cp`, `mv`, `git commit`, `docker run`, `npm install`, `systemctl restart`, etc.
- **Remove:** irreversible or state-destroying. `rm`, `docker rm`, `apt purge`, `git reset --hard`, `kill -9`, `reboot`, `dd`, `mkfs*`, etc.

Full lists and rationale: see `memory/project_safe_bash_todo.md` and the classifier source at `~/Documents/Repos/Workstation/second-opinion/opencode-plugins/permission-classifier/index.js` (preserved for future use).

---

## Known SSH targets

- `laptop` — anny's laptop, resolved via her `~/.ssh/config`. In her session, use this for all execution.
- `levinelabsserver1` / `proxmox` — Proxmox homelab host. In levine's session, used for infrastructure management. Server-map and diagnostic docs live at `~/Documents/Repos/LevineLabsServer1/docs/`.

When operating on `levinelabsserver1`, mine the relevant doc before blindly probing:
- `network.md` for architecture
- `server-map.md` for symptom-driven diagnostics
- `security-plan.md` for access/auth decisions

---

## For humans reading this

The system is designed to make agent-assisted development safe enough to run mostly unattended, while keeping enough friction on irreversible actions that the human stays in the loop for those specifically. Key design choices:

- **Services not enabled at boot** — respects gaming/non-AI workstation time
- **Polkit grants specific permissions, not broad sudo** — scope is the three llama services, nothing else
- **Polite shutdown refuses if anyone's connected** — the two-user "are you done?" problem solved without synchronization protocols
- **Read via mount, execute via SSH** — anny sees her laptop's real performance, not the workstation's, because execution genuinely runs on her hardware
- **Librarian over read, distiller over webfetch** — context efficiency is purchased by doing small amounts of work on the secondary card (embed, summarize) to avoid inflating the primary card's context
- **Diagnose before destroy** — every piece of automation has failed gracefully at least once today because diagnostic output was preserved before destructive cleanup
