# How to patch opencode

Notes from extending the opencode fork after the original fix-1/fix-2
patches landed -- the time-tested procedure for adding a new patch to
the stack, the hooks that turned out to be load-bearing, and the
mistakes that cost time.

Most of this is rediscovery from the May 2026 session that added
`our-patch-skill-permission.diff`. The process is documented here so
the next patch does not start from scratch.

---

## What you are working with

The opencode source tree at `/tmp/opencode-build/opencode/` (sparse
clone of `anomalyco/opencode`, checked out at `v1.14.28` for this
fork). The umbrella repo's `opencode-zed-patches/` directory carries:

- One `our-patch-*.diff` per concern -- agent, bash, tools,
  skill-permission. Each patch targets a small set of files and is
  meant to be reviewable on its own.
- `install-and-wire.md` lists the patches in apply order. Order
  matters when patches touch the same file -- agent-patch is the
  largest and goes first.
- `README.md` describes the user-visible behavior each patch fixes.

The build pipeline produces a single binary at
`/usr/local/bin/opencode-patched`, world-readable so any local user
(yourself, a second user on the same workstation, a remote user
SSHing in) can run it. Zed's
`agent_servers.opencode.command.env.OPENCODE_BIN` points at that
path, so no per-user binary install is needed.

---

## The minimum working loop

Every patch goes through the same five steps. Once you have done one
end-to-end you can move quickly; the first time, do each step
deliberately because failures look like different problems than they
are.

### 1. Reset the build tree to a known baseline

```bash
cd /tmp/opencode-build/opencode
git checkout -- packages/
```

This is the safest starting point. Anything left over from a previous
build attempt -- partial patches, conflict markers, stash residue --
is wiped. A clean tree at the `v1.14.28` tag is the baseline every
patch is written against.

### 2. Apply the existing patches in order

```bash
cd /tmp/opencode-build/opencode
for p in our-patch-agent our-patch-bash our-patch-tools our-patch-skill-permission; do
  git apply "/path/to/2gpu-local-ai-workstation/opencode-zed-patches/${p}.diff"
done
```

Plain `git apply` -- not `git apply --3way`. The 3-way mode chases
conflicts that do not exist when the baseline is clean, and will
leave the tree in an unmerged state if a patch fails for any reason.
Spent considerable time tonight unwinding 3-way's "helpful" mess
before realizing the patches apply cleanly without it.

If you are *adding* a new patch, stop after applying the existing
three (or however many already exist) and keep the resulting state
as your baseline.

### 3. Edit the source files directly

Use the editor tools, not `git diff`-and-iterate. Open the file,
find the function, write the change. The diff comes later as a
*derivative* of the edit.

Hooks that turned out to matter:

- **`packages/opencode/src/acp/agent.ts`** -- the ACP server. Title
  resolver, permission card formatter, session lifecycle, tool-call
  forwarding. Most opencode-Zed UX bugs live here.
- **`packages/opencode/src/tool/<name>.ts`** -- per-tool definitions.
  Add `description` parameters here, populate `metadata` on
  `ctx.ask()`, change tool output shape. Three tools currently
  patched (`bash`, `edit`, `write`); skill is the fourth.
- **`packages/opencode/src/permission/index.ts`** -- the rule
  evaluator. Read this to understand why a permission gate did or
  didn't fire. Has not needed editing yet.
- **`packages/opencode/src/skill/index.ts`** -- skill discovery,
  `EXTERNAL_DIRS = [".claude", ".agents"]` and the
  `EXTERNAL_SKILL_PATTERN` constant. Worth knowing about, has not
  needed editing.
- **`packages/opencode/src/session/system.ts`** -- the system prompt.
  This is where skills get advertised to the model (descriptions
  only, not content). Worth reading if a feature seems to depend on
  what the model knows about; has not needed editing.

### 4. Build and smoke test

```bash
cd /tmp/opencode-build/opencode
PATH="/tmp/bun-1313/bin:$PATH" /tmp/bun-1313/bin/bun run typecheck
cd packages/opencode
PATH="/tmp/bun-1313/bin:$PATH" /tmp/bun-1313/bin/bun run script/build.ts --single
```

`typecheck` runs in seconds when only opencode itself changed (12 of
the 13 tasks cache hit; only the `opencode` task recompiles). It
catches the trivial mistakes -- typos, wrong-type fields, missing
imports -- before the slow `bun run script/build.ts --single` step,
which takes a few minutes and ends with a bun-bundled binary at
`packages/opencode/dist/opencode-linux-x64/bin/opencode`.

The build's last line is

```
Smoke test passed: 0.0.0--<datestamp>
```

If you see that, the binary at least starts and reports a version. It
does not mean your patch is correct -- the actual UX has to be tested
in Zed -- but it does mean the change compiled and links cleanly.

### 5. Install and reload

```bash
cp /tmp/opencode-build/opencode/packages/opencode/dist/opencode-linux-x64/bin/opencode \
   /home/<you>/.local/bin/opencode-patched
chmod +x /home/<you>/.local/bin/opencode-patched

sudo cp /home/<you>/.local/bin/opencode-patched /usr/local/bin/opencode-patched
sudo chmod 0755 /usr/local/bin/opencode-patched
```

Zed reads the binary path from its profile settings, but it caches
the *running process*, not the file. Restart the Zed agent panel
(close-and-reopen Zed, or whatever your equivalent for terminating
the opencode-acp child is) before re-testing. The previous opencode
process keeps running with the old binary code in memory until it
exits.

`/usr/local/bin/opencode-patched` is system-wide, so any other user
on the workstation gets the new build the moment they start a new
Zed session. No per-user install.

---

## Generating the diff

After the change is verified working, the source-tree edits get
captured as a `.diff` file in the umbrella repo. Two things to know.

### What the diff is built against

The diff for a *new* patch is built against "all previous patches
applied, mine on top." Not against pristine upstream.

```bash
cd /tmp/opencode-build/opencode

# Save your edits
cp packages/opencode/src/<file> /tmp/<file>-with-fix.ts

# Reset, apply only the existing patches (not yours)
git checkout -- packages/
git apply our-patch-agent.diff
git apply our-patch-bash.diff
git apply our-patch-tools.diff
# DO NOT apply yours yet

# Snapshot the baseline
cp packages/opencode/src/<file> /tmp/<file>-base.ts

# Restore your edits
cp /tmp/<file>-with-fix.ts packages/opencode/src/<file>

# Diff baseline against your edits
diff -u --label "a/<path>" --label "b/<path>" \
  /tmp/<file>-base.ts packages/opencode/src/<file> > our-patch-<name>.diff
```

This produces a small focused diff that contains only your changes,
listed against the same baseline you developed against. When the next
person applies all four patches in order, your patch's hunks land on
exactly the lines they expect.

### Sanity check on a fresh tree

Always validate the diff applies cleanly from a true baseline before
calling it done:

```bash
git checkout -- packages/
for p in our-patch-agent our-patch-bash our-patch-tools our-patch-<name>; do
  git apply "$p.diff" && echo "$p OK" || echo "$p FAIL"
done
```

Any FAIL means the diff was built against a wrong baseline, or the
order is wrong, or you accidentally rebased on top of mid-build
state. Go back to step 2 and rebuild the diff.

---

## Which hook to patch (a small playbook)

Each opencode UX problem turns out to live in a different layer.
Picking the right one matters because patches in the wrong layer
either fail to fire or cause subtle pollution.

### "The model emits a tool call, opencode rejects/fumbles it"

Patch the *tool definition*, not the agent. Example: stock opencode's
`write` and `edit` tools did not require a `description` parameter,
so the model sometimes skipped it, leaving Zed's permission card
title blank. Fix: add `description: Schema.String.annotate(...)` to
the tool's `Parameters` struct (`tool/edit.ts`, `tool/write.ts`).
With grammar-constrained sampling, the local model is now forced to
include a description on every call. Lives in `our-patch-tools.diff`.

### "The model's tool args are correct but the UI rendering is wrong"

Patch the *agent.ts permission card resolver*. Example: the skill
tool already forced `permission: "skill"` on `ctx.ask()`, but stock
sent `metadata: {}` -- so the title resolver downstream had nothing
to render and produced a card titled `skill` with no body. Fix:
populate `metadata` with description + token estimate at the tool
site, then teach the resolver in `agent.ts` to recognize
`permission.permission === "skill"` and produce a meaningful headline.
Lives in `our-patch-skill-permission.diff`.

### "The user's intent never reaches the model in the first place"

Patch the *system prompt builder* in `session/system.ts`. Has not
been needed yet but worth knowing about. The skill list is built
here, MCP tool advertisements are built here, the agent's role
prompt is built here.

### "The runtime never even fires the gate"

Check `permission/index.ts`. Permissions evaluate against the
ruleset; if the rule resolves to `allow` for a given permission name,
the `ask` flow short-circuits and the ACP server never sees a
`requestPermission` event. Tonight's skill-permission ask only
worked after adding `"skill": "ask"` to the rendered opencode.json's
`permission` block -- without it, the default `"*": "allow"` made
the gate silently inert. Fix is in the *config*, not in code.

---

## Mistakes that cost time tonight

### `git apply --3way` on a clean baseline

3-way is for resolving conflicts when patches don't quite fit -- not
for clean applies. It found "conflicts" in pristine code and left
agent.ts in an unmerged state, which then broke the next patch's
apply, which broke the diff generation. Plain `git apply` is the
right tool when patches are well-maintained against a known tag.

### Building the diff against the wrong baseline

When generating a new patch's diff, the baseline must be "previous
patches applied, mine NOT yet applied." If you accidentally include
your changes in the baseline, the diff is empty. If you exclude the
previous patches from the baseline, the diff reports their changes
as yours, and applying it elsewhere will conflict against the
already-applied previous patches.

The cleanest procedure is the multi-step one in "What the diff is
built against" above. Resist the urge to use `git diff HEAD` or any
shortcut; the build tree's HEAD is upstream, which is the wrong
reference.

### Assuming `permission.metadata` reaches the title resolver

It does not, by default. The resolver builds its `md` variable from
the *tool's call arguments* (`toolInput`), not from
`permission.metadata`. For tools whose only declared parameter is
`name` (skill), the description and token estimate had to be merged
in explicitly. The patch handles this by spreading
`permission.metadata` over `toolInput`. Without that merge, every
field you populated in the tool's `ctx.ask` metadata is invisible.

### Trying to put descriptions in the title

Zed's permission card title is single-line for non-`execute` kinds
and adds an ellipsis when long. A title like
`"Load skill: X (~N tokens)\n<description>"` flattens to one line
and clips. The right place for descriptions is a separate
`type: "content"` block in the `requestPermission` payload --
exactly the pattern the existing `our-patch-agent.diff` uses for
write/edit's description body.

### Forgetting Zed caches the running opencode process

Editing `/usr/local/bin/opencode-patched` does not affect a Zed
session that already launched it. The opencode-acp child has the
old code in memory. Always restart Zed's agent panel after a patched
binary install before re-testing.

---

## Future patches: where to start

A new patch generally starts with one of three observations:

1. **A permission card looks wrong.** Search for the tool's
   `ctx.ask` call, check the `metadata` it sends, then trace it to
   the `agent.ts` resolver. Most cards-look-wrong bugs are split
   between those two files.

2. **The agent calls a tool the user wishes it would not call (or
   stopped at).** Look at the tool's `permission:` key and whether
   the rendered opencode.json has a matching `"<key>": "ask"` entry.
   If not, the rule defaults to `allow` and the gate never fires.

3. **The model misses a feature opencode advertises.** Check
   `session/system.ts` to see how the feature is described to the
   model, then check the tool's `description` text annotations.

For any of those: read the relevant file in the build tree first,
write the change, build, install, reload Zed, verify in the actual
permission card or behavior. Generate the diff last. Commit the diff
plus a README/install-and-wire update describing the new patch's
purpose.

The four-patch stack is meant to grow. Keep each patch focused on
one user-visible concern; resist bundling unrelated improvements into
one diff. When two issues genuinely depend on each other, document
the dependency in the patch's commit message and in
install-and-wire.md.
