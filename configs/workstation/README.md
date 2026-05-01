# Workstation env files

Three env files split by scope. The umbrella tracks the example versions;
the actual files live outside the repo and are sourced at runtime.

If you are setting up the stack for the first time, the canonical
order is in `docs/install.md` (step 4 covers env files). This file
is the deeper reference for what each env file holds, why the split
exists, and how the values flow.

## What each file holds

**system.env** describes the workstation's hardware and service shape.
Card names, GPU device indices, llama.cpp binary path, model catalog
location, port assignments, per-role default models. Same values for
every user. No secrets.

**user.env** describes paths the current user owns. Repo checkout
locations, editor profile paths, optional per-user model dirs. Each
local user has their own user.env with their own values.

**secrets.env** holds machine-specific values that should not commit to
a public repo. Today: the SSH user and host for the remote that
opencode permission rules reference. Empty in the example file.

## Install locations

```
system.env    /etc/workstation/system.env       root, 0644
user.env      ~/.config/workstation/user.env    user, 0644
secrets.env   ~/.config/workstation/secrets.env user, 0600
```

## Install steps

The first time you set this up:

```
sudo mkdir -p /etc/workstation
sudo install -m 0644 configs/workstation/system.env.example /etc/workstation/system.env
sudo $EDITOR /etc/workstation/system.env

mkdir -p ~/.config/workstation
install -m 0644 configs/workstation/user.env.example ~/.config/workstation/user.env
install -m 0600 configs/workstation/secrets.env.example ~/.config/workstation/secrets.env
$EDITOR ~/.config/workstation/user.env
$EDITOR ~/.config/workstation/secrets.env
```

Then run `sudo systemctl daemon-reload` so the llama-* units pick up
the new EnvironmentFile path.

## Why the split

Three files instead of one for three reasons.

**Privilege.** system.env is root-owned because systemd reads it before
any user is around. The other two are user-owned. Mixing them would
mean either user.env needs root to edit (annoying) or system.env
becomes user-readable and the multi-user model breaks.

**Portability.** When the umbrella goes public, system.env.example and
user.env.example travel with the repo and describe the shape of the
deploy. secrets.env.example travels too but with placeholder values; a
clone of the repo can run after editing only secrets.env (and adjusting
paths in user.env if their layout differs).

**Habit-forming.** Every other homelab project uses the same shape:
public template + private overrides. Following the convention makes the
umbrella legible to anyone who has set up a self-hosted service before.

## How they get sourced

systemd units use `EnvironmentFile=/etc/workstation/system.env` directly.
That covers the unit's ExecStart line.

Shell scripts (the launcher, install scripts, the opencode.json render
helper) source all three:

```
. /etc/workstation/system.env
. ~/.config/workstation/user.env
. ~/.config/workstation/secrets.env
```

The render step for opencode.json reads from all three to substitute
placeholders in the template at launch time.

## Future

When llama-swap arrives, the per-role *_MODELS_AVAILABLE lists become
the catalog it manages. system.env stays the source of truth for what
models exist; llama-swap's own config references them.

When the umbrella goes public, secrets.env becomes a candidate for sops
encryption so the encrypted form can live in the repo. For now plain
gitignored env files are fine.
