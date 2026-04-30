# Opencode conventions

Shared conventions for opencode sessions on this stack. The
`~/.config/opencode/AGENTS.md` file is generated from a symlink into
`configs/opencode/AGENTS.md` and references this doc for meta-rules so
the source of truth is one file, not many.

This doc is prescriptive for agents (GLM and friends) and explanatory
for humans. If you are a developer reading to understand how things
work, welcome.

---

## Multi-user note

The stack supports two local users sharing the workstation. The polkit
rule, the system-scoped `llama-*` services, and the polite-shutdown
coordinator all exist because the workstation hosts more than one
person who codes with these services.

This documentation describes the single-user case. The multi-user
extension (a second user reaching in over SSH, mounting their laptop
filesystem via SSHFS, running opencode under their own account) works
on this hardware but is not documented in the public repo. The
relevant pieces if you want to recreate it: polkit grants for both
users on the four `llama-*` services, SSHFS with `idmap=user` for UID
remapping, and a per-user wrapper script that does cwd translation
between laptop and mount paths.

---

## Shared services, polkit, polite shutdown

### How the llama services are managed

Four services run on the workstation and serve any local user over
localhost HTTP:

- `llama-primary.service` -- chat model (e.g., GLM-4.7-Flash) on
  `:11434` (7900 XTX).
- `llama-secondary.service` -- summarizer (Qwen3-4B) on `:11435`
  (5700 XT).
- `llama-embed.service` -- multilingual embedder
  (multilingual-e5-large) on `:11437` (5700 XT).
- `llama-coder.service` -- edit-prediction model (Qwen2.5-Coder-3B)
  on `:11438` (5700 XT).

Service files live at `/etc/systemd/system/`. **Not enabled at boot**
-- they start on demand when a launcher runs them, stay up as long as
anyone is using them, stop when explicitly shut down.

A polkit rule at `/etc/polkit-1/rules.d/10-llama-services.rules`
grants the configured local users the ability to
`systemctl start/stop/restart` these specific services without a sudo
password.

### Coordinating shutdown

Because services are shared, "when is it safe to stop them?" matters.
The solution:

- **`llama-shutdown`** -- polite stop. Counts active TCP connections
  and checks for opencode/zed processes that count as session-holders.
  Refuses to stop if anyone is connected, waits for a grace period of
  continuous idleness before stopping. `--force` overrides (use
  sparingly); `--grace=N` overrides the default grace period.

The launcher (`scripts/2gpu-launch.sh`) calls `llama-shutdown` on
editor close when invoked with a path argument; the manual command is
available to either user from a terminal at any time.

---

## Prefer `library_read_file` over `read` for question-shaped file access

When the user asks a question *about* a file's contents ("how does X
work?", "what does the plan say about Y?", "summarize the security
policy"), call `library_read_file(path, query)` instead of `read`.

The Library MCP chunks the file, embeds it on the secondary GPU, and
returns only the chunks relevant to the query. Reading the whole file
costs primary-model context proportional to file size; the Library
costs ~1-5K regardless.

Use `read` only when:

- The user wants the whole file verbatim
- You need to edit the file
- The file is tiny (< 100 lines)
- The Library is unavailable

Mine iteratively on ambiguous questions. Different query phrasings
surface different facets (Library caches embeddings per-file, so
additional calls after the first are nearly free). A drilldown of 3-4
queries typically delivers a materially better answer than a single
broad query.

---

## Use `library_research` for web research

When you need current information from the web -- docs, changelogs,
forum posts, GitHub issues, Stack Overflow, package READMEs -- call
`library_research(question)`. It runs a search-and-summarize pipeline
so only the distilled answer hits your context.

Use `webfetch` directly only when:

- You know the exact URL
- The user has explicitly pointed you at a URL
- `library_research` returned thin results

Use `library_research` liberally -- local, free, cheap. Better than
guessing at APIs from memory.

---

## Diagnose before destroy

When something looks broken, state what you believe is wrong and why
*before* proposing destructive or reset-style fixes. A fix that
destroys state also destroys diagnostic signal. If a symptom has
multiple possible causes, check the cheap observable one first before
reaching for the nuclear option.

Examples of destroying signal:

- `docker rm` a crashlooping container before you have read the logs
  from the start of the crash
- `git reset --hard` a broken branch before you have read what is
  actually wrong
- `rm -rf node_modules && npm install` before you have identified the
  specific missing or conflicting package
- Recreating a systemd service before you have checked why it failed

---

## Command tiering

Commands fall conceptually into three tiers by blast radius. The
production gating mechanism is opencode's `permission.bash` config in
`opencode.json` (rendered from `configs/opencode/opencode.json.template`),
with specific destructive patterns listed as `deny` or `ask`. The tiers
below are documented as the shape any future gating mechanism should
follow:

- **Read:** idempotent, non-mutating. `ls`, `cat`, `grep`, `docker ps`,
  `git status`, etc.
- **Write:** reversible with work. `mkdir`, `cp`, `mv`, `git commit`,
  `docker run`, `npm install`, `systemctl restart`, etc.
- **Remove:** irreversible or state-destroying. `rm`, `docker rm`,
  `apt purge`, `git reset --hard`, `kill -9`, `reboot`, `dd`,
  `mkfs*`, etc.

The umbrella's `archive/permission-classifier/` directory holds an
opencode plugin that classified bash commands into these tiers
programmatically; it was superseded by the static `opencode.json`
patterns and is preserved as reference code, not running
infrastructure.

---

## For humans reading this

The system is designed to make agent-assisted development safe enough
to run mostly unattended, while keeping enough friction on
irreversible actions that the human stays in the loop for those
specifically. Key design choices:

- **Services not enabled at boot** -- respects gaming and non-AI
  workstation time.
- **Polkit grants specific permissions, not broad sudo** -- scope is
  the four llama services, nothing else.
- **Polite shutdown refuses if anyone is connected** -- the multi-user
  "are you done?" problem solved without synchronization protocols.
- **Library over read, library_research over webfetch** -- context
  efficiency is purchased by doing small amounts of work on the
  secondary card (embed, summarize) to avoid inflating the primary
  card's context.
- **Diagnose before destroy** -- every piece of automation has failed
  gracefully at least once because diagnostic output was preserved
  before destructive cleanup.
