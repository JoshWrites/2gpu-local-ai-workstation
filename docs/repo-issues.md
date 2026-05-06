# Repo Issues

Issues found while onboarding a second/remote user that need to be addressed in the repo.

## polkit rule hardcodes usernames

**File:** `systemd/polkit/10-llama-services.rules`

The live rule at `/etc/polkit-1/rules.d/10-llama-services.rules` hardcodes usernames directly in the JS rule (`subject.user === "<admin>" || subject.user === "<user2>"`). The repo template uses an `allowedUsers` array placeholder but still requires manual editing per user.

**Problem:** Adding/removing users requires editing the polkit rule directly. The rule is owned by root and not user-configurable. Username list is not derived from any env file.

**Proposed fix:** Read allowed users from `/etc/workstation/system.env` (e.g. `WS_ALLOWED_USERS="user1 user2"`) and either:
- Parse it in the polkit JS rule via an external helper, OR
- Have `install-systemd-units.sh` template the rule from `system.env` at install time (simpler, no runtime parsing)

The simpler approach: `install-systemd-units.sh` reads `WS_ALLOWED_USERS` from `system.env` and generates the rule with the correct usernames baked in at install time. Re-run the script to update.

## Library submodule (resolved — public 2026-05-06)

The Library submodule was previously a private GitHub repo, blocking
`git clone --recurse-submodules` for any user without explicit access.
Resolved on 2026-05-06: a parallel portability review against the
Library repo (templatize sidecar URLs, sharpen tool docstrings, add
LICENSE + LICENSES.md, standalone-readable README) was completed and
the repo was made public. New users can now clone the umbrella with
`--recurse-submodules` directly.

## Library submodule uses SSH URL (fixed)

**File:** `.gitmodules`

`Library` submodule was configured with `git@github.com:JoshWrites/Library.git` (SSH), requiring a GitHub SSH key for any user cloning the repo. Changed to `https://github.com/JoshWrites/Library.git` so any user can clone without credentials.

**Status:** Fixed in `.gitmodules`. Needs commit and push.

## Proxmox SSH target is a hard requirement in opencode-session.sh

`opencode-session.sh` aborts if `secrets.env` is missing, and the template requires `WS_PROXMOX_USER` and `WS_PROXMOX_HOST`. These are only used in opencode.json permission rules for read-only Proxmox queries — not needed for basic coding work.

**Fix:** Make secrets.env optional, or give `WS_PROXMOX_USER`/`WS_PROXMOX_HOST` empty-string defaults so the stack works for users without Proxmox access.

## Live polkit rule ahead of repo

The live `/etc/polkit-1/rules.d/10-llama-services.rules` diverged from `systemd/polkit/10-llama-services.rules` in the repo. The live version should be committed back to the repo.
