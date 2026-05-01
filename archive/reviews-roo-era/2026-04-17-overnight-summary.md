# Overnight summary -- 2026-04-17

Left for you to review in the morning. Nothing committed, nothing destructive
done that isn't reversible.

## What I did

### 1. Audited the 6 existing Cline task transcripts

Location: `~/.config/VSCodium/User/globalStorage/saoudrizwan.claude-dev/tasks/`

| Task ID       | Date       | Prompt                                                 | Outcome                                                                  |
| ------------- | ---------- | ------------------------------------------------------ | ------------------------------------------------------------------------ |
| 1772732052578 | (recent)   | `get to know the repo and describe its purpose`        | 1 message, never progressed                                              |
| 1772790918413 | 2026-03-06 | `Index /home/levine/.../LevineLabsServer1 with librarian` | Succeeded after 3 tries -- 24 files, 77 chunks, 14s via librarian MCP     |
| 1774126596157 | (recent)   | `Index shadowbroker with the librarian`                | 6 messages                                                               |
| 1774128589342 | (recent)   | `use index repo tool on Shadowbroker`                  | 1 message retry of the above                                             |
| 1774126070022 | (recent)   | (no history -- focus-chain stub only)                   | empty                                                                    |
| 1774127773361 | (recent)   | (no history -- focus-chain stub only)                   | empty                                                                    |

**Big finding: you already built a librarian MCP server that does repo indexing.**
- Registered globally in Cline at `http://localhost:11436/mcp` (see
  `~/.config/VSCodium/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json`)
- Successfully indexed LevineLabsServer1 on 2026-03-06 (the `.librarian/`
  marker dir is still present there, and in `Shadowbroker/`)
- Auto-approved tools: `index_repo_tool`, `get_relevant_context`,
  `list_indexed_repos`, `get_index_status`
- **The server process is NOT running right now** (no listener on 11436,
  no matching systemd unit, no process). So whatever we do next for RAG,
  step 0 is figuring out where the librarian code lives and whether to
  revive it or start fresh. I didn't touch it tonight.

**Pattern from the one successful run:** the model tried `ls -R | grep ':$' > index.txt` twice before you corrected it to `use index_repo_tool from librarian`. That's consistent with the agents-ignore-existing-infra failure mode we've been tracking. Worth a rule: "if a librarian MCP is registered, prefer its tools over ad-hoc shell indexing."

### 2. Ported rules from `.roo/` to `.clinerules/`

Cline reads:
- Repo rules: `<repo>/.clinerules/*.md`  (mirrors `.roo/rules/`)
- Global rules: `~/Documents/Cline/Rules/*.md`  (mirrors `~/.roo/rules/`)

Files copied (verbatim, no edits):

| Source                                                  | Destination                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------- |
| `~/.roo/rules/personal.md`                              | `~/Documents/Cline/Rules/personal.md`                            |
| `LevineLabsServer1/.roo/rules/deployment-and-targets.md` | `LevineLabsServer1/.clinerules/deployment-and-targets.md`        |
| `LevineLabsServer1/.roo/rules/operations-log.md`         | `LevineLabsServer1/.clinerules/operations-log.md`                |

**What I did NOT port:**

- `second-opinion/.roo/` has no `rules/` subdir (only `modes/`). Nothing
  to port. `.clinerules/` directory was created but left empty.
- The **run-5 winning rule** (`critical.md` with `ammonite-9` canary) --
  that lives only on the `ha-fix-5` branch, per your method doc's rule
  that experiment branch notes don't merge back. Porting it now would
  preempt the decision of which rule the next iteration branch inherits.
  Whoever sets up run-6 should decide whether `test-baseline` promotes
  run-5's rule (same way it promoted run-3's) before branching.

### 3. What's not done yet -- waiting on your call

- **Cline API provider config.** You need to point Cline at
  `http://127.0.0.1:8080/v1` in its settings panel. Can't do that from
  the CLI (it's stored in VS Code's workspace DB, not a flat file I can
  edit cleanly without risking corruption).
- **Plan/Act mode toggle.** Needs a click in Cline's settings. Confirm
  it's on before run-6.
- **Librarian revival.** Find the source code, confirm it still works,
  decide whether to systemd-unit it. Probably lives in
  `~/Documents/Repos/local-mcp-servers/` (has a `pyproject.toml` but
  only `sysmon.py` visible -- librarian might be a separate repo or
  removed). First morning task to track down.
- **Run-6.** Not attempted overnight. That's the deliberate stop point.

## Files touched

Created:
- `~/Documents/Repos/LevineLabsServer1/.clinerules/` (dir)
- `~/Documents/Repos/LevineLabsServer1/.clinerules/deployment-and-targets.md` (copy)
- `~/Documents/Repos/LevineLabsServer1/.clinerules/operations-log.md` (copy)
- `~/Documents/Repos/Workstation/second-opinion/.clinerules/` (dir, empty)
- `~/Documents/Cline/Rules/personal.md` (copy from `~/.roo/rules/personal.md`)
- `~/Documents/Repos/Workstation/second-opinion/reviews/2026-04-17-overnight-summary.md` (this file)

No commits. No deletes. `.roo/` originals untouched -- both Cline and Roo
can coexist with duplicate rule files, and we keep Roo as a fallback
until the Cline swap is validated.

## Recommended first move in the morning

1. Read this file.
2. Open Cline settings in VSCodium, set OpenAI-compat provider to
   `http://127.0.0.1:8080/v1`, confirm Plan/Act toggle is on.
3. Decide on librarian: revive first, or defer to after run-6? My read:
   defer. Run-6 should isolate "Roo -> Cline" as the single variable. If
   we also turn librarian back on, we've changed two things.
4. If deferring librarian: decide whether to `test-baseline`-promote
   run-5's `critical.md` before branching `ha-fix-6` (or whatever
   you name it).
