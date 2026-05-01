---
title: Remote IDE -- choices and implications
date: 2026-04-28
status: pre-decision write-up; we decide and build tomorrow
---

# Remote IDE -- choices and implications

Goal: the second user runs Zed on her laptop while opencode runs on the workstation, with the agent reading and editing **her laptop's files**, not the workstation's. Same plumbing should later extend to owner-on-laptop talking to opencode on the workstation but editing **the workstation's files**.

This document captures the design choices we surfaced during today's brainstorm, the prior-art research that followed, and the implications of each choice. We decide tomorrow.

## TL;DR

The brainstorm walked us toward "SSHFS mount + cwd-in-launcher + symlink-or-not" -- and that family of solutions was right when we started. The research changes the picture in four ways:

1. **The ACP spec itself has no concept of remote.** Paths are absolute strings, single namespace assumed. Everyone hitting our exact problem (Zed + remote ACP agent + path mismatch) is paving new ground; there is no shipped community fix.
2. **opencode honors `params.cwd` from the ACP client over its own process cwd.** The "cd in the launcher before exec" trick we were going to use does not work for ACP. (Verified by reading `acp/agent.ts:691-697` and `acp/session.ts:20-39`.)
3. **SSHFS for many small reads is structurally bad** (~21x slower than local for indexing workloads). The agent does many small reads. There is a much better tool for the file-bridge job: **Mutagen**, which gives both sides a native filesystem and reaches near-native read perf.
4. **The "no one has solved it yet" finding is not an opportunity, it's a warning.** A second research pass into *why* nothing has shipped found: (a) one serious attempt -- `anna239`'s `remote-session-support` RFD ([PR #442](https://github.com/agentclientprotocol/agent-client-protocol/pull/442)) -- has been stuck in Draft since Feb 2026 on architectural disagreement; (b) the community's stated direction is "tunnel the agent's HTTP API to a remote server" (OpenCode #7790, claude-code#24365), not "translate paths"; (c) path emission in agents is genuinely dispersed across many code paths (checkpoints, terminal cwds, edits, MCP configs, `@`-mentions) -- whack-a-mole at scale; (d) state persisted by the agent (checkpoints) embeds absolute paths, so cross-machine session resume is broken even if you rewrite the wire. See "Why is this unsolved?" section below.

These findings push us **away** from the "small targeted proxy" framing. A path-translating ACP proxy is a real ongoing engineering project, not a weekend artifact. The honest read: a community-grade proxy is a multi-week effort, ongoing maintenance against agent versions forever, and would compete with `anna239`'s in-flight RFD which is stuck on the same hard questions we'd hit.

There is a **fourth-architecture-entirely** option (Choice E) that the research now points at much more strongly: drop the "edit local files from a remote agent" frame and use Zed's own native remote-development feature, which sidesteps all of this. It changes who-owns-what semantics in a way that matters and may not be acceptable, but it deserves serious weight given the cost of the alternative.

---

## The fork in the road

We have to make four decisions, in this order. Each constrains the next.

1. **Architecture (Choice A)** -- co-tenant-via-shared-FS, or co-tenant-via-remote-IDE? This is the biggest fork.
2. **File-bridge mechanism (Choice B)** -- assuming we go shared-FS, what tech bridges the laptop's files to the workstation? SSHFS, Mutagen, or other?
3. **Path-translation strategy (Choice C)** -- assuming we go shared-FS, how do laptop-Zed and workstation-opencode agree on path strings?
4. **Zed entry-point UX (Choice D)** -- assuming we go shared-FS, how does the second user launch Zed and have it land in a project directory whose path is workstation-translated?

A single alternative architecture (Choice E) eliminates 2-4 entirely.

---

## Choice A -- Architecture

### A1. Co-tenant via shared filesystem (the brainstorm path)

opencode runs on the workstation. The laptop's files are made visible to the workstation through some FS bridge. opencode sees the files as if they were local; Zed, on the laptop, sees them at a possibly-different path. The two sides must agree on what string identifies a file.

This is what we've been designing. It's the SSHFS-today architecture extended to the ACP/Zed world.

**Pros:** the second user keeps using her laptop's editor with its own files. Familiar mental model. Local-first ownership of files-of-record. The architecture we already partly have.

**Cons:** Path translation is a real and unsolved problem at the ACP layer. We will be writing the first community shim/proxy/whatever for this.

### A2. Co-tenant via Zed Remote Development (Choice E expanded)

Zed has a native remote-development mode. In this mode, files-of-record live on the **remote** (workstation) machine. A `zed-remote-server` process runs there; the local Zed window is a rendering surface that streams UI over an SSH tunnel. The agent panel works in this mode -- opencode running on the workstation sees workstation-local files, no path translation, no SSHFS, no proxy.

Reference: https://zed.dev/docs/remote-development and https://zed.dev/blog/remote-development

**Pros:** No path translation problem. No FS bridge to maintain. Zed's own roadmap supports this; the agent panel is documented as working in remote sessions. Far simpler operationally.

**Cons:** Files-of-record live on the **workstation**, not the laptop. the second user would be editing files in `/home/second-user/projects/blog` *on the workstation*, with no copy on her laptop. If she's offline (no workstation reachable), she can't work. If the workstation dies, her in-progress work is on the workstation, not on her laptop. She'd need a separate sync (rsync/git/Mutagen) to keep a laptop-local copy as backup.

This is the architecture you said you didn't want during the brainstorm -- file ownership flipped. But the research strongly suggests it's the only architecture that doesn't fight the protocol. It deserves a re-evaluation now that we know:
- ACP has no remote-namespace concept.
- The rest of the industry (VS Code Remote, JetBrains Gateway) chose this architecture for the same reason.
- The shared-FS path requires us to write the first community-published ACP proxy.

### A3. Choice E in disguise (workstation-as-source, but laptop-mirrored)

A pragmatic hybrid: use A2 (Zed Remote Development), but add a **separate** laptop <-> workstation Mutagen sync of the project directory. Files-of-record are on the workstation (source of truth from ACP's POV); a continuous sync gives the second user a laptop copy too. If the workstation is unreachable, she opens her laptop copy in standalone Zed and edits there; later, sync resolves.

This is the kitchen-sink option. Adds complexity (two systems, conflict semantics) but preserves both Zed-remote's clean ACP story *and* a laptop-local fallback. Worth flagging as a possibility, probably not worth building for V1.

### Recommendation for Choice A

The honest read of the research, after the why-unsolved second pass: **A2 is the strongly-recommended path.** The "small targeted proxy" framing for A1+C3 was optimism the second research pass deflated. A1 with C1 (symlink) is viable for V1 but inherits the structural ACP-vs-remote mismatch -- when edges appear, the only fixes are (a) build a multi-week proxy, (b) accept the edges, or (c) migrate to A2 anyway.

**Tomorrow's decision question: Is "files of record live on the workstation" acceptable for the second user's primary workflow?**

If yes -> A2 (or A3 with Mutagen mirror), ignore Choices B-D, do this in 1-2 days. The path forward is well-trodden by VS Code Remote and JetBrains Gateway; Zed has it built in; the agent panel works; opencode-patched stays exactly where it is on the workstation.

If no -> A1 with C1 (symlink) for V1, accepting that this is a "good enough until it isn't" choice and that the upgrade path beyond C1 is "switch to A2," not "build a proxy."

---

## Choice B -- File-bridge mechanism (only if A1)

### B1. SSHFS (status quo)

What today's `work-opencode-launch` does. FUSE mount over SFTP. Zero setup beyond what we already have.

**Pros:** Already deployed, already working, idempotent. One canonical path namespace via the mount.

**Cons:** Performance is structurally bad for the agent's workload. Karl Voit's bonnie++ measured SSHFS at ~21x slower than direct disk for filename indexing -- the same access pattern grep/find/agent scans use. Symlink semantics are leaky (libfuse/sshfs#312, vscode#115645). Hangs when the SSH connection drops without timeout.

The deprecation note from the rclone research is striking: **SSHFS is officially deprecated**, with rclone as the project-recommended successor.

Source: https://blog.ja-ke.tech/2019/08/27/nas-performance-sshfs-nfs-smb.html, https://karl-voit.at/2017/07/26/sshfs-performance/

### B2. Mutagen (the research's strong recommendation)

Continuous bidirectional sync with a daemon on each side. Both endpoints have native ext4; Mutagen propagates changes between them. Reported sub-second propagation on monorepos. Small-file reads are at native ext4 speed because they're served by the local filesystem, not a network protocol.

Source: https://mutagen.io/documentation/synchronization/, https://news.ycombinator.com/item?id=33225703

**Pros:** Near-native read performance for the agent. Conflict-tolerant modes (`two-way-safe`, `two-way-resolved`). No FUSE.

**Cons:** Two paths exist on two filesystems -- Mutagen does not give you a single canonical path; it gives you two real paths with synchronized contents. **This actually exposes the ACP path-translation problem more sharply** (the workstation sees `/home/second-user/work/...`, the laptop sees `/home/second-user/work-laptop/...` or wherever you sync to). The single-path illusion of SSHFS goes away; you need the proxy from Choice C either way under shared-FS, but the path mapping becomes more visible.

Initial sync is slow on big trees (one-time cost). Conflict resolution semantics need understanding.

### B3. NFSv4 over SSH tunnel

Better than SSHFS for small random reads (per Lochmann's benchmarks), worse than native sync. Single namespace via mount.

**Pros:** Faster than SSHFS. Single canonical path.

**Cons:** Setup over SSH is fiddly (port-forwarding, root_squash). Still per-op network round-trip. No advantage over SSHFS large enough to justify the setup cost when Mutagen exists.

### B4. rclone mount (SFTP backend, with VFS cache)

`vfs-cache-mode full` gives caching SSHFS doesn't have. One benchmark showed ~4x SSHFS throughput on bulk transfer; small-file responsiveness is mixed. Project actively recommends this as SSHFS replacement.

**Pros:** Drop-in replacement for SSHFS with caching. Maintained.

**Cons:** Still FUSE; small-file metadata path still per-op. Cache staleness window introduces its own failure modes.

### B5. lsyncd (push-only sync)

inotify on the laptop, rsync to workstation. One-way only.

**Pros:** Simple model.

**Cons:** Default 15s batch delay. Documented to choke under heavy file events. Not bidirectional, so opencode writes on the workstation would not propagate back.

### Recommendation for Choice B

If we go A1, **Mutagen `two-way-safe` mode** is the strongest pick on raw performance and on operational maturity. The research is clear that on-demand-network-FS architectures (SSHFS, NFS, rclone) are structurally worse than native-FS-plus-sync for the agent's workload.

The cost of Mutagen vs SSHFS: it sharpens the path-translation problem (two visible paths instead of one mounted path) and adds a daemon both sides. Both are real but small.

If we don't trust Mutagen yet, **stay on SSHFS for V1** with a known-and-acknowledged perf ceiling, plan a B2 migration later.

---

## Choice C -- Path-translation strategy (only if A1)

This is the choice that turned out hardest. Today's brainstorm walked through three options (T1 symlink, T2 cd-in-launcher, T3 ACP shim) and the code reading killed T2. The research adds context to T3.

### C1. Single-namespace-via-symlink (T1, "the symlink trick")

On the laptop: `ln -s /home/second-user /home/second-user/laptop-home`. On the workstation: SSHFS mount at `/home/second-user/laptop-home`. The path string `/home/second-user/laptop-home/projects/blog` is real on both machines and refers to the same files. Zed sends that path in `session/new.cwd`; opencode receives it; everyone agrees.

**Pros:** No translation logic anywhere. Cwd contract is satisfied by construction. opencode's `pathToFileURL()` calls (which we now know happen at `acp/agent.ts:1159, 1169`) emit URIs that resolve correctly on the laptop because the path exists there too via the symlink.

**Cons:** Cosmetic -- Zed shows "laptop-home/" in breadcrumbs. the second user has to remember to launch Zed from `~/laptop-home/foo` rather than `~/foo` (or use the launcher to do the translation for her). The "wandering out of the mount" concern you raised earlier doesn't apply -- the symlink is a self-reference; there's no escape to the workstation's real filesystem.

### C2. Translate `$PWD` once at launch, no symlink (T2)

The brainstorm's earlier choice. **The code reading killed it.** opencode honors `params.cwd` from `session/new`, not its own process cwd. Translating `$PWD` before exec'ing opencode does nothing; Zed will still send laptop-native paths in `session/new`, and opencode will store them and try to resolve files against them, and every file op fails.

**Verdict: structurally broken. Do not pick.**

### C3. ACP path-rewriting proxy (T3, narrow scope)

A process that sits in the laptop <-> workstation pipe, parses ACP messages, and rewrites path strings. Today's brainstorm rejected this as whack-a-mole. The first research pass softened that concern; **the second research pass (why-unsolved) hardens it back up**:

- **`anna239`'s `remote-session-support` RFD has been stuck in Draft since February 2026.** This is the most serious attempt to date and it died on architectural disagreement: reviewer `alpgul` proposed moving tool management client-side; `anna239` rebutted that this defeats agent autonomy. The PR is open but unprogressed. We would be entering an in-progress design conversation, not a vacuum. PR: https://github.com/agentclientprotocol/agent-client-protocol/pull/442
- **The community's chosen direction is to avoid path translation by relocating the namespace.** OpenCode #7790 (assigned to a maintainer) explicitly lists "No remote filesystem access beyond the OpenCode server API" as a non-goal -- they're building HTTP-tunneling, not path translation. claude-code#24365 was bot-closed (stale label), but the 20+ third-party workarounds in its comment thread are all "tunnel the HTTP API," none are path translators. The architectural intuition we'd be cutting against is widely held.
- **Path emission is dispersed.** The first-pass list (cwd, fs/read_text_file path, fs/write_text_file path, pathToFileURL) is incomplete. Real evidence:
  - Tool-call args, edit notifications, terminal cwds (per opencode source structure)
  - **Checkpoint files** -- zed#43335 traces a path-handling bug to `crates/acp_thread/src/acp_thread.rs:1703`, in checkpoint code. State persisted by the agent embeds absolute paths.
  - **MCP server configs** -- zed#52254 shows Zed wraps remote MCP launch commands in SSH, defeating discovery; a path-translating proxy would also need to relocate MCP configs across the boundary.
  - **`OpenBufferByPath`** -- zed#48240 shows Zed's RPC misclassifies a remote directory as a file. Adjacent file-tooling already has shape-of-data bugs at the remote boundary.
  - **`@`-mentions, slash-command outputs** -- these emit paths too.
  - The proxy must rewrite **bidirectionally** and maintain a bijective map. Drift between map and reality means corruption.
- **Cross-machine session resume is structurally broken** even with a wire-level proxy, because checkpoints and persisted session state embed absolute paths. Restoring a checkpoint on the other machine reads paths that don't exist there.
- **The Proxy Chains RFC has a reference implementation (`symposium-acp`/`sacp-conductor`, latest release Jan 19 2026) that is local-only.** The RFC anticipates proxies but has no path-namespace concept. We'd be building on a proxy framework that doesn't yet have the primitive we need.
- **Precedent in the LSP world (`remote-ssh.nvim` "Smart Path Translation") exists**, but LSP is a *narrower* protocol -- fewer message types, less persisted state, no checkpoints, no sub-agent MCP plumbing. The LSP precedent is an existence proof that path translation can work, not a template we can copy.

**Honest cost estimate, revised:** Not 200-400 lines. A community-grade ACP path-translation proxy is **multi-week initial work + ongoing maintenance against every agent version**. The "moving target" concern is the dominant ongoing cost: opencode ships frequent updates; each one can introduce a new path-emission site that the proxy doesn't cover.

**Pros:** Cleanest user-facing experience -- Zed shows real laptop paths. If we built it well, it would be the first published proxy of its kind, useful to the community.

**Cons:** Real ongoing engineering project. Whack-a-mole maintenance forever. The one prior serious attempt (anna239's RFD) is stuck on the same architectural questions we'd hit. Cross-machine checkpoint resume can't be solved by a wire-level proxy alone. Building this is committing to a side-quest.

### C4. Symlink + skinny proxy (hybrid)

Use C1 as the primary mechanism, *plus* a 10-line proxy that rewrites `session/new.cwd` only -- as a safety net for the case where Zed is launched via the GUI Open-Folder picker and the user navigates into `/home/second-user/foo` instead of `/home/second-user/laptop-home/foo`. Idempotent: if the path is already mount-translated, leave it alone; if it's laptop-native, rewrite it.

**Pros:** Most paths handled by the symlink (no logic). Edge case (GUI navigation outside laptop-home) handled by tiny rewrite. Lowest total complexity.

**Cons:** Two mechanisms instead of one. Outgoing-from-opencode `pathToFileURL` URIs still need handling (the symlink covers this -- they resolve on the laptop because the path exists there too via symlink -- but only if the second user stays under `~/laptop-home`).

### Recommendation for Choice C

**C1 (symlink) for V1**, with the explicit understanding that **C3 is not a Phase 2 deliverable for us** -- it's a side-quest masquerading as one. If C1 has rough edges, the right response is probably to switch to A2 (Zed Remote Development), not to start building a proxy.

The reasoning: of the four, only C1 ships immediately with no new code. C3 is **not** "the architecturally cleanest but is a real engineering project" -- it's a multi-week project with ongoing maintenance against every agent version, where the one serious community attempt has been stuck for months on the same hard questions we'd hit, and where wire-level rewriting can't fix all the bugs (checkpoint persistence embeds absolute paths). C4 is C1+C3-lite; the lite version still inherits C3's concerns at smaller scale.

If C1 hits real edges, the cheapest move is to step back and ask whether A2 (Zed Remote Development) is the right answer, not to climb the proxy hill.

---

## Choice D -- Zed entry-point UX (only if A1)

the second user needs two entry points to work:

1. CLI: `cd ~/projects/blog && zed-second-opinion` and have Zed open at the right place
2. GUI: click the desktop entry, then File -> Open Folder, navigate to the project

### D1. Symlink + CLI launcher does translation; GUI requires user navigates via `~/laptop-home/`

With C1 (symlink) in place: the CLI launcher script translates `$PWD` from `/home/second-user/projects/blog` to `/home/second-user/laptop-home/projects/blog` and passes that to Zed. The GUI flow requires the second user to navigate via the `~/laptop-home/` symlink path in the file picker.

**Pros:** Simple. CLI launcher is one shell script; GUI requires only user habit.

**Cons:** GUI requires habit. If she opens `/home/second-user/projects/blog` directly via the picker, opencode breaks (path doesn't exist on workstation).

### D2. Symlink + CLI launcher + skinny proxy (C4) handles GUI

CLI as in D1. GUI: the proxy normalizes `session/new.cwd`, so even if she opens `/home/second-user/projects/blog` from the picker, the proxy rewrites to `/home/second-user/laptop-home/projects/blog` before opencode sees it.

**Pros:** Works regardless of how she opens the project. No user habit required.

**Cons:** Requires C4 (skinny proxy). Smallest possible proxy -- one regex on one field -- but it's still code.

### D3. Hide the laptop-native namespace entirely

Don't create the `~/projects/blog` paths on the laptop at all. Make `~/laptop-home/` the only place projects live. Her CLI is `cd ~/laptop-home/projects/blog && zed-second-opinion`. Picker only sees `~/laptop-home/`.

**Pros:** No translation needed anywhere; "laptop-home/" is just where stuff lives.

**Cons:** Awkward -- every other tool on her laptop (terminal, file manager, scripts) has to use `~/laptop-home/` paths too. Breaks the principle that her laptop should look normal.

### Recommendation for Choice D

**D1 for V1**, with **D2 as the upgrade path** when we build C4. D3 is too invasive.

---

## Choice E -- Adopt Zed Remote Development (the alternative architecture)

This is the architecture-level alternative that came out of the research. Quick recap:

- Zed has a built-in mode where the editor runs locally as a thin client and a `zed-remote-server` runs on the remote machine. Files live on the remote.
- The agent panel works in this mode; opencode running on the remote sees remote files; no path translation, no FS bridge, no proxy.
- This is what VS Code Remote-SSH and JetBrains Gateway also do.

**Pros over A1:**
- Zero new code. Pure configuration.
- No path translation problem to solve.
- No SSHFS/Mutagen to deploy.
- Native ACP support (no proxy).
- Aligned with industry direction (VS Code Remote, JetBrains Gateway, Zed's own roadmap).
- Solves all the open issues in the research (zed#47910, zed#48240, zed#52254, zed#37011, etc.) because they don't apply.

**Cons:**
- Files-of-record live on the workstation. If the second user is at home with no workstation, she can't work on her files in the same way.
- Inverts the laptop-is-source-of-truth invariant we set up the multi-user setup to protect.
- If the workstation dies, in-progress work is gone unless mirrored.

**Mitigations for the cons:**
- Add a Mutagen sync between workstation `/home/second-user/projects` and laptop `/home/second-user/projects-mirror` running in the background. Provides a second copy for offline/disaster cases without affecting the primary work surface. (This is the A3 hybrid.)
- Or accept that "you can only work when the workstation is on" is true (it already is, for the GLM model -- without llama-primary running on the workstation, she has no agent anyway).

### Recommendation for Choice E

**Strongly worth a serious second look before tomorrow's build.** The honest answer is: A2/E gives us 90% of what we want with 10% of the complexity. The 10% we'd give up (laptop as canonical file home) may be less load-bearing than we thought when the alternative requires us to write a community-first ACP proxy.

The questions to answer tomorrow:
1. Is "the second user can only work on her code when the workstation is on" acceptable? (It already is for AI work -- without GLM, she has no agent.)
2. Is laptop-as-canonical-file-home a hard requirement, or is it a habit we built up that we could update?
3. If we add a Mutagen mirror back to the laptop (Choice A3), does that resolve the offline-resilience concern?

---

## What this means for the brainstorm we did

Today we walked through:
- T1 vs T2 vs T3 path translation -> you picked T2 for safety reasons
- WORK_TARGET env var for second-user vs owner divergence
- Two-Zed vs one-Zed -- the second user gets only second-opinion Zed
- Cwd contract: Zed and opencode must agree

The research changes most of these:
- **T2 is broken at the protocol level.** It can't work because opencode honors `session/new.cwd`, not process cwd. T1 (symlink) is the V1 pick if we go A1; T3 (proxy) is the V2 destination.
- **WORK_TARGET still makes sense** as a forward-compatibility flag in either A1 or A2; nothing about the architecture decision invalidates it.
- **One-Zed (second-opinion only) on the second user's laptop** is right regardless of A1 vs A2. The `agent_servers` config differs, but the Zed flavor is the same.
- **Cwd contract:** in A1, the path string in `session/new.cwd` must resolve identically on both machines (C1 via symlink does this by construction). In A2, it's automatic because there's only one machine.

---

## What I'd build tomorrow (given each branch)

### If we pick A2 (Zed Remote Development)

1. Install `zed-remote-server` on the workstation (Zed binary supports this natively).
2. On the second user's laptop second-opinion Zed: configure SSH connection to the workstation host.
3. Open a project at `/home/second-user/projects/...` *on the workstation*; Zed transparently runs the agent there.
4. Configure opencode in the workstation's Zed-remote profile to use `/usr/local/bin/opencode-patched`.
5. Optionally add Mutagen sync of `/home/second-user/projects` <-> laptop mirror as A3 hybrid.

Estimated effort: 0.5-1 day.

### If we pick A1 + B1 + C1 + D1 (SSHFS + symlink + CLI launcher)

1. Create `remote-ide` branch.
2. On the second user's laptop: `ln -s /home/second-user /home/second-user/laptop-home`.
3. Write `~/.local/bin/work-zed-acp` (laptop wrapper: WoL, translate `$PWD`, exec ssh into workstation).
4. Write `~/.local/bin/remote-ide-launch` (workstation launcher: idempotent llama startup, idempotent SSHFS mount, exec opencode-patched acp). Use `wait $!` pattern + signal trap to fix the orphan-leak bug on this new launcher.
5. Write `~/.local/bin/zed-second-opinion-laptop` (laptop equivalent of `second-opinion-launch.sh`, sets `--user-data-dir`).
6. Configure her laptop `~/.local/share/zed-second-opinion/config/settings.json` with `agent_servers.opencode.command = ~/.local/bin/work-zed-acp` and `env: { WORK_TARGET: "local-files" }`.
7. Document GUI usage: "always navigate via `~/laptop-home/` in the file picker."

Estimated effort: 1-2 days.

### If we pick A1 + B2 (SSHFS -> Mutagen migration)

Same as above, replace the SSHFS mount step with Mutagen daemon setup. Path-translation strategy may shift to C3 (proxy) because Mutagen paths are explicit per-endpoint.

Estimated effort: 2-3 days.

---

## Why is this unsolved? (the second research pass)

When the first-pass research found "no shipped community fix for remote ACP," I framed that as opportunity. The user pushed back: don't be optimistic -- drill into *why*. A second research pass read the actual issue threads and PR comments. Here's what came back.

### The hypotheses tested

- **H1 -- Hard at the protocol level.** Partially supported. ACP's spec assumes shared filesystem semantics. The Additional Workspace Roots RFD ([PR #783](https://github.com/agentclientprotocol/agent-client-protocol/pull/783), merged) explicitly scopes itself out of cross-machine cases -- paths must be "absolute path under the same platform path rules." Streamable HTTP transport ([PR #721](https://github.com/agentclientprotocol/agent-client-protocol/pull/721), merged) added a wire format but did not raise path translation. The wall is real but it's a layered design assumption, not impossibility.

- **H2 -- Hard at the implementation level.** *Strongly* supported. opencode#19473 (UNC paths to WSL) shows path mangling on naive concatenation. zed#48240 shows `OpenBufferByPath` misclassifies a remote directory as a file. zed#43335 traces a path-handling bug to checkpoint code at `crates/acp_thread/src/acp_thread.rs:1703`. PR #48935 "fixed" remote ACP registry but only for *agent installation visibility* -- not running-session paths. Each agent emits paths through dozens of code paths; this is whack-a-mole at scale.

- **H3 -- Politically blocked.** Partially supported, with nuance. claude-code#24365 was closed "not planned" but carries the `stale` label -- bot closure on inactivity, not deliberate rejection. Zed maintainer `benbrandt` reviewed the remote-session-support RFD ([PR #442](https://github.com/agentclientprotocol/agent-client-protocol/pull/442)) and asked *"whose responsibility it is to set this thing up which will help me better grasp how this should fit in the protocol"* -- that's "needs more design," not "no." OpenCode #7790 is *open with active assignment*, but its non-goals include "No remote filesystem access beyond the OpenCode server API." The community is building remote-IDE *only at the HTTP-tunnel layer*, not solving cross-fs paths.

- **H4 -- Doesn't matter to most users.** Weakly supported. zed#47910 is `frequency:common`, `priority:P1`. claude-code#6686 (parent ACP request) had 553 reactions. But the pattern is: people hit it, find a same-box workaround (run Zed inside WSL, run editor on the remote), stop pushing. Demand exists but converts poorly into PRs because the workaround is acceptable.

- **H5 -- Someone tried and ran into deal-breakers we should know about.** Supported. The closest documented attempt is `anna239`'s `remote-session-support` RFD ([PR #442](https://github.com/agentclientprotocol/agent-client-protocol/pull/442), opened Feb 2 2026, **still open in Draft**). Reviewer `alpgul` proposed an alternative architecture -- "moving tool management client-side so agents remain completely stateless" -- and `anna239` rebutted that this would defeat the point because agents couldn't run independently while users work locally. The PR is stuck on architectural disagreement about *where the filesystem lives*. The AWS-samples [`sample-acp-bridge`](https://github.com/aws-samples/sample-acp-bridge) explicitly punts on the cross-fs problem ("Agent CLIs stay on your host -- mount them into the container as needed"). The Proxy Chains RFD has a reference implementation (`symposium-acp`/`sacp-conductor`, latest release Jan 19 2026), but its proxies "cannot access capabilities that ACP doesn't expose" -- and a path namespace is not such a capability today.

- **H6 -- Solved invisibly.** Not supported. No fork or downstream patch surfaced. `claude-code-acp` and `claude-agent-acp` are local adapters. `claude-agent-acp`'s behavior is the *opposite* of what we'd want: "the execution_environment setting is overridden by the ACP session, which injects an ACPExecutionEnvironment that routes all toolset operations back to the IDE/client filesystem" -- i.e. it assumes filesystem unity in the other direction.

### Specific deal-breakers a would-be builder needs to know

1. **Path emission is dispersed.** Tool-call args, edit notifications, terminal cwds, checkpoint files, MCP server configs, slash-command outputs, `@`-mentions. A proxy must intercept *all* of them and the surface is uneven.
2. **Paths flow both directions.** Client -> agent (cwd, additionalDirectories, openBufferByPath responses) and agent -> client (tool calls, edits). Bijective map required.
3. **MCP-over-tunnel is already broken in Zed.** zed#52254 shows Zed wraps remote MCP launch commands in SSH, defeating discovery. A path-translating proxy must also transparently relocate MCP configs.
4. **ACP capabilities are negotiated at `initialize`** -- a proxy must declare client capabilities consistent with both sides.
5. **Checkpoint/restore semantics depend on absolute paths.** "failed to get old checkpoint" recurs across zed#48240, zed#43335. State persisted by the agent embeds local paths. **Cross-machine sessions can't be resumed without rewriting persisted state**, which a wire-level proxy cannot reach.
6. **The community's stated direction is to tunnel the agent's HTTP API, not to translate paths.** OpenCode #7790, claude-code#24365, opencode#8890 all gravitate toward `--attach` / HTTP-bridge designs that keep filesystem unity by running the editor against a remote server. A path-translation proxy contradicts the prevailing architectural intuition.
7. **Maintainers are not opposed -- they're under-designed.** This is opportunity in principle but it means *we* would have to do the design work that anna239's RFD has been trying to land for two months.

### Overall read

**H2 + H5 best support the current state, with H1 as the underlying constraint.** The problem is unsolved because (a) the spec was designed for shared-filesystem semantics and never got an explicit remote namespace primitive, (b) every agent leaks paths through many code paths, and (c) the one serious attempt is stuck on architectural disagreement since February. It is *not* unsolved because maintainers killed it. A would-be builder is not first, but the prior attempt died on scope and design responsibility, not on impossibility -- meaning we wouldn't be banging our head on a closed door, we'd be wandering into a half-finished design discussion that nobody has had the bandwidth to land. **That is a worse position than "first," not better.**

The realistic build, if we did it, is a path-translating ACP proxy with a bijective path map, intercepting every spec-defined path field plus the empirically-known leakage points, rerouting MCP configs, and accepting that checkpoint/resume across machines will remain broken without spec-level work. Multi-week initial. Whack-a-mole forever.

This is what makes A2 (Zed Remote Development) the recommended path. Not because A1 is impossible, but because A1's true cost is much higher than today's brainstorm assumed.

---

## Open questions for tomorrow's decision session

1. **The big one: A1 vs A2.** Now that the proxy path looks like multi-week + ongoing maintenance (not "small targeted shim"), is laptop-as-canonical-file-home still worth it? Or is A2 (workstation-as-canonical, optionally with Mutagen mirror) the cleaner answer?
2. If A1: do we accept that C1 (symlink) is the ceiling, and that "edges past C1 -> migrate to A2" is the upgrade path, NOT "edges past C1 -> build proxy"?
3. If A1: do we move off SSHFS to Mutagen now (B2), or accept SSHFS for V1 and migrate later?
4. **Do we want to publish an ACP proxy as a research artifact?** The honest answer should weigh: is this our highest-leverage research direction, or is it a side-quest that competes with the work we actually care about (passive-context architecture, librarian, distiller, etc.)?

---

## Sources

### From this brainstorm

- Brainstorming session 2026-04-28 (this document captures the conclusions)
- opencode source: `/tmp/opencode-build/opencode/packages/opencode/src/acp/agent.ts`, `session.ts`, `cli/cmd/acp.ts`
- Existing memory: `project_multi_user_opencode.md`, `project_opencode_patch.md`, `project_wol_todo.md`, `project_second-user_launcher_hygiene_todo.md`

### From the parallel research and the why-unsolved follow-up

Four agents researched in total; their full outputs are at the cited URLs in the body. Key sources:

- Zed Remote Development: https://zed.dev/docs/remote-development, https://zed.dev/blog/remote-development
- Zed external agents: https://zed.dev/docs/ai/external-agents, https://zed.dev/docs/extensions/agent-servers
- Open Zed issues showing community pain: zed#47910, zed#48240, zed#52254, zed#45165, zed#37011, zed#43335, zed#53249
- Open opencode issues: opencode#7790, opencode#8890, opencode#19473
- ACP RFCs that anticipate this work: https://agentclientprotocol.com/rfds/proxy-chains, https://agentclientprotocol.com/rfds/streamable-http-websocket-transport
- ACP file-system spec: https://agentclientprotocol.com/protocol/file-system
- The serious in-flight attempt (stuck since Feb 2026): https://github.com/agentclientprotocol/agent-client-protocol/pull/442
- ACP capability/scope clarification: https://github.com/agentclientprotocol/agent-client-protocol/pull/783
- ACP transport (does NOT solve paths): https://github.com/agentclientprotocol/agent-client-protocol/pull/721
- AWS sample-acp-bridge (punts on cross-fs): https://github.com/aws-samples/sample-acp-bridge
- LSP precedent: https://neovimcraft.com/plugin/inhesrom/remote-ssh.nvim/, https://emacs-lsp.github.io/lsp-mode/page/remote/
- SSHFS perf: https://karl-voit.at/2017/07/26/sshfs-performance/, https://blog.ja-ke.tech/2019/08/27/nas-performance-sshfs-nfs-smb.html
- Mutagen docs: https://mutagen.io/documentation/synchronization/
- VS Code Remote model: https://code.visualstudio.com/docs/remote/ssh, https://code.visualstudio.com/api/advanced-topics/remote-extensions
- VS Code Uri.fsPath bug: https://github.com/microsoft/vscode/issues/105969
- JetBrains Gateway architecture: https://blog.jetbrains.com/blog/2021/12/03/dive-into-jetbrains-gateway/
