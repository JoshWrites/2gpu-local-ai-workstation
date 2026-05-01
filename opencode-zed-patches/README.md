# opencode-zed-patches

Source patches and an installer for a small fork of opencode that fixes
the tool-call permission UX in Zed.

## What this does

Stock opencode in a Zed agent panel asks for permission to run a tool
but does not always show what the tool will do. For bash this means an
empty box where the command should be. For file-write/edit/read it
means a bare tool name with no path - especially when the model
(typical for small local models like GLM-4.7-Flash) skips the optional
`description` argument. Either way the user has no way to approve or
deny informedly.

Three patches in this repo fix that:

- **agent.ts patch.** Looks up the actual tool input from the message
  store before sending the permission request, then derives a two-line
  title: the verbatim subject (command for bash, `<tool> <path>` for
  write/edit) on line 1 and the model-supplied `description` on
  line 2. The Zed permission card now shows what is about to happen
  in concrete terms.
- **bash.ts patch.** Renders working-directory and command text on the
  permission card via the ACP `_meta.terminal_info` convention, plus
  streams terminal output back to Zed during execution. The card looks
  and behaves like a real terminal.
- **tools.ts patch.** Adds a required `description` parameter to the
  `write` and `edit` tool schemas (mirroring `bash`). With `--jinja`
  on, llama.cpp's grammar-constrained sampling forces the model to
  emit a description on every call, so the second line of the
  permission title is reliable - not a request the model can skip on
  a tight turn.

Apply the patches, rebuild opencode from source, install the resulting
binary alongside the upstream one, and point Zed at the patched binary.
Stock opencode stays available; the patched build only runs when Zed
asks for it.

## What you need before you start

- A working opencode source clone (see https://github.com/sst/opencode).
  These patches target opencode v1.14.28. They may apply cleanly to
  later versions; rebase if not.
- bun and the build prerequisites opencode itself documents.
- A Zed install with the agent-servers feature, configured to run an
  ACP-compatible agent.

## How to install

The full procedure with terminal copy-paste lines lives in
`install-and-wire.md`. The short version:

1. Clone opencode at the v1.14.28 tag.
2. Apply `our-patch-agent.diff` and `our-patch-bash.diff` to the source
   tree.
3. Build the patched binary with `bun build`.
4. Install the result at `/usr/local/bin/opencode-patched` (or another
   path of your choosing; the exact location only matters as the value
   you set for `OPENCODE_BIN`).
5. Point Zed at the patched binary by setting `OPENCODE_BIN` in the
   `agent_servers.opencode.command.env` block of your Zed settings.json.
6. Restart Zed and open an agent thread.

The included `test-the-fix.sh` script smoke-tests the result by running
opencode against a captured ACP fixture and confirming the permission
flow now carries command text.

## What to do when it does not work

A few real failure modes:

- **Patch fails to apply.** opencode's source has moved since v1.14.28.
  Pin to the v1.14.28 tag, or rebase the patches by hand against newer
  source. The diff context is small and the rebase is usually
  mechanical.
- **Build succeeds but Zed still shows an empty permission card.** Zed
  is still running the unpatched binary. Confirm `OPENCODE_BIN` is set
  in Zed's `agent_servers.opencode.command.env` block, then fully
  restart Zed (close window and reopen, not just reload).
- **Permission card shows the command but Zed rejects after approval.**
  Different bug, not this one. Check Zed's log for the actual error.
- **Terminal output not streaming during command execution.** That is
  the bash.ts side of the fix. Confirm both patches applied; the
  terminal-streaming behavior depends on the bash.ts changes, not the
  agent.ts changes.

## What this repo holds

- `our-patch-agent.diff`: the agent.ts patch.
- `our-patch-bash.diff`: the bash.ts patch.
- `our-patch-tools.diff`: the write/edit schema patch (and matching
  test fixtures).
- `the-fix.md`: a plain-language description of the agent.ts patch and
  why it works.
- `fix-2-shipped.md`: the production state after the bash polish landed
  (cwd header, literal-command title, terminal streaming).
- `fix-3-shipped.md`: the file-tool fallback that landed when GLM
  sampler tuning exposed a missing path-based title path.
- `fix-4-shipped.md`: the schema-required `description` for write and
  edit, plus a two-line `<tool> <path>` + description card title.
- `fix-5-shipped.md`: 15-line code preview on the approval card,
  rendered via fenced markdown with language-tagged syntax
  highlighting.
- `install-and-wire.md`: full install procedure.
- `test-the-fix.sh`: smoke test against a captured fixture.

## Why this is two patches

Fix 1 (agent.ts) makes the permission card show the command. That alone
fixes the original silent-rejection bug.

Fix 2 (bash.ts) adds the cwd header, the literal-command title that
stays through the lifecycle, and terminal output streaming. That makes
the card feel like a terminal in Zed's UI.

You can ship Fix 1 alone and have a working stack. Fix 2 is polish.
The combined patches are the production state.

## Background

The research narrative behind these patches lives in the umbrella
repo's `docs/research/opencode-zed-patches/` directory: the source
walk that found the bug, the five options considered before settling
on a local-patch approach, the upstream PR (#7374) we read but did
not pursue, the race condition we found while building Fix 2, and
the planning notes that informed each fix. Read those files for the
why; the files in this repo are the what.

## Status

Both patches are in production on the author's workstation as of
2026-05-01. Stock opencode v1.14.28 plus the two diffs (agent.ts now
including the fix-3 file-tool fallback), built and installed at
`/usr/local/bin/opencode-patched`. Zed in a per-project isolated
profile points at it via `OPENCODE_BIN`.

These patches are not submitted upstream. PR #7374 covered roughly the
same ground earlier and was closed without comment; the upstream path
appears open but has not been actively pursued. Anyone who wants to
land this work upstream is welcome to use the diffs as a starting
point.
