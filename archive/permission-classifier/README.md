# permission-classifier

An opencode plugin that classifies bash commands into three tiers and
routes destructive ones through a typed-confirmation MCP tool. Built
as a prototype, never deployed; the production permission policy ended
up living as static patterns in opencode.json instead.

## What this does

opencode lets a plugin intercept its `tool.execute.before` hook. This
plugin uses that hook to inspect every bash command opencode wants to
run and classify it as one of:

- **read.** Commands that observe state without changing it (`ls`,
  `cat`, `grep`, `git status`, `systemctl status`). Auto-allowed; no
  prompt.
- **write.** Mutations that are reversible with effort (`git commit`,
  `npm install`, `mkdir`). Passed through to opencode's native ask
  flow, where the user sees the standard permission card.
- **remove.** Destructive or irreversible commands (`rm`, `git push
  --force`, `dd`, `apt purge`, `docker rm`, Proxmox container
  destroys). Blocked outright with a structured error that instructs
  the agent to call a `confirm_destructive` MCP tool, where the user
  must type a verification phrase before the command can run.

Classification is **transport-independent**: SSH-prefixed commands
(`ssh host -- rm -rf /foo`) classify identically to local ones. The
plugin strips the SSH prefix before the tier match so a remote `rm`
gets the same protection as a local one.

## Why this is not in production

Two real reasons:

**The simpler approach won.** opencode's native `permission.bash`
config block accepts pattern-list rules of the same shape as the
plugin's tier definitions. After building the plugin and running it
under load, the same protection became achievable by writing the
patterns directly into `opencode.json`:

```json
"permission": {
  "bash": {
    "*": "ask",
    "ls *": "allow",
    "rm *": "ask",
    "rm -rf *": "deny",
    "ssh user@host rm -rf *": "deny"
  }
}
```

That config-file approach is in production today. The plugin is
vendored as reference for anyone who wants the tier-classification
shape with the SSH-stripping behavior, but they will probably reach
for the static config first.

**The confirm_destructive MCP it depends on does not exist yet.** The
plugin's "remove" tier instructs the agent to call
`confirm_destructive_confirm` when blocked. That MCP server was
designed alongside this plugin but never shipped; the user's
safe-bash MCP work is paused. Without the destination MCP, the
plugin's blocking behavior dead-ends.

## When you might still want this

The plugin is published as code, not as advice. Reasons you might
prefer it over the static config:

- You want SSH-transport-independent classification. The static
  config can list specific SSH targets but cannot intrinsically
  recognize that `ssh host -- rm` is morally the same as `rm`.
- You want a typed-phrase confirmation flow, not just allow/ask/deny.
  This requires the `confirm_destructive` MCP, which is not in this
  repo.
- You want to extend the tier set beyond three (e.g., add a
  "network-side-effect" tier for commands that hit external APIs).
  Easier to extend code than the static-config flat list.

If your use case is "make `rm -rf` denied by default and `ls`
auto-approved," skip this plugin and use the static config in
opencode.json. Less moving pieces.

## What you need before you start

- An opencode install. The plugin targets the v1.x ACP plugin API.
- bun (opencode's runtime). Plugins are loaded as modules at
  opencode startup.
- The `confirm_destructive` MCP server registered in opencode.json,
  if you want the typed-phrase block-and-instruct flow to actually
  reach a working tool. See "Why this is not in production" above.

## How to install

1. Drop this directory at `~/.config/opencode/plugins/permission-classifier/`
   (or anywhere opencode resolves plugins from).
2. Add the plugin path to opencode.json:

```json
"plugin": ["~/.config/opencode/plugins/permission-classifier"]
```

3. Restart opencode.

## How to run the tests

```
bun test
```

The test suite covers tier classification (read/write/remove
boundaries), SSH-transport stripping, and the structured-error
shape that the plugin emits when blocking a remove-tier command.

## When it does not work

- **Plugin loads but does not intercept anything.** Confirm the path
  in opencode.json's `plugin` array resolves correctly. opencode
  silently no-ops a plugin entry that points at a nonexistent path.
- **Read-tier commands prompt anyway.** opencode's static config
  rules apply *after* plugin hooks. If opencode.json has
  `"*": "ask"` and no specific allow rule for the command, opencode
  asks even when the plugin returned without throwing. That is by
  design; the plugin is permissive, opencode's static rules win.
- **Remove-tier commands run silently.** The plugin's `throw new
  Error(...)` should propagate as a tool-call failure that opencode
  surfaces to the agent. If the agent ignores the error and tries
  again, the agent's instruction-following is the issue, not the
  plugin's.
- **Subagent commands bypass the hook.** Known opencode upstream
  issue (#5894). Subagent-spawned bash calls do not fire the
  parent's `tool.execute.before` hook. No workaround in the plugin.

## Status

Working code. Not deployed. Not maintained.

The opencode plugin API surface this targets is from opencode v1.x
circa April 2026. Future opencode versions may move the
`tool.execute.before` hook to a different shape. If the plugin stops
working and you want to revive it, the hook signature should be the
first thing to check.
