# Install and wire-up

How the patched opencode is built, installed, and connected to Zed on this machine.

## What's installed where

| What | Path | Purpose |
|---|---|---|
| Stock opencode binary | `~/.opencode/bin/opencode` | Untouched. The TUI continues to use this. |
| Patched opencode binary | `~/.local/bin/opencode-patched` | Our build. v1.14.28 source + the rawInput fix. Used by Zed only. |
| Build tree | `/tmp/opencode-build/opencode/` | Sparse clone for rebuilding. Disposable; recreate as needed. |
| Isolated bun 1.3.13 | `/tmp/bun-1313/bin/bun` | Required to build (stock bun on this machine is 1.3.11). Disposable. |
| Source patch | `docs/research/opencode-shim/pr-7374-diff.patch` | The original PR #7374 diff. Reference only — does not apply cleanly to v1.14.28. |
| Adapted patch | inlined in `the-fix.md` | The same logic re-applied against v1.14.28's drifted line numbers. |

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
      "OPENCODE_BIN": "/home/levine/.local/bin/opencode-patched"
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

# 7. Install
cp dist/opencode-linux-x64/bin/opencode ~/.local/bin/opencode-patched
chmod +x ~/.local/bin/opencode-patched
```

Build time: ~3 minutes on this machine for `--single` (current platform only).
Binary size: ~147 MB (Bun-compiled single binary, all deps embedded).

## Pitfalls hit during this build, for next time

- **`bun add bun@1.3.13`** lands a Windows `.exe` shim in `node_modules/.bin/bun` because of how npm distributes the bun package. The shim then poisons PATH inside the build's `bun run` shell-outs. Fix: don't use `bun add bun`; use the official installer with a custom `BUN_INSTALL` dir to get the real Linux binary.
- **Bun version gate** is hard-coded in `packages/script/src/index.ts`. Don't bypass — the gate exists because the build relies on Bun runtime features that landed in 1.3.13.
- **`bun run typecheck` from the workspace root** runs all 13 packages via Turbo. That's fine; ~5s with cache cold. Per-package typecheck is faster but only proves one package.
- **The `--single` flag** is essential. Without it, the build cross-compiles for darwin-x64, darwin-arm64, linux-arm64, windows-x64, etc. — that's slow (10+ minutes) and produces binaries you won't use.

## How to revert

If anything goes wrong:

```bash
# Revert Zed config — restore the agent_servers block in
# ~/.local/share/zed-second-opinion/config/settings.json to:
#   "agent_servers": { "opencode": { "type": "registry" } }
# Zed falls back to the registered opencode (registry entry:
# anomalyco/opencode v1.14.25, downloaded on demand).

# Or just delete the patched binary; Zed will fail to launch the agent
# until the config is also fixed.
rm ~/.local/bin/opencode-patched
```

Stock opencode and the TUI flow are completely unaffected by any of this.
