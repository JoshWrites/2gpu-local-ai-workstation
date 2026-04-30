# Workstation restructure plan

Logged 2026-04-23. Captures the full shape we discussed so we don't forget the rest when picking this up again.

## Current state (as of today)

```
/home/levine/Documents/Repos/
├── Workstation/                       ← grouping dir, not a git repo
│   ├── docs/                          ← cross-project docs
│   │   ├── ports-registry.md
│   │   ├── tries-and-takeaways.md
│   │   ├── opencode-conventions.md
│   │   └── restructure-plan.md        ← this file
│   ├── second-opinion/                ← git repo, Roo experiments
│   ├── more-than-pretty-lights/       ← git repo
│   ├── library_and_patron/            ← git repo, has GitHub remote
│   └── boot-cleanup-2026-04-15.md     ← loose doc
├── local-mcp-servers/                 ← git repo, HAS NO REMOTE YET
│   ├── distiller.py
│   ├── sysmon.py
│   ├── watcher.py
│   ├── confirm_destructive.py
│   ├── pyproject.toml                 ← shared across all four MCPs currently
│   └── uv.lock                        ← shared
└── (other unrelated repos — blender-mcp, CALMe, ComfyUI, etc.)
```

The asymmetric nesting is historical. `library_and_patron` grew up inside `Workstation/` as a workstation-project thing; `local-mcp-servers` grew up as a general-purpose repo under `Repos/`.

## Target state (end state)

```
/home/levine/Documents/
└── Workstation/                       ← moved up one level, out of Repos/
    ├── docs/
    ├── second-opinion/
    ├── more-than-pretty-lights/
    └── local-mcp-servers/             ← now a grouping dir, NOT a repo itself
        ├── library_and_patron/        ← moved into local-mcp-servers/; separate repo
        ├── distiller/                 ← split out, own repo, own pyproject
        ├── sysmon/                    ← own repo
        ├── watcher/                   ← own repo
        └── confirm_destructive/       ← own repo

/home/levine/Documents/Repos/
├── Workstation           →  symlink ../Workstation           (muscle memory)
├── library_and_patron    →  symlink ../Workstation/local-mcp-servers/library_and_patron
├── distiller             →  symlink ../Workstation/local-mcp-servers/distiller
├── sysmon                →  symlink ../Workstation/local-mcp-servers/sysmon
├── watcher               →  symlink ../Workstation/local-mcp-servers/watcher
├── confirm_destructive   →  symlink ../Workstation/local-mcp-servers/confirm_destructive
└── (other unrelated repos, untouched)
```

## Why this shape

- **Each MCP is independently clonable.** anny (or anyone else) can clone just `distiller` without pulling in `sysmon` or `watcher`. Reduces cognitive load on consumers.
- **Per-MCP pyproject + lockfile** means dep updates don't cross-contaminate. If distiller bumps a dep, watcher doesn't risk it.
- **`local-mcp-servers/` becomes a coherent container** — "all my workstation MCPs live here" — without being a single monolith repo.
- **Workstation is the project root,** symlinked from `Repos/` for habit. The `Repos/` dir becomes just "a convenient flat view of clonable projects."
- **Documents/Workstation/** separation from **Documents/Repos/** lets Workstation feel like its own thing (because it is one), not just one of many repos.

## Phased execution (what we've done, what remains)

### ✅ Phase 1 — unblock anny (2026-04-23)

- Commit pending local-mcp-servers changes (confirm_destructive.py + tests + pyproject/lock bumps)
- Create private GitHub repo `JoshWrites/local-mcp-servers`
- Push main
- Clone local-mcp-servers + library_and_patron into `/home/anny/Documents/Repos/`
- Run `uv sync` in both as anny
- Update her opencode.json to point at her own clones
- Revert `/home/levine` back to 750 (she no longer needs to reach into your home)

**Net result of phase 1:** anny's MCPs work without her touching anything in your home. Filesystem structure remains as-is for you. The shape above is target; today's state is unchanged except for the new remote + her clones.

### Phase 2 — lift Workstation one level (not started)

- `mv ~/Documents/Repos/Workstation/ ~/Documents/Workstation/`
- `ln -s ../Workstation ~/Documents/Repos/Workstation` (symlink for muscle memory)
- Verify opencode.json, systemd units, VSCodium settings, etc. still resolve (most follow symlinks transparently)
- Update any references that break

**Effort:** ~15 min + verification.
**Risk:** moderate. 30+ references to current path identified; most are fine with symlink, some need explicit updates. Systemd unit `/etc/systemd/system/librarian.service` references the full path and may not handle symlinks in some configurations — verify before committing.

### Phase 3 — move library_and_patron into local-mcp-servers/ (not started)

- After phase 2 completes: `mv ~/Documents/Workstation/library_and_patron/ ~/Documents/Workstation/local-mcp-servers/library_and_patron/`
- Update opencode.json for both users (their path references)
- Add `~/Documents/Repos/library_and_patron` symlink

**Effort:** ~10 min.
**Risk:** low. library_and_patron's tooling (uv, pyproject) doesn't care about its parent dir.

### Phase 4 — split local-mcp-servers into per-MCP repos (not started)

For each of distiller / sysmon / watcher / confirm_destructive:

1. Read its current source to determine its dep footprint (grep imports)
2. Create per-MCP directory under `local-mcp-servers/`
3. Write per-MCP `pyproject.toml` with trimmed deps
4. Move the source file(s) in
5. Decide on history preservation — cheap: fresh repo + lessons-learned.md; proper: `git filter-repo` from local-mcp-servers original
6. `git init`, commit, create GitHub remote, push
7. Add `~/Documents/Repos/<mcp>` symlink

**Effort:** ~30 min per MCP, ~2 hours total.
**Risk:** moderate. Splitting pyproject.toml deps correctly is the finicky part. Test each MCP imports cleanly after the split before committing.

**History preservation chosen approach (per user direction 2026-04-23):**

Preferred technique: **clone-and-delete**, not `git filter-repo`. For each new per-MCP repo:
1. Clone `local-mcp-servers` fresh
2. Delete every file NOT belonging to this MCP
3. Commit the deletion
4. Rename the clone (git remote → new repo, local dir → MCP name)
5. Push to new GitHub remote

This preserves the full shared history (including commits that only touched shared files like pyproject.toml). `git log` in each per-MCP repo shows every commit up to the split point, including ones about other MCPs — some log pollution, but the trade is every commit's context is still there. `git gc --aggressive` after deletion helps compact.

Rejected alternatives and why:
- `git filter-repo --path <mcp>`: loses shared-file commits (pyproject bumps, lockfile updates). Cleaner logs but less complete history.
- Fresh repos + lessons-learned.md: simplest, but then "what did distiller look like last month?" requires archeology in a separate archive repo.

Each new repo can still include a `docs/lessons-learned.md` if specific patterns deserve highlighting beyond what `git log` surfaces naturally.

### Phase 5 — review for obvious breakage (not started)

After phases 2-4 complete:

- Restart both users' opencode sessions
- Smoke test: ls /tmp, docker ps (both users), basic MCP tool calls
- Test librarian_mine_file on a real file
- Test distiller_research on a real question
- Fix any path-breakage surfaced
- Update `docs/tries-and-takeaways.md` with results

## References needing update when doing phases 2-4

From `grep -rl 'Documents/Repos/Workstation' ~` on 2026-04-23:

**Live config (must update for real or rely on symlinks):**
- `/home/levine/.config/opencode/opencode.json` — MCP paths
- `/home/anny/.config/opencode/opencode.json` — MCP paths
- `/home/levine/.config/VSCodium-second-opinion/User/settings.json`
- `/home/levine/.config/VSCodium-second-opinion/User/globalStorage/storage.json`
- `/home/levine/.config/systemd/user/more-than-pretty-lights.service`
- `/home/levine/.config/systemd/user/ai-session.service`
- `/home/levine/.config/systemd/user/codium-second-opinion.service`
- `/etc/systemd/system/librarian.service` (system-scoped, archived from v1)

**Workstation-local configs (follow whatever moved with them):**
- `/home/levine/Documents/Repos/Workstation/second-opinion/configs/roo-code-settings.json`
- `/home/levine/Documents/Repos/Workstation/second-opinion/systemd/codium-second-opinion.service`
- `/home/levine/Documents/Repos/Workstation/second-opinion/systemd/llama-second-opinion.service`
- `/home/levine/Documents/Repos/Workstation/more-than-pretty-lights/systemd/more-than-pretty-lights.service`

**Inert (archive docs, implementation plans that have shipped):**
- Various files under `library_and_patron/archive/` — historical, leave alone
- Various files under `second-opinion/reviews/` — historical, leave alone

## Why we're deferring phases 2-5

User decision 2026-04-23: do phase 1 only now. Unblocks anny tonight. Phases 2-4 are aesthetic/developer-ergonomic improvements, not functional requirements; they can be done in a focused session without pressure. Phase 5 (review) depends on having phases 2-4 done.

## When to pick this up

Whenever there's a calm hour with no in-flight work. This isn't urgent. Good candidates:
- Morning coffee, fresh context
- Between feature development cycles
- When adding a new MCP would benefit from the cleaner per-MCP repo structure

## Risks worth remembering

1. **Filesystem `mv` + active processes.** If any process has a file open from the old path when the `mv` happens, it may hold an inode reference that diverges from the new path. Recommend stopping llama services + both opencode sessions before phase 2.
2. **Symlink resolution differences.** Some tools (certain Python import systems, certain build tools) follow symlinks strictly; others resolve them and cache the real path. If something breaks after phase 2, check whether it's a symlink-resolution issue.
3. **Git submodule path `archive/v1-code-oriented/harness`** is a submodule URL, not a filesystem path — unaffected by these moves.
4. **Python venvs are not portable across filesystem paths.** After any `mv` that changes a venv's parent, `uv sync` or venv recreation is required. The `.venv/` dirs are git-ignored so no git consequence, just "remember to rebuild venvs after moves."
