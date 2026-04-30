# Install and wire-up

How the patched opencode is built, installed, and connected to Zed on this machine.

## What's installed where

| What | Path | Owner | Purpose |
|---|---|---|---|
| Stock opencode (levine) | `~/.opencode/bin/opencode` | levine | Untouched. TUI continues to use this. |
| Stock opencode (anny) | `/home/anny/.opencode/bin/opencode` | anny | Untouched. anny's TUI / `work-opencode` use this. |
| **Patched opencode (system-shared)** | `/usr/local/bin/opencode-patched` | root, 0755 | Our build. v1.14.28 source + both patches. World-readable. Used by Zed and (optionally) anny. |
| Build artifact (levine's local) | `~/.local/bin/opencode-patched` | levine | Build output before system-install. Kept as a fallback / build staging area. |
| Build tree | `/tmp/opencode-build/opencode/` | levine | Sparse clone for rebuilding. Disposable; recreate as needed. |
| Isolated bun 1.3.13 | `/tmp/bun-1313/bin/bun` | levine | Required to build (stock bun on this machine is 1.3.11). Disposable. |
| Source patch | `docs/research/opencode-shim/pr-7374-diff.patch` | repo | The original PR #7374 diff. Reference only — does not apply cleanly to v1.14.28. |
| Adapted patch | inlined in `the-fix.md` | repo | The same logic re-applied against v1.14.28's drifted line numbers. |

## How the build is launched

**Important:** the second-opinion launcher uses an isolated Zed profile.
The Zed config that matters is **NOT** `~/.config/zed/settings.json` —
it's `~/.local/share/zed-second-opinion/config/settings.json`, because
`scripts/second-opinion-launch.sh` calls Zed with
`--user-data-dir ~/.local/share/zed-second-opinion`.

Edit the right file:

```jsonc
// ~/.local/share/zed-second-opinion/config/settings.json
"agent_servers": {
  "opencode": {
    "command": "/home/levine/Documents/Repos/Workstation/second-opinion/scripts/opencode-session.sh",
    "args": ["acp"],
    "env": {
      "OPENCODE_BIN": "/usr/local/bin/opencode-patched",
      "OPENCODE_DISABLE_CHANNEL_DB": "1"
    }
  }
}
```

(Previous default in this file was `"opencode": { "type": "registry" }`,
which downloads stock opencode v1.14.25 from the agent registry. Replacing
that block with the explicit command + env points Zed at our patched build.)

This routes through the existing `opencode-session.sh` wrapper, which:
1. Brings up the `llama-primary` / `llama-secondary` / `llama-embed` systemd services if not already running.
2. Waits for their endpoints to be reachable.
3. `exec`s `OPENCODE_BIN` (default `~/.opencode/bin/opencode`, overridden here to our patched binary) with the passed args (`acp`).

Stock TUI usage (`opencode` from a shell) is unaffected — it uses the default `OPENCODE_BIN`.

## How to rebuild from scratch

Done once already; documented here so we (or future-us) can reproduce.

```bash
# 1. Clone the source
mkdir -p /tmp/opencode-build && cd /tmp/opencode-build
git clone --depth 50 https://github.com/anomalyco/opencode.git
cd opencode
git fetch --depth 50 --tags origin
git checkout v1.14.28      # or newer, if the bug is still present there

# 2. Apply the fix (manually — patch file is reference, line numbers drift)
# See docs/research/opencode-shim/the-fix.md for the exact code block.
# Edits a single function in packages/opencode/src/acp/agent.ts.

# 3. Get a compatible bun. Build script requires >=1.3.13, system has 1.3.11.
BUN_INSTALL=/tmp/bun-1313 bash <(curl -fsSL https://bun.sh/install) bun-v1.3.13

# 4. Install workspace deps
bun install

# 5. Typecheck (sanity)
bun run typecheck

# 6. Build for current platform only (much faster than building for all targets)
cd packages/opencode
PATH="/tmp/bun-1313/bin:$PATH" /tmp/bun-1313/bin/bun run script/build.ts --single

# 7. Install (per-user staging copy)
cp dist/opencode-linux-x64/bin/opencode ~/.local/bin/opencode-patched
chmod +x ~/.local/bin/opencode-patched

# 8. System-install (shared between users; safe to run while sessions are live)
sudo install -m 0755 -o root -g root \
  ~/.local/bin/opencode-patched /usr/local/bin/opencode-patched.new
sudo mv /usr/local/bin/opencode-patched.new /usr/local/bin/opencode-patched
```

The `install` + `mv` dance is atomic. Step 8 swaps the inode under
`/usr/local/bin/opencode-patched`, so any process anny has running keeps
using the old inode until she restarts her session. Doing a plain
`cp` over the file would fail with "Text file busy" if either user
has a copy running.

Build time: ~3 minutes on this machine for `--single` (current platform only).
Binary size: ~147 MB (Bun-compiled single binary, all deps embedded).

## Pitfalls hit during this build, for next time

- **`bun add bun@1.3.13`** lands a Windows `.exe` shim in `node_modules/.bin/bun` because of how npm distributes the bun package. The shim then poisons PATH inside the build's `bun run` shell-outs. Fix: don't use `bun add bun`; use the official installer with a custom `BUN_INSTALL` dir to get the real Linux binary.
- **Bun version gate** is hard-coded in `packages/script/src/index.ts`. Don't bypass — the gate exists because the build relies on Bun runtime features that landed in 1.3.13.
- **`bun run typecheck` from the workspace root** runs all 13 packages via Turbo. That's fine; ~5s with cache cold. Per-package typecheck is faster but only proves one package.
- **The `--single` flag** is essential. Without it, the build cross-compiles for darwin-x64, darwin-arm64, linux-arm64, windows-x64, etc. — that's slow (10+ minutes) and produces binaries you won't use.

## anny's opt-in (optional, no rush)

anny's `work-opencode-launch` defaults to `$HOME/.opencode/bin/opencode` — her own stock install. To pick up the patched binary, set `OPENCODE_BIN` in her launcher invocation:

```bash
# from anny's laptop
ssh -t anny@levine-positron OPENCODE_BIN=/usr/local/bin/opencode-patched work-opencode-launch
```

Or, if she wants it permanent, add `export OPENCODE_BIN=/usr/local/bin/opencode-patched` to her `~/.profile` on the workstation. The launcher's existing `${OPENCODE_BIN:-...}` default-or-override pattern (line 22 of the script) means no script change is needed.

She doesn't need this for the TUI — the bug is specific to ACP-via-Zed and doesn't affect terminal sessions. Only worth opting in if she ever tries opencode through Zed.

## How to revert

If anything goes wrong:

```bash
# Revert Zed config — restore the agent_servers block in
# ~/.local/share/zed-second-opinion/config/settings.json to:
#   "agent_servers": { "opencode": { "type": "registry" } }
# Zed falls back to the registered opencode (registry entry:
# anomalyco/opencode v1.14.25, downloaded on demand).

# To uninstall the system-shared binary:
sudo rm /usr/local/bin/opencode-patched

# To remove the per-user staging copy:
rm ~/.local/bin/opencode-patched
```

Stock opencode and the TUI flow for both users are completely unaffected
by any of this.
