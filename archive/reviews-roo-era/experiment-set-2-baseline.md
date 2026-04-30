# Experiment set 2 — baseline marker

This commit is the starting point for experiment set 2 of the
second-opinion agentic experiments.

## What set 1 was

**ha-workstation-toggle** — 6 runs (Roo ×5, Cline ×1) evaluating
rule-change impact against a fixed HA bug prompt, against a fixed
test-repo baseline. **Closed 2026-04-17.**

Post-mortem and per-run evidence:
`~/Documents/agentic-iteration/experiments/ha-workstation-toggle/`
(separate from any repo so agents can't load it as workspace
context and contaminate future runs).

Headline finding: the experiment measured process (SSH-first, read
logs, no-ssh-to-self) but couldn't measure outcome (did the fix
actually work). None of the 6 agent runs produced a correct fix.
The bug required three stacked deprecations + one stale README MAC
to be resolved together; no single run identified all four.
Capability gaps (no web access, no domain-validator directive, no
state-store inspection) dominated rule-tuning signal.

## What set 2 inherits from set 1

- Canonical method doc:
  `~/Documents/agentic-iteration/method.md`
- Per-run writeup format:
  `experiments/ha-workstation-toggle/runs/run-03-imperative-rule.md`
  (run-3 as the clearest template)
- Rule-file template (agent-agnostic, scenario-portable):
  `~/Documents/agentic-iteration/rule-template.md`
- Proxmox CT snapshot labeled `pre-test2-setup-2026-04-17` on all 14
  CTs (set 2 rollback baseline)
- Workstation config backup at
  `~/Documents/homelab-backups/outputs/2026-04-17-2306/`
- Private web-search proxy at `http://127.0.0.1:8888`
  (SearxNG, Bing+Brave+DDG+GitHub+Stack Overflow, no Google,
  systemd user service with linger)
- Homelab backup/snapshot/rollback tooling:
  `~/Documents/homelab-backups/` (own repo, init commit `a1e8c38`)

## What set 2 changes from set 1

| Axis | Set 1 | Set 2 |
|---|---|---|
| Scenario shape | Bug fix (open-ended "restore this function") | Build task (objective "does the service respond correctly") |
| Web access | None | SearxNG at 127.0.0.1:8888, MCP wiring pending |
| Rule content | HA-specific, consolidated `.roo/rules/critical.md` | Template-based, scenario-specific instantiation |
| Success criteria | Process-only (SSH-first, log-reading) | Process + outcome (does the service actually work) |
| Reset mechanism | Proxmox snapshots on CT113 only; manual steps | pct snapshots on all CTs + named label + one-command rollback |
| Matrix (CT104) | Running | Stopped, onboot=0 — not needed; resources back in pool |

## Scenario candidates for set 2, run 1

TBD this commit. Stack rank for discussion:

1. **Immich container spinup** — new CT, Docker Compose, Postgres +
   Redis, Traefik route, HTTPS. Objective "done" = web UI responds,
   test upload succeeds, photo appears. Exercises: multi-service
   orchestration, Traefik config (repo-tracked), DNS (Pi-hole),
   potentially firewall. User's stated preference.
2. **Grafana dashboard** — add a workstation-uptime panel to the
   existing monitoring stack. Smaller scope, tests integration with
   existing infra, Grafana domain knowledge → web search test.
3. **Local TUI tool** — workstation-only, no Proxmox side effects.
   Easiest to reset. Narrow scope.

## Bookkeeping

- Homelab-backups repo init commit: `a1e8c38`
- This baseline commit: `d1e73ae` (tagged `experiment-set-2-baseline`)
- Snapshot label: `pre-test2-setup-2026-04-17`
- SearxNG service: `searxng.service` (user), verified responsive
  2026-04-17 ~23:05 IDT

To roll back all of set 2's work:

```
cd ~/Documents/homelab-backups
./rollback-all-cts.sh pre-test2-setup-2026-04-17
# then reset the test repo (LevineLabsServer1) and any workstation
# state via git as appropriate.
```
