# Install and wire-up

How to build the patched opencode, install it, and wire Zed to use it.

## What gets installed where

| What | Path | Purpose |
|---|---|---|
| Stock opencode | `~/.opencode/bin/opencode` | Untouched. Your TUI usage continues to use this. |
| Patched opencode (this repo's output) | `/usr/local/bin/opencode-patched` | The build with both diffs applied. World-readable so Zed can run it. |
| Build artifact (per-user staging) | `~/.local/bin/opencode-patched` | Build output before the system install. Useful as a fallback. |
| Build tree | `/tmp/opencode-build/opencode/` | Sparse clone for rebuilding. Disposable. |
| Isolated bun 1.3.13 | `/tmp/bun-1313/bin/bun` | Required to build (stock bun on most distros lags behind). Disposable. |
| Source patches | `our-patch-agent.diff`, `our-patch-bash.diff`, `our-patch-tools.diff`, `our-patch-skill-permission.diff`, `our-patch-router-swap-v3.diff` | Five diffs in this repo. Apply in order against opencode v1.14.28. |

> Note: `our-patch-router-swap-v3.diff` supersedes both v1 and v2.
> v1 and v2 are kept in the repo for historical reference but are
> not applied.

## How Zed picks up the patched binary

Zed's `agent_servers.opencode.command.env.OPENCODE_BIN` is the override.

If you launch Zed in an isolated profile (e.g., a workstation-wide
"second-opinion" profile), the config that matters is **not**
`~/.config/zed/settings.json`. It is the isolated profile's
settings.json, typically at
`~/.local/share/<your-profile-name>/config/settings.json`.

Edit the right file:

```jsonc
"agent_servers": {
  "opencode": {
    "command": "/path/to/opencode-session.sh",
    "args": ["acp"],
    "env": {
      "OPENCODE_BIN": "/usr/local/bin/opencode-patched",
      "OPENCODE_DISABLE_CHANNEL_DB": "1",
      "OPENCODE_MODEL_SWAP_SCRIPT": "/path/to/scripts/model-swap.sh"
    }
  }
}
```

(The default Zed config for opencode is `"opencode": { "type":
"registry" }`, which downloads stock opencode from Zed's agent
registry. Replacing that block with an explicit command + env points
Zed at your patched build.)

The `command` value typically chains through a wrapper script
(opencode-session.sh in this stack) that brings up local llama
services and waits for endpoints before exec-ing the binary. If you
have no wrapper, point `command` directly at the binary path.

## How to rebuild from scratch

```bash
# 1. Clone the source
mkdir -p /tmp/opencode-build && cd /tmp/opencode-build
git clone --depth 50 https://github.com/anomalyco/opencode.git
cd opencode
git fetch --depth 50 --tags origin
git checkout v1.14.28      # or newer, if the bug is still present

# 2. Apply the patches
git apply /path/to/this/repo/our-patch-agent.diff
git apply /path/to/this/repo/our-patch-bash.diff
git apply /path/to/this/repo/our-patch-tools.diff
git apply /path/to/this/repo/our-patch-skill-permission.diff
git apply /path/to/this/repo/our-patch-router-swap-v3.diff

# 3. Get a compatible bun. The build script requires bun >= 1.3.13.
BUN_INSTALL=/tmp/bun-1313 bash <(curl -fsSL https://bun.sh/install) bun-v1.3.13

# 4. Install workspace deps
bun install

# 5. Typecheck (sanity)
bun run typecheck

# 6. Build for current platform only (much faster than all targets)
cd packages/opencode
PATH="/tmp/bun-1313/bin:$PATH" /tmp/bun-1313/bin/bun run script/build.ts --single

# 7. Install (per-user staging copy)
cp dist/opencode-linux-x64/bin/opencode ~/.local/bin/opencode-patched
chmod +x ~/.local/bin/opencode-patched

# 8. System-install (atomic; safe while sessions are live)
sudo install -m 0755 -o root -g root \
  ~/.local/bin/opencode-patched /usr/local/bin/opencode-patched.new
sudo mv /usr/local/bin/opencode-patched.new /usr/local/bin/opencode-patched
```

The `install` + `mv` dance is atomic. Step 8 swaps the inode under
`/usr/local/bin/opencode-patched`, so any process already running
keeps using the old inode until that process restarts. Doing a plain
`cp` over the file would fail with "Text file busy" if either user
has a copy running.

Build time: roughly 3 minutes on a modern desktop for `--single`
(current platform only). Binary size: roughly 147 MB (bun-compiled
single binary, all deps embedded).

## Pitfalls

- **`bun add bun@1.3.13` lands a Windows .exe shim** in
  `node_modules/.bin/bun` because of how npm distributes the bun
  package. The shim poisons PATH inside the build's `bun run`
  shell-outs. Fix: do not use `bun add bun`. Use the official
  installer with a custom `BUN_INSTALL` dir to get the real Linux
  binary, as in the steps above.
- **Bun version gate** is hard-coded in
  `packages/script/src/index.ts`. Do not bypass; the gate exists
  because the build relies on bun runtime features that landed in
  1.3.13.
- **`bun run typecheck` from the workspace root** runs all 13
  packages via Turbo. That is fine, roughly 5 seconds cold. Per-
  package typecheck is faster but only proves one package.
- **The `--single` flag is essential.** Without it, the build cross-
  compiles for darwin-x64, darwin-arm64, linux-arm64, windows-x64,
  and others. Slow (10+ minutes) and produces binaries you do not
  need.

## Multi-user notes

If two users share the workstation and both want the patched binary,
the system-install at `/usr/local/bin/opencode-patched` is
world-readable. The second user can opt in by setting
`OPENCODE_BIN=/usr/local/bin/opencode-patched` in their environment
or wrapper script. Their stock TUI usage at
`~/.opencode/bin/opencode` is unaffected.

The bug this repo fixes is specific to ACP-via-Zed and does not
affect terminal sessions. A user who only runs opencode in a TUI
does not need the patched binary.

## How to revert

```bash
# Revert Zed config: restore the agent_servers block to the registry default
#   "agent_servers": { "opencode": { "type": "registry" } }
# Zed falls back to the registered opencode (registry entry: stock
# upstream, downloaded on demand).

# Uninstall the system-shared binary:
sudo rm /usr/local/bin/opencode-patched

# Remove the per-user staging copy:
rm ~/.local/bin/opencode-patched
```

Stock opencode and the TUI flow are unaffected by any of this.
