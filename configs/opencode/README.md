# opencode global config

The agent rules and provider config that opencode reads at startup.
Tracked here so they survive a machine rebuild and so changes are
reviewable.

## Files in this directory

- `AGENTS.md` - global agent rules. Tells the model how to use the
  Library MCP, which tool to prefer for which job, how the
  two-layer return contract works.
- `opencode.json` - provider config (which llama-server endpoints,
  which models, which MCP servers), permission rules for bash and
  edit tools.
- `README.md` - this file.

Other files at `~/.config/opencode/` are not tracked. The existing
`.gitignore` lists them: `node_modules/`, `bun.lock`, `package.json`,
state files like `opencode-notifier-state.json`.

## How the symlink pattern works

opencode reads its config from `~/.config/opencode/`. The two tracked
files in this directory are symlinked into that location.

To verify the symlinks:

```
ls -la ~/.config/opencode/AGENTS.md ~/.config/opencode/opencode.json
```

You should see arrows pointing into this directory.

## Setting up on a new machine

After cloning the umbrella repo:

```
cd ~/Documents/Repos/Workstation/second-opinion/configs/opencode
ln -sf "$(pwd)/AGENTS.md" ~/.config/opencode/AGENTS.md
ln -sf "$(pwd)/opencode.json" ~/.config/opencode/opencode.json
```

opencode picks up the rules and config on its next launch.

## Pre-publish work

Before this directory ships in a public repo, two things need to
happen:

1. The `permission.bash` block in `opencode.json` lists literal SSH
   targets like `josh@10.100.102.50`. Replace with env-var references
   (e.g. `${WS_SSH_REMOTE_USER}@${WS_SSH_REMOTE_HOST}`) and document
   the env-file pattern. Tracked as part of Phase 1 env-ification.
2. Sweep `AGENTS.md` for non-ASCII characters and tighten prose to
   the project writing standards. Tracked for the language pass.

Both items are organizational holds, not bugs. The current files work
on this machine as-is. Do not push to a public remote until both are
done.
