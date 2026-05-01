# Install

End-to-end setup procedure for the umbrella. Follow top to bottom.
Each step is small and has a verification line. Where a step has
deeper context, the step links to the relevant reference doc; you
can read that on the side or skip it and trust the procedure.

## What you are installing

When this procedure finishes, your machine will have:

- llama.cpp built with Vulkan, installed system-wide.
- Four GGUF models on disk in a system-shared catalog.
- Three workstation env files (system, user, secrets) installed at
  their canonical locations.
- Four `llama-*.service` systemd units installed (not enabled).
- A polkit rule granting your user passwordless start/stop on those
  units.
- The polite-shutdown coordinator at `/usr/local/bin/llama-shutdown`.
- A patched opencode binary at `/usr/local/bin/opencode-patched`.
- An isolated Zed profile pointed at the patched binary and the
  local llama coder endpoint.
- A desktop entry that brings the stack up on icon click.

The system-level pieces (units, polkit, sysctl, binaries under
`/usr/local`) are owned by root. The user-level pieces (env file
overrides, opencode config, Zed profile) are owned by the user.

## Prerequisites

The procedure below assumes everything in this list is already
installed and working. If anything here is missing, install it
through your distribution's package manager before starting step 1.

**Hardware:**

- An AMD primary GPU with at least 16 GB of VRAM (24 GB recommended;
  the documented stack is sized for 24 GB).
- An AMD secondary GPU with 8 GB of VRAM. Both AMD; nothing in this
  procedure works for NVIDIA.

**Operating system:**

- Ubuntu 24.04 or a similar Linux distribution. systemd 255 or later.
- A working desktop environment that supports `.desktop` entries.

**Drivers and runtimes:**

- Mesa with the Vulkan loader (`vulkan-tools`, `mesa-vulkan-drivers`).
  Verify with `vulkaninfo --summary` -- both GPUs must be listed as
  Vulkan devices.
- ROCm 7.2 or later. Required because some launcher and bench
  scripts call `rocm-smi` to read VRAM. The inference path does not
  use ROCm directly, but the diagnostic path does. Verify with
  `rocm-smi --showmeminfo vram`.
- AMD GPU drivers loaded (`amdgpu` kernel module). Verify with
  `lsmod | grep amdgpu`.

**Build toolchain:**

- A C/C++ build environment (`build-essential`, `cmake`, `git`, `curl`).
- Vulkan headers and development libraries (`libvulkan-dev`,
  `glslc` from `glslang-tools`).
- Headers and library for the GPU compute layer
  (`libomp-dev` if you want OpenMP, optional).
- Python 3 (system or via uv; the bench scripts use Python 3.10+).

**Userland tools:**

- `jq`, `curl`, `ss` (from `iproute2`), `pgrep` and `ps` (from
  `procps-ng`).
- `yad` (for the launcher splash; optional but recommended).
- `notify-send` (from `libnotify-bin` or your DE's equivalent).
- `envsubst` (from `gettext`).
- `node` (Node.js, for one validation step in the regression
  script's JSONC parsing).
- `pandoc` (required by the Library MCP's `library_export` tool, which
  converts markdown to docx/odt/html/epub/rtf/latex). Install via
  `sudo apt install pandoc`. Optional: `texlive-xetex` if you want
  `library_export` to also produce PDF (`sudo apt install texlive-xetex`).

**Editor and runtime:**

- Zed editor at `~/.local/bin/zed`. The `2gpu-launch.sh` script
  hardcodes that path; if you have Zed installed elsewhere, edit
  the `ZED_BIN` line in the script.
- `bun` runtime version 1.3.13 or later. Required for the opencode
  build step. The procedure installs an isolated bun for that
  build, so the system bun version is not load-bearing for the
  install -- but you need a bun somewhere on PATH for runtime
  invocations of opencode itself.
- `uv` (Python package manager from Astral). Required to run the
  Library MCP. Install per their docs (`curl -LsSf
  https://astral.sh/uv/install.sh | sh`); the resulting binary
  typically lives at `~/.local/bin/uv`.

**Disk:**

- ~120 GB free on the partition that will hold `/var/lib/llama-models`.
  The default model set is ~16 GB; the rest is headroom for
  alternate models and KV-cache disk persistence.

**Permissions:**

- Sudo access on the workstation. The systemd units, polkit rule,
  and sysctl drop-in all install to system locations. The
  `install-systemd-units.sh` script uses `sudo install` for those
  steps; you will be prompted for your password unless you have
  passwordless sudo configured.

**Optional but documented:**

- `gh` (GitHub CLI) if you want to clone with the umbrella's
  authenticated remote pattern.
- A working SearxNG instance if you want web research through the
  Library MCP. Not required for the basic stack to come up.

## Install order

### Step 1: Clone the umbrella

```
git clone --recurse-submodules \
  https://github.com/JoshWrites/2gpu-local-ai-workstation.git \
  ~/Documents/Repos/2gpu-local-ai-workstation
cd ~/Documents/Repos/2gpu-local-ai-workstation
```

The `--recurse-submodules` flag pulls the Library submodule along
with the umbrella. If you forgot the flag, run `git submodule
update --init` from the repo root.

**Verify:** `ls Library/` should show `pyproject.toml`, `library/`,
`docs/`, `bench/`, etc. If `Library/` is empty, the submodule did
not pull.

### Step 2: Build llama.cpp with Vulkan

llama.cpp is a separate project with its own build process. The
procedure here is the minimum needed to get a Vulkan build at the
path the systemd units expect.

```
mkdir -p ~/src && cd ~/src
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
mkdir -p build && cd build
cmake -DGGML_VULKAN=ON -DLLAMA_BUILD_SERVER=ON -DCMAKE_BUILD_TYPE=Release ..
cmake --build . --config Release -j$(nproc) --target llama-server
```

That produces `build/bin/llama-server`. Install it system-wide:

```
sudo mkdir -p /usr/local/lib/llama.cpp
sudo install -m 0755 build/bin/llama-server /usr/local/lib/llama.cpp/llama-server
```

The unit files hardcode `/usr/local/lib/llama.cpp/llama-server` as
the binary path; see `docs/llama-services-reference.md` for why
that path cannot be parameterized.

**Verify:** `/usr/local/lib/llama.cpp/llama-server --version` should
print a version string. The binary should also report Vulkan support
in `--help` output (search for `--device Vulkan`).

### Step 3: Pull the model GGUFs

The default model set is documented in
`docs/llama-services-reference.md`:

| Role | Model | Path | Approx size |
|---|---|---|---|
| Primary | GLM-4.7-Flash UD-Q4_K_XL | `glm-4.7-flash/GLM-4.7-Flash-UD-Q4_K_XL.gguf` | ~10 GB |
| Secondary | Qwen3-4B-Instruct-2507 Q4_K_M | `qwen3-4b-instruct-2507/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | ~2.4 GB |
| Embed | multilingual-e5-large Q8_0 | `multilingual-e5-large/multilingual-e5-large-Q8_0.gguf` | ~0.6 GB |
| Coder | Qwen2.5-Coder-3B-Instruct Q4_K_M | `qwen2.5-coder-3b/qwen2.5-coder-3b-instruct-q4_k_m.gguf` | ~1.9 GB |

The catalog lives at `/var/lib/llama-models/`. Create the directory
and pull each model into its named subdirectory. The exact source
varies by model -- typically Hugging Face. For example, for the
primary:

```
sudo mkdir -p /var/lib/llama-models/glm-4.7-flash
sudo chown $USER:$USER /var/lib/llama-models/glm-4.7-flash
cd /var/lib/llama-models/glm-4.7-flash
huggingface-cli download <repo>/<file> --local-dir .
# or curl/wget from a direct URL
```

Repeat for each of the four model paths above. The file names in
the table are exactly what the systemd units expect.

**Verify:** `ls /var/lib/llama-models/*/` should show the four GGUF
files. The unit-file paths must match exactly; a typo here causes
"file not found" at service startup.

### Step 4: Install the env files

This step is the Phase 1 invariant for the rest of the install.
The systemd units and the launcher all read these files; they must
exist before any of the system pieces install.

```
# system.env (root-owned, world-readable, no secrets)
sudo mkdir -p /etc/workstation
sudo install -m 0644 configs/workstation/system.env.example \
                     /etc/workstation/system.env
sudo $EDITOR /etc/workstation/system.env

# user.env (per-user, paths)
mkdir -p ~/.config/workstation
install -m 0644 configs/workstation/user.env.example \
                ~/.config/workstation/user.env
$EDITOR ~/.config/workstation/user.env

# secrets.env (per-user, machine-specific values)
install -m 0600 configs/workstation/secrets.env.example \
                ~/.config/workstation/secrets.env
$EDITOR ~/.config/workstation/secrets.env
```

What to edit in each file:

- `system.env`: confirm the GPU names, Vulkan device indices, model
  paths, and ports match your hardware. The defaults match the
  umbrella's reference deployment (7900 XTX as Vulkan0, 5700 XT as
  Vulkan1) -- run `vulkaninfo --summary` if you are not sure which
  card is which device index.
- `user.env`: set `WS_USER_ROOT` to your clone path (default
  assumes `~/Documents/Repos/2gpu-local-ai-workstation`).
  Optional: set `WS_OPENCODE_SKILL_PATHS` to a colon-separated list
  of extra skill directories you want opencode to scan beyond its
  defaults (`~/.claude/skills` and `~/.agents/skills`). Useful for
  deep paths the default scan does not reach -- the superpowers
  plugin cache at
  `~/.claude/plugins/cache/claude-plugins-official/superpowers/<version>/skills`
  is a typical example. `opencode-session.sh` injects this into the
  rendered `opencode.json` under `.skills.paths` on every launch.
- `secrets.env`: set `WS_PROXMOX_USER` and `WS_PROXMOX_HOST` to
  match a remote you have SSH access to, if you use the
  opencode.json template's SSH-target permission rules. If you do
  not, leave the placeholder values; the rendered opencode.json
  will simply have unused permission entries.

For deeper context on why three files instead of one, see
`configs/workstation/README.md`.

**Verify:** all three files exist and `grep WS_PORT_PRIMARY
/etc/workstation/system.env` returns `WS_PORT_PRIMARY=11434` (or
whatever you set it to).

### Step 5: Install the systemd units, polkit rule, and llama-shutdown

The umbrella has an idempotent script for this:

```
./scripts/install-systemd-units.sh
```

What it does:

- Installs `systemd/llama-{primary,secondary,embed,coder}.service` to
  `/etc/systemd/system/`.
- Installs `systemd/llama-shutdown` to `/usr/local/bin/llama-shutdown`.
- Installs `systemd/polkit/10-llama-services.rules` to
  `/etc/polkit-1/rules.d/`.
- Installs `etc/sysctl.d/60-apparmor-namespace.conf` to
  `/etc/sysctl.d/` (works around an Ubuntu 24.04 Electron-app
  crash).
- Installs `systemd/searxng.service` to user scope (only loaded if
  you choose to enable SearxNG; the unit is a template).
- Runs `systemctl daemon-reload` for both system and user scopes.

The script asks for your sudo password once at the start. It is
safe to re-run after repo updates -- everything uses `install -m`,
which overwrites only when content changes.

For deeper context on what each piece does, see
`docs/lifecycle-management.md`.

**Verify:**

```
ls -la /etc/systemd/system/llama-*.service
ls -la /usr/local/bin/llama-shutdown
ls -la /etc/polkit-1/rules.d/10-llama-services.rules
systemctl is-enabled llama-primary.service
```

The first three should exist. `is-enabled` should report `disabled`
(intentional; services are not enabled at boot).

### Step 6: Configure the polkit rule for your user

The polkit rule ships with `allowedUsers = ["your-username-here"]`
as a placeholder. Edit it to list your actual local username (or
multiple usernames, comma-separated):

```
sudo $EDITOR /etc/polkit-1/rules.d/10-llama-services.rules
```

Find the line that reads:

```
var allowedUsers = ["your-username-here"];
```

And change it to your username:

```
var allowedUsers = ["alice"];
```

Or for multi-user setups:

```
var allowedUsers = ["alice", "bob"];
```

Save. polkit picks up rule changes without a reload.

**Verify:** as your normal user (not via sudo), run:

```
systemctl start llama-primary.service
```

It should start without prompting for a password. If it prompts, the
polkit rule is not granting passwordless start; re-check the
`allowedUsers` array spelling. Stop the service after verifying:

```
systemctl stop llama-primary.service
```

(or `llama-shutdown --force` to stop everything that started.)

### Step 7: Build the patched opencode binary

opencode is the agent runtime that Zed's agent panel talks to. The
umbrella ships two source patches that fix permission-card UX in
Zed; building opencode with the patches applied gives you a
replacement binary at `/usr/local/bin/opencode-patched` that Zed
will use.

Follow the procedure in `opencode-zed-patches/install-and-wire.md`.
The short version:

```
cd /tmp
mkdir -p opencode-build && cd opencode-build
git clone --depth 50 https://github.com/anomalyco/opencode.git
cd opencode
git checkout v1.14.28
git apply $UMBRELLA/opencode-zed-patches/our-patch-agent.diff
git apply $UMBRELLA/opencode-zed-patches/our-patch-bash.diff

# isolated bun 1.3.13 to avoid version drift
BUN_INSTALL=/tmp/bun-1313 bash <(curl -fsSL https://bun.sh/install) bun-v1.3.13

bun install
cd packages/opencode
PATH=/tmp/bun-1313/bin:$PATH /tmp/bun-1313/bin/bun run script/build.ts --single

# install
sudo install -m 0755 dist/opencode-linux-x64/bin/opencode \
                     /usr/local/bin/opencode-patched
```

`$UMBRELLA` is your clone path of `2gpu-local-ai-workstation`.

The full procedure (with each step explained, alternate paths for
revert, and pitfalls to avoid) is in
`opencode-zed-patches/install-and-wire.md`.

**Verify:** `/usr/local/bin/opencode-patched --version` should
print a version. If it prints `usage: opencode <command>` instead,
the binary is fine but you ran it without args -- that is correct.

### Step 8: Bootstrap the Library MCP

Library is a Python project that ships its own pyproject.toml. The
opencode template references it via `uv run --project <path>
library`, so all you need to do is install the venv:

```
cd Library
uv sync
```

That creates a `.venv/` inside the Library directory and installs
all dependencies. The first sync downloads several hundred MB of
Python packages.

**Verify:** `uv run --project Library library --help` should print
the Library MCP's help line. If it errors with `no such command`,
the entry point is not registered correctly; check that
`Library/pyproject.toml` lists `library = "library.server:main"`
under `[project.scripts]`.

### Step 9: Set up Zed's isolated profile

The umbrella's launcher uses an isolated Zed profile so it does not
collide with your default Zed configuration. Create the profile
directory and point Zed at the patched opencode:

```
mkdir -p ~/.local/share/zed-second-opinion/config
$EDITOR ~/.local/share/zed-second-opinion/config/settings.json
```

Minimum content:

```jsonc
{
  "agent_servers": {
    "opencode": {
      "command": "<umbrella>/scripts/opencode-session.sh",
      "args": ["acp"],
      "env": {
        "OPENCODE_BIN": "/usr/local/bin/opencode-patched",
        "OPENCODE_DISABLE_CHANNEL_DB": "1"
      }
    }
  },
  "edit_predictions": {
    "provider": "open_ai_compatible_api",
    "open_ai_compatible_api": {
      "api_url": "http://127.0.0.1:11438/v1/completions",
      "model": "qwen2.5-coder-3b",
      "prompt_format": "qwen",
      "max_output_tokens": 64
    }
  },
  "feature_flags": {
    "acp-beta": "on"
  }
}
```

Replace `<umbrella>` with your clone path.

The `agent_servers.opencode` block tells Zed to launch
`opencode-session.sh` instead of the default registry-downloaded
opencode. The `edit_predictions` block points Zed's edit-prediction
feature at the local llama-coder endpoint.

The `feature_flags.acp-beta` flag enables Zed's beta ACP UI surfaces.
Most importantly, it turns on the live context-window indicator (a
small ring with a percentage, rendered in the message-composer toolbar
next to the model picker). Opencode already emits `usage_update`
events on every turn; without the flag, Zed silently drops them and no
indicator appears. The chip turns warning-colored at >=85% used. The
flag is safe to leave on -- the variants it gates are additive and do
not change existing behavior.

For deeper context on the opencode-template flow, see
`configs/opencode/README.md`. For deeper context on the patched
binary, see `opencode-zed-patches/README.md`.

**Verify:** `cat ~/.local/share/zed-second-opinion/config/settings.json
| jq .` should parse cleanly (no syntax errors).

### Step 10: Symlink AGENTS.md into the opencode config dir

opencode reads global agent rules from `~/.config/opencode/AGENTS.md`.
The umbrella tracks the canonical version at
`configs/opencode/AGENTS.md`; symlinking lets you edit it in the
repo and have opencode pick up the changes.

```
mkdir -p ~/.config/opencode
ln -sf "$(pwd)/configs/opencode/AGENTS.md" ~/.config/opencode/AGENTS.md
```

**Verify:** `readlink ~/.config/opencode/AGENTS.md` should print
the absolute path back to the file in your clone.

The opencode.json render is automatic -- it happens every time
`opencode-session.sh` runs, sourced from the env files you
installed in step 4. You do not need to install opencode.json
manually.

### Step 11: Install the desktop entry

```
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/zed-2gpu.desktop <<EOF
[Desktop Entry]
Name=Zed (2GPU)
GenericName=Agentic Coding Editor
Comment=Brings up the 2GPU local-AI stack and opens Zed in an isolated profile
Exec=$(pwd)/scripts/2gpu-launch.sh
Icon=$HOME/.local/zed.app/share/icons/hicolor/512x512/apps/zed.png
Type=Application
StartupNotify=false
StartupWMClass=zed-2gpu
Categories=Utility;TextEditor;Development;IDE;
Actions=editor-only;

[Desktop Action editor-only]
Name=Editor only (no llama services)
Exec=$HOME/.local/bin/zed --user-data-dir $HOME/.local/share/zed-second-opinion
Icon=$HOME/.local/zed.app/share/icons/hicolor/512x512/apps/zed.png
EOF

update-desktop-database ~/.local/share/applications
```

The icon path assumes a standard Zed install. Adjust if yours is
different. The `editor-only` action is a right-click menu item that
opens Zed without starting llama services -- useful for reading
files or editing config without paying the GPU cost.

**Verify:** the entry should appear in your application menu under
the name "Zed (2GPU)". If it does not, the desktop database may
need a manual rebuild; on KDE that is `kbuildsycoca5
--noincremental`.

### Step 12: Run the regression check

The umbrella ships a 30-assertion regression script that verifies
everything is in place. Run it after step 11:

```
./bench/regression.sh
```

Expected output ends with:

```
regression: 30 passed, 0 failed
result: OK
```

What it checks:

- Required tools present (`curl`, `jq`, `python3`, `systemctl`, `ss`).
- llama-server binary present at the expected path.
- opencode-patched binary present.
- llama-shutdown present.
- Launcher present.
- Phase 1 invariant: `/etc/workstation/system.env` exists and parses.
- Each llama unit is in a state systemd recognizes.
- (When services are running) each port serves `/v1/models` with
  the expected model identifier.
- (When services are running) the coder endpoint serves
  `/v1/completions` and the embed endpoint serves `/v1/embeddings`.
- (When services are running) VRAM is within budget on both cards.
- opencode.json parses as JSON.
- Zed isolated profile settings.json parses (JSONC tolerated).
- Launcher script passes `bash -n`.
- Zed binary present.

If you run regression before the first launch, services are not
running, so the per-port checks (sections 5-9) will fail. That is
expected; do the first launch in step 13 and re-run regression
after to get a real green result.

The `--writing-lint` flag is documented but not part of the install
verification; it flags non-ASCII characters in committed text and
is informational.

### Step 13: First launch

Click the desktop icon, or run from a terminal:

```
./scripts/2gpu-launch.sh
```

What you should see, in order:

1. A yad splash window with "2GPU - starting" and a live tail of
   the primary unit's journal.
2. notify-send notifications as phases complete: ROCm devices
   discovered, tensors loaded, KV cache built, server listening.
3. After ~60 seconds, "2GPU - ready - Up in Ns. Opening Zed."
4. Zed opens in the isolated profile (window title may include
   "Zed - second-opinion" or similar).

In Zed:

- Open the agent panel (typically `Ctrl+,` or via the right-side
  panel toggle).
- Start a new opencode chat.
- Ask "What MCP tools do you have available?" -- the response should
  include `library_research`, `library_read_file`, and
  `library_get_skill`.
- Type some code in a buffer; edit-prediction should activate after
  a brief pause and offer completions.

If any of those does not work, the relevant troubleshooting section
is in the corresponding reference doc (see "Where to look when
something breaks" in each).

**Verify with regression:** while services are running, run
`./bench/regression.sh` again. All 30 checks should pass.

### Step 14: First polite shutdown

Close Zed, then:

```
llama-shutdown
```

Expected output:

```
[llama-shutdown] current client connections across all llama services: 0
[llama-shutdown] no active connections - watching for 30s to confirm idleness
......
[llama-shutdown] idle for 30s - stopping llama-* services
[llama-shutdown]   stopping llama-primary.service
[llama-shutdown]   stopping llama-secondary.service
[llama-shutdown]   stopping llama-embed.service
[llama-shutdown]   stopping llama-coder.service
[llama-shutdown] done
```

If it refuses with "X opencode/zed process(es) still alive":
investigate with `pgrep -af opencode` and `pgrep -af zed`. Usually
a stale process from before the install. Run with `--force` to
unblock; address the stale process afterward.

**Verify:** `rocm-smi --showmeminfo vram` should show the secondary
card back at near-zero used VRAM (driver overhead only) and the
primary card back at desktop-only baseline.

## You are done

The stack is installed. Daily use:

- Click the desktop icon to start a session.
- Use Zed for editing and the agent panel for opencode work.
- Run `llama-shutdown` when you are done to release VRAM.

For ongoing context:

- Lifecycle and shutdown details: `docs/lifecycle-management.md`.
- The four llama services and how to swap models:
  `docs/llama-services-reference.md`.
- The env files: `configs/workstation/README.md`.
- The opencode template: `configs/opencode/README.md`.
- The Library MCP: `Library/README.md`.
- The opencode patches: `opencode-zed-patches/README.md`.
