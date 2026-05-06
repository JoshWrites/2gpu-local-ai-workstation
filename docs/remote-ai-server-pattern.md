# The remote-AI-server pattern

How to run a setup where one user works locally with their own files
on their own machine, and some or all of the AI workload runs on a
different machine on the same network.

This doc has three parts. First, the two deployment shapes the
pattern supports — they have different contracts and different
update procedures, so know which one you're running before you read
further. Second, the architecture and contracts: what's
load-bearing, what's optional, what breaks if you skip a step.
Third, the concrete update procedure for keeping a remote user's
installation in sync with the AI server, written as copy-paste
blocks rather than a single script, because the cross-machine,
cross-user hopping is hard to automate robustly and easier to read
as a checklist.

For the *initial* onboarding flow (creating the user, getting the
keys exchanged, setting up WireGuard), see
[`remote-user-setup.md`](remote-user-setup.md). This doc assumes
that's already done.

For an update that just touches the workstation (no laptop side),
see [`second-user-setup.md`](second-user-setup.md) which covers
the local-only case.

---

## Two deployment shapes

Two distinct things can be served from a remote AI machine, and they
have different contracts.

### Shape A — full stack (chat model + retrieval + edit prediction)

The laptop is mostly a thin client. Zed runs locally because editor
latency demands it, but everything else — the chat model, the
opencode agent, edit prediction, retrieval — runs on the server.
The laptop reaches the server via SSH (for the agent's ACP
protocol), SSHFS reverse-mount (so opencode can see the user's
files), and a direct HTTP connection to llama-coder for inline edit
predictions.

This is what anny runs in the 2gpu deployment. It's the right shape
when the user doesn't have a GPU big enough for their preferred
chat model, or when multiple users want to share one big-GPU
workstation.

### Shape B — Library MCP only

The laptop runs its own complete AI stack — its own chat model
(local or hosted), its own opencode (or other MCP-aware agent), its
own editor — and reaches out to the AI server *only* for the
Library MCP. The server contributes web search, embeddings,
summarization, and document conversion; the chat model and editor
stay on the laptop.

Three motivations for this shape, roughly ordered by how often each
applies:

1. **Hosted-API chat model + cost discipline.** The user is paying
   per token to a hosted provider (Anthropic, OpenAI, Mistral, etc.)
   and webfetch-style raw retrieval makes the bill unreasonable
   fast — Library's 22-43× compaction (see the
   [stack one-sheet](research/2026-05-03-stack-one-sheet.md))
   directly translates to 22-43× lower input-token spend on every
   research-bearing turn. The chat session also stays cheaper to
   *resume*: every message replays the entire prior conversation
   to the provider, so a 100KB block of raw HTML in turn 3 is paid
   for again on every subsequent turn. Library keeps that at ~400
   tokens.
2. **Already-working local LLM workflow.** The user has a chat
   model they like running on their own machine (ollama, lmstudio,
   a private llama.cpp build) and just wants better retrieval
   without changing what they already use.
3. **Asymmetric VRAM budget on the laptop.** The laptop has enough
   GPU to run a chat model OR run embeddings + summarization
   sidecars, but not both at once. Push the sidecars to the server,
   keep the chat where the laptop can hit it fastest.

The server's role in Shape B is much smaller: just expose Library
to the laptop. The laptop's opencode is configured with Library as
an MCP server reached over the network, with `LIBRARY_*_URL` env
vars pointing at the laptop's own loopback (for any sidecars the
laptop runs locally) or at the server (for sidecars only the server
provides).

A common Shape B layout: laptop runs its own chat model and
mnemory; server runs SearxNG, llama-embed, llama-secondary
(summarizer), and docling-serve. Library lives on the server but
the laptop's opencode talks to it. This pattern reuses the server's
retrieval infrastructure across multiple users without committing
each user to the server's chat model.

### Quick comparison

|                              | Shape A (full)                      | Shape B (Library only)              |
|------------------------------|--------------------------------------|--------------------------------------|
| Chat model                   | Server                              | Laptop                              |
| opencode (or agent runtime)  | Server                              | Laptop                              |
| Editor (Zed)                 | Laptop                              | Laptop                              |
| Edit prediction              | Server (port 11438)                 | Laptop or none                      |
| Library MCP                  | Server (loopback to opencode)       | Server (network to laptop opencode) |
| Files                        | Laptop home, SSHFS-mounted on server | Laptop home, never leaves laptop     |
| Server-side polkit grants    | Required (for llama-* services)     | Not required                        |
| SSH key exchange             | Required (ACP over stdio)           | Optional (only if Library ships over SSH) |
| WireGuard / VPN              | Strongly recommended                 | Strongly recommended                |
| AGENTS.md as copy not symlink | Required (on server, for opencode)  | Required (on laptop, for opencode)  |
| `~/.mnemory/` collection     | Server, dim-locked at first use     | Laptop, dim-locked at first use     |

The rest of this doc has separate subsections for each shape where
they differ. Common contracts (network, AGENTS.md, dim-locked
embeddings) are called out once.

---

## Architecture

### Shape A — full-stack architecture

```
┌──────────── User's laptop ────────────┐         ┌──────────── AI server ────────────┐
│                                       │         │                                   │
│  Editor (Zed)                         │         │  Patched opencode (ACP agent)     │
│   │                                   │         │   │                               │
│   │  ACP over SSH stdio               │ ─────── │   │                               │
│   ├──────────────────────────────────▶│ ◀──────▶│   │  llama-primary (chat)         │
│   │                                   │   :22   │   │  llama-secondary (summarize)  │
│   │  SSHFS reverse-mount of laptop    │         │   │  llama-embed                  │
│   ├──────────────────────────────────▶│ ◀──────▶│   │  llama-coder (edit predict)   │
│   │                  /mnt/<user>-laptop│         │   │  Library MCP (loopback)       │
│   │                                   │         │   │  mnemory (optional)           │
│   │  edit predictions over LAN/WG     │         │   │                               │
│   └──────────────────────────────────▶│ ◀──────▶│   │  ports 11434/5/7/8, 8050     │
│                                       │   :11438│                                   │
│                                       │         │                                   │
└───────────────────────────────────────┘         └───────────────────────────────────┘
```

Three concurrent connections between the two machines:

- **SSH** carries the ACP protocol that drives the chat agent. Zed's
  agent panel speaks ACP; opencode runs on the AI server and reads
  ACP over its stdio when invoked from a wrapper script over SSH.
- **SSHFS reverse-mount** lets opencode see the user's files. The
  laptop exports its `$HOME` to the AI server at
  `/mnt/<user>-laptop/`. opencode runs on the AI server, opens files
  through that mount point, and the bytes flow over SSH on demand.
- **Direct HTTP to llama-coder** (port 11438) on LAN or VPN gives
  Zed inline edit predictions without going through opencode. This
  is the only path with a sub-100ms latency budget; routing it via
  ACP would add too much round-trip cost.

Library on the AI server is reached only by opencode-on-the-server
over loopback. The laptop never sees Library directly in this
shape.

### Shape B — Library-only architecture

```
┌──────────── User's laptop ────────────┐         ┌──────── AI server (smaller role) ─┐
│                                       │         │                                   │
│  Editor (Zed) + opencode + chat model │         │  Library MCP                      │
│   │                                   │         │   │                               │
│   │  MCP over SSH stdio (or HTTP)     │ ─────── │   │  llama-secondary (summarize)  │
│   └──────────────────────────────────▶│ ◀──────▶│   │  llama-embed                  │
│                                       │   :22   │   │  SearxNG, docling-serve       │
│                                       │ or :8090│   │                               │
│                                       │         │                                   │
│  files: local. mnemory: optional      │         │  llama-primary, llama-coder:      │
│  on laptop.                           │         │  not used in this shape           │
│                                       │         │                                   │
└───────────────────────────────────────┘         └───────────────────────────────────┘
```

Only one connection: the laptop's opencode reaches Library on the
server. Two ways to do that:

- **MCP over SSH stdio** — laptop's opencode is configured with
  Library as a `local` MCP whose `command` is
  `ssh server-host /path/to/library/launcher`. opencode spawns ssh,
  the server runs `library` (the entry point), MCP framing flows
  back over the SSH stdio. No HTTP port needs to be open. This is
  the simplest variant and recommended unless you have a reason
  for HTTP.
- **MCP over HTTP** — Library on the server is wrapped in an HTTP
  endpoint (e.g. via fastmcp's HTTP transport) and the laptop's
  opencode reaches it as a `remote` MCP. Requires the server to
  bind on an interface the laptop can reach.

The chat model lives on the laptop in this shape. It can be
anything: a local llama.cpp running a model the laptop's GPU can
fit, a hosted Anthropic/OpenAI API, ollama, anything else opencode
supports. Library doesn't care.

Edit prediction in this shape is laptop-local (e.g. a small coder
model on the laptop's own GPU) or off entirely. The server's
llama-coder service is unused.

mnemory in this shape lives on the laptop, dim-locked to the
laptop's chat workflow. The server's mnemory instance is unused.

### Common contracts (apply to both shapes)

**Agent rules — AGENTS.md must be a copy, not a symlink.**
opencode does not follow symlinks for global agent rules. Wherever
opencode runs (Shape A: server-side, under the remote user's home;
Shape B: laptop-side, under the user's home), the
`~/.config/opencode/AGENTS.md` file must be a regular file. This
is the one place in the stack where copying-instead-of-linking is
mandatory. Update procedure below covers how to keep the copy in
sync.

**Embedding dimension is locked at first use.** Whichever side
runs the vector store (mnemory's qdrant, or any other store using
the embeddings sidecar) commits to a specific embedding dimension
on its first write. Changing the embedding model later requires
dropping that store and re-ingesting; otherwise you get silent
write rejections.

**Network — assume hostile and use a VPN.** WireGuard or
equivalent. Don't expose any of these services to the public
internet. The threat model assumes a trusted LAN or trusted VPN.

### Shape A contracts

**Network**:
- Laptop must reach the AI server's SSH port (typically 22) and the
  llama-coder port (typically 11438). Either same LAN or VPN.
- AI server must reach the laptop's SSH port for the SSHFS reverse-
  mount. WireGuard gives both directions in one configuration.
- Firewall rules: llama-coder must bind on a non-loopback interface
  so the laptop can reach it. The other llama services can stay
  loopback-only since the laptop never talks to them directly —
  opencode on the AI server talks to them over loopback.

**System users**:
- AI server has a dedicated user account per remote user. polkit
  grants that account passwordless start/stop on the `llama-*`
  services.
- The remote user authenticates to their AI-server account via SSH
  keys, one per device.

**File access**:
- Laptop runs `sshfs` with FUSE configured to allow remote-user
  access to the mount. AI server runs the kernel `fuse` module.
- A `~/Projects` symlink on the AI server points to
  `/mnt/<user>-laptop/Projects/` (or wherever) so opencode's path
  resolution works as if the project tree were local.

**Editor configuration**:
- Zed on the laptop uses an isolated profile (`--user-data-dir`).
- The isolated profile has `agent_servers.opencode.command` pointing
  at a launcher script in `~/bin/`. The launcher SSHes to the AI
  server and runs the workstation's `opencode-session.sh`.
- Edit-prediction points at `http://<server>:11438/v1/completions`.

**Mnemory contracts (if used)**:
- The remote user has an API key in `MCP_API_KEYS` in
  `/etc/workstation/mnemory.env` on the server. Memories namespace
  by user_id keyed off that API key.

### Shape B contracts

**Network**:
- Laptop must reach the AI server in *one* of these two ways:
  - **MCP over SSH stdio** — laptop's user must be able to SSH to
    the server account that owns Library. No HTTP port needs to
    be open.
  - **MCP over HTTP** — server binds Library's HTTP transport on
    an interface the laptop reaches. Strongly recommend pairing
    this with a token-bearer auth wrapper or a private-network-only
    bind; Library has no built-in auth.
- AI server does NOT need to reach the laptop. Files stay on the
  laptop in this shape.

**System users**:
- The server account that runs Library can be unprivileged — it
  doesn't need polkit grants for the `llama-*` services since the
  laptop's opencode never asks the server to start them. The
  server owner runs the sidecar services (llama-embed,
  llama-secondary, SearxNG, docling-serve) under whatever account
  is convenient; Library reaches them by URL.

**File access**:
- Files stay on the laptop. Library reads them only if the laptop's
  opencode passes a path that exists on the server (rare — Library
  is mostly used for web research and laptop-local files in this
  shape; for a server-local file the user would typically use
  Shape A or just SSH directly).

**Editor configuration on the laptop**:
- The laptop runs its own opencode (or other MCP-aware agent).
- Library is registered in opencode.json as either a `local` MCP
  with `command: ["ssh", "<server>", "/path/to/library"]` (SSH
  stdio variant) or a `remote` MCP with the HTTP URL (HTTP
  variant). Set `LIBRARY_*_URL` env vars in opencode's `env` block
  if Library should reach sidecars on hosts other than its own
  loopback.

**Mnemory contracts (if used, on the laptop)**:
- mnemory runs on the laptop or on a third machine the laptop
  reaches. Same dim-locked-on-first-write rule applies.

### What you need on each side, by shape

**Shape A — AI server, per remote user**:
- A user account with home directory and standard shell.
- Membership in `WS_LLAMA_USERS` (polkit allowlist).
- A clone of the umbrella repo at
  `/home/<user>/Documents/Repos/2gpu-local-ai-workstation/`.
- `~/.config/workstation/user.env` pointing `WS_USER_ROOT` at that
  clone.
- `~/.config/opencode/AGENTS.md` as a copy (not symlink) of the
  canonical AGENTS.md from the clone.
- `~/.ssh/authorized_keys` containing the laptop's public key.
- `~/Projects` symlink to `/mnt/<user>-laptop/Projects/`.

**Shape A — laptop**:
- WireGuard or LAN connectivity to the AI server.
- An SSH key, with the public half installed in the AI-server
  account.
- The laptop launcher scripts (`2gpu-remote-launch`,
  `opencode-remote-session`) installed at `~/bin/`, executable.
- A Zed isolated profile with `agent_servers.opencode.command`
  pointing at `~/bin/opencode-remote-session` and
  `edit_predictions.api_url` pointing at the AI server's
  llama-coder.
- A desktop entry wrapping the launcher for one-click start.

**Shape B — AI server**:
- A user account that owns Library + its venv. Need not be the
  same account as any remote user.
- A clone of `https://github.com/JoshWrites/Library` at any
  convenient path.
- `uv sync` run; `uv sync --extra dev` if you want to run tests.
- The four sidecar services (SearxNG, llama-embed,
  llama-secondary, docling-serve) running and reachable on
  loopback.
- For SSH-stdio variant: laptop's public SSH key in this account's
  `~/.ssh/authorized_keys`.
- For HTTP variant: a wrapper that exposes Library's HTTP transport
  on a routable interface (the FastMCP server class supports HTTP;
  see Library's docs for how to invoke).

**Shape B — laptop**:
- A working opencode (or other MCP-aware agent) install.
- A chat model accessible to that agent — local llama.cpp /
  ollama, or hosted API key, or anything else opencode supports.
- `~/.config/opencode/AGENTS.md` as a copy (not symlink) of an
  AGENTS.md tuned for Library-aware agents (the umbrella's
  `configs/opencode/AGENTS.md` works as-is even when only Library
  is remote).
- opencode.json with a `mcp.library` block pointing at the server
  via SSH stdio or HTTP.

---

## Update procedure — Shape A

The procedure below covers Shape A. For Shape B see
[Update procedure — Shape B](#update-procedure--shape-b) further down.

When the AI server's umbrella repo updates (e.g. the portability
work landing on main), the remote user's installation needs to pick
up:

1. The repo clone in `/home/<user>/Documents/Repos/2gpu-local-ai-workstation/`
   (so wrapper scripts run the new code).
2. The Library submodule pointer (since umbrella commits track it
   by sha).
3. `~/.config/opencode/AGENTS.md` (the file opencode reads, as a
   copy not symlink).
4. The laptop launcher scripts in `~/bin/` (if their behavior
   changed).

What does NOT need a per-user update:
- The system-installed binaries (`opencode-patched` at
  `/usr/local/bin/`, llama.cpp builds, llama-shutdown). Those are
  shared across users and the workstation owner installs them
  once.
- The systemd unit files, polkit rule, sysctl drop-ins. Same.
- The model GGUFs in `/var/lib/llama-models/`. Same.

The procedure below is for the remote user only. Read top to bottom;
the order matters because some steps depend on earlier ones (the
AGENTS.md copy needs the repo to be on the new commit first; the
laptop launcher push needs the workstation source to be on the new
commit first).

> Replace `<user>` with the remote user's account name throughout
> (e.g. `anny`).
>
> Replace `<laptop>` with the laptop's SSH alias as configured on
> the workstation (e.g. `laptop`).

### Step 1 — workstation: update the user's umbrella clone

Run as the workstation owner. Pulls the latest umbrella into the
remote user's home and updates the Library submodule.

```bash
sudo -u <user> bash -c '
  cd ~/Documents/Repos/2gpu-local-ai-workstation
  git fetch origin
  git log --oneline HEAD..origin/main | head
  git checkout main
  git pull --ff-only origin main
  git submodule update --init --recursive
  git log --oneline -3
'
```

The `git log --oneline HEAD..origin/main | head` line shows you what
new commits are about to land. If anything looks unexpected, abort
before the `pull`.

### Step 2 — workstation: copy the new AGENTS.md into the user's opencode config

opencode reads `~/.config/opencode/AGENTS.md` as a regular file,
not following symlinks. Update it in place. Backup first.

```bash
SRC=/home/<user>/Documents/Repos/2gpu-local-ai-workstation/configs/opencode/AGENTS.md
DST=/home/<user>/.config/opencode/AGENTS.md

sudo -u <user> bash -c "
  if [[ -e $DST ]]; then
    cp $DST ${DST}.bak.\$(date +%Y%m%d-%H%M%S)
  fi
  cp -f $SRC $DST
  ls -la $DST*
  md5sum $SRC $DST
"
```

The two md5 values in the output should match. They confirm the new
file is in place.

If you have the helper script in
`private/owner-tooling/sync-anny-agents-md.sh`, that does this same
job with verification baked in:

```bash
/home/levine/Documents/Repos/2gpu-local-ai-workstation/private/owner-tooling/sync-anny-agents-md.sh
```

### Step 3 — workstation: re-run install-systemd-units.sh if the repo's systemd templates changed

If the update touched anything under `systemd/`, the polkit rule or
mnemory.service templates need to be re-rendered. Run from the
*owner's* clone (not the remote user's), with sudo:

```bash
cd /home/levine/Documents/Repos/2gpu-local-ai-workstation
sudo ./scripts/install-systemd-units.sh
```

This is idempotent. If nothing changed in the templates, it
re-installs the same content.

To check if it's needed at all:

```bash
git -C /home/levine/Documents/Repos/2gpu-local-ai-workstation log \
  --oneline --since="<last update date>" -- systemd/ scripts/install-systemd-units.sh
```

If the output is empty, you can skip this step.

### Step 4 — workstation: restart any of the user's running opencode subprocesses

opencode reads `AGENTS.md` per-turn but caches `opencode.json` for
the session. If the user has a Zed session open through the AI
server, the new AGENTS.md takes effect on the next prompt; the new
opencode.json (rendered fresh each session) takes effect on the next
launch.

To force a clean state, ask the user to close their Zed window. If
you're in a hurry, look for stale subprocesses:

```bash
sudo pgrep -af 'opencode-patched.*<user>' | head
```

Kill any that look orphaned (e.g. older than the last Zed close).

### Step 5 — laptop: update the laptop's umbrella clone (if the user has one)

If the user keeps an umbrella clone on their laptop too — useful for
reading docs and following along, but not required for the AI agent
to work — pull it on the laptop:

```bash
ssh <user>@<laptop> '
  cd ~/Documents/Repos/2gpu-local-ai-workstation
  git fetch origin
  git pull --ff-only origin main
  git submodule update --init --recursive
  git log --oneline -3
'
```

If the laptop doesn't have a clone, skip this step.

### Step 6 — laptop: redeploy launcher scripts

The launcher scripts at `~/bin/2gpu-remote-launch` and
`~/bin/opencode-remote-session` on the laptop need updating only if
their *workstation source* changed. Source lives in
`private/owner-tooling/laptop/` on the workstation.

Backup, scp, verify:

```bash
SRC_DIR=/home/levine/Documents/Repos/2gpu-local-ai-workstation/private/owner-tooling/laptop

for script in 2gpu-remote-launch opencode-remote-session; do
  echo "=== $script ==="

  # Backup
  ssh <user>@<laptop> "
    cp ~/bin/$script ~/bin/${script}.bak.\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
  "

  # Stage to /tmp with anny-readable perms (workstation owner can't scp from
  # /home/levine/private/ as anny directly — we stage in /tmp for the hop).
  STAGED=$(mktemp /tmp/${script}.XXXXXX)
  cp $SRC_DIR/$script $STAGED
  chmod 0644 $STAGED

  # Push as the remote user (their SSH key reaches the laptop)
  sudo -u <user> scp $STAGED <user>@<laptop>:bin/$script
  ssh <user>@<laptop> "chmod +x ~/bin/$script"

  rm -f $STAGED
  ssh <user>@<laptop> "ls -la ~/bin/$script*"
done
```

If the scripts didn't change in this update, skip this step. To
check:

```bash
git -C /home/levine/Documents/Repos/2gpu-local-ai-workstation log \
  --oneline --since="<last update date>" -- private/owner-tooling/laptop/
```

The owner-tooling/ path is gitignored, so this only catches changes
in your private working tree, not in commits. Compare file mtimes
against the laptop's copies if you're not sure.

### Step 7 — laptop: copy the new AGENTS.md (if the laptop has its own opencode session)

This step only applies if the laptop runs opencode locally for some
purpose (rare in this pattern — usually opencode runs on the AI
server). Skip if the laptop's opencode is exclusively the
ACP-over-SSH client.

```bash
sudo scp /home/<user>/Documents/Repos/2gpu-local-ai-workstation/configs/opencode/AGENTS.md \
  <user>@<laptop>:.config/opencode/AGENTS.md
```

### Step 8 — verify

The user's next Zed launch should pick up the new code end-to-end.
A quick sanity check from your shell:

```bash
# Confirm anny's repo is on the latest commit
sudo -u <user> git -C /home/<user>/Documents/Repos/2gpu-local-ai-workstation log --oneline -1
sudo -u <user> git -C /home/<user>/Documents/Repos/2gpu-local-ai-workstation/Library log --oneline -1

# Confirm AGENTS.md hashes match
md5sum /home/<user>/Documents/Repos/2gpu-local-ai-workstation/configs/opencode/AGENTS.md \
       /home/<user>/.config/opencode/AGENTS.md

# Confirm the launcher's mtime on the laptop is fresh
ssh <user>@<laptop> 'stat -c "%y %n" ~/bin/2gpu-remote-launch ~/bin/opencode-remote-session'
```

If anything looks off, the most informative log to read is the
launcher's terminal output: have the user start
`~/bin/2gpu-remote-launch` from a terminal (not the desktop entry)
on the laptop and watch what it prints.

---

## Update procedure — Shape B

When the Library MCP repo updates, a Shape B deployment needs to
pick up the new code on the *server side only* — Library is the
only piece on the server in this shape. The laptop's opencode and
the laptop's chat model don't need touching unless the laptop user
also wants to update those independently.

The procedure is much shorter than Shape A's because there's no
SSHFS mount, no per-user clone, no laptop launcher, no Zed isolated
profile to keep in sync.

> Replace `<server-host>` with the AI server's SSH alias from the
> laptop's perspective.
>
> Replace `<library-user>` with the account on the server that owns
> Library + its venv.

### Step 1 — server: pull the latest Library

Run as the account that owns Library on the server. SSH there from
your usual workstation if needed.

```bash
ssh <library-user>@<server-host> '
  cd ~/Documents/Repos/Library     # or wherever you cloned it
  git fetch origin
  git log --oneline HEAD..origin/main | head
  git checkout main
  git pull --ff-only origin main
  uv sync                          # picks up any pyproject.toml changes
  git log --oneline -3
'
```

The `git log --oneline HEAD..origin/main | head` line shows you
what new commits are about to land. If anything looks unexpected,
abort before the `pull`.

### Step 2 — server: restart whatever process serves Library

If Library runs on demand (spawned per-MCP-session), there is
nothing to restart — the laptop's next opencode session spawns a
fresh Library process that picks up the new code.

If Library runs as a long-lived HTTP service (e.g. via systemd or
docker), restart it:

```bash
ssh <library-user>@<server-host> 'systemctl --user restart library'
# or whatever your management mechanism is
```

### Step 3 — laptop: refresh AGENTS.md if the server's AGENTS.md changed

If the umbrella's `configs/opencode/AGENTS.md` was updated in this
push (which usually it is when Library's tool descriptions
change — they tend to ship together), pull the new file from the
server's umbrella clone (if you have one) or from
[github.com/JoshWrites/2gpu-local-ai-workstation](https://github.com/JoshWrites/2gpu-local-ai-workstation/blob/main/configs/opencode/AGENTS.md)
and copy it to `~/.config/opencode/AGENTS.md` on the laptop. The
file must be a regular file, not a symlink.

```bash
# On the laptop:
curl -fsS \
  https://raw.githubusercontent.com/JoshWrites/2gpu-local-ai-workstation/main/configs/opencode/AGENTS.md \
  > ~/.config/opencode/AGENTS.md
md5sum ~/.config/opencode/AGENTS.md
```

### Step 4 — verify

The laptop's next opencode session should pick up the new Library
code. Quick sanity check from the laptop, after starting a fresh
session in opencode:

- Ask the agent something that exercises a Library tool whose
  behavior changed (or just ask "what version of Python introduced
  tomllib in stdlib" — exercises `library_research` end-to-end).
- Tail Library's stderr on the server while you do this:
  `ssh <library-user>@<server-host> 'journalctl --user -u library -f'`
  (or whatever your log target is). Confirm the new code is what's
  actually running by looking at any new log lines or behavior
  changes in the latest commit.

---

## Generalizing to other AI servers

If you're adapting this pattern to a non-2gpu workstation:

- **The contracts above are the load-bearing parts.** Network
  topology, SSHFS reverse-mount (Shape A only), AGENTS.md as a
  copy, dim-locked embeddings — these stay the same regardless of
  which inference stack you swap in.
- **The specific scripts are not.** `2gpu-remote-launch` is tuned
  for one workstation's WoL setup, `opencode-remote-session` is
  tuned for one workstation's mount layout. If you build a new
  remote-user stack on a different inference platform, the
  launcher scripts are where most of the work goes.
- **Shape B is unusually portable.** Library is just a Python
  package with documented env-var knobs; running it on a non-2gpu
  server is mostly "set up four sidecar HTTP services, run
  `library`, point your laptop's opencode at it." If you don't
  have a homelab and don't want to build one, Shape B against a
  rented VPS that runs Library + sidecars works too — just expose
  it over SSH and skip the LAN/WireGuard part.
- **The Shape A update procedure transfers cleanly.** Steps 1-8
  don't reference 2gpu-specific paths beyond the `WS_USER_ROOT`
  convention. The "pull repo, sync agent rules, push launcher,
  verify" sequence applies to any setup with a per-user clone.

For a fresh build of a similar pattern on different hardware:

1. Start with [`remote-user-setup.md`](remote-user-setup.md) as the
   reference. It's tuned for 2gpu but the *shape* of every step
   (account, polkit, key exchange, WireGuard, Zed isolated profile)
   maps directly.
2. Replace the inference stack pieces (llama services, model
   catalog, model-swap script) with whatever your platform offers.
   The umbrella's `models.toml.example` shows how to make the model
   choices configurable from a single source of truth.
3. Keep the AGENTS.md-as-copy invariant. This trips up people
   building similar setups; opencode genuinely doesn't follow
   symlinks for global rules.
4. Test the update flow against this doc's procedure before you
   actually need it. The first time you discover that step N is
   missing for your platform should not be the day you're trying
   to ship a fix to your remote user.
