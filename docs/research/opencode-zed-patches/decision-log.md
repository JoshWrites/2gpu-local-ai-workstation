# Decision log

## 2026-04-28 -- kickoff

**Context:** User noticed opencode-in-Zed fails to surface tool approval prompts; bash boxes appear empty in the UI. Investigated as a debugging session, traced through opencode source.

**Constraints set by user:**
- Permission decisions must be **per-call interactive**, not static allowlists.
- Solutions must be **local** (no hosted agent substitutes -- Claude is for toolchain, opencode is for files).
- Top priority: opencode as first-class Zed citizen.
- Phase 2 priority: solution must be remote-serveable (matching the existing `work-opencode` SSH pattern for laptop->workstation).
- User willing to fork Zed if needed (deferred -- not needed unless other paths fail).
- Community contribution desired where it doesn't slow down phase 1.

**Decision:** Hybrid plan.
1. Build local stdio shim (Phase 1).
2. Once shim's logic is proven, port it as an upstream PR to opencode (re-doing what closed-bot-PR #7374 did, this time as a human submission).
3. Remote serving (Phase 2) inherits the shim as the natural place to bridge SSH <-> stdio. No protocol changes needed.

**Why shim before patched-opencode:**
- Reversible (no fork to maintain).
- Same code becomes the basis of the upstream PR.
- Phase 2 architecture lands on the shim anyway, so building it is unavoidable.

**Why not fork Zed:** Zed maintainers have publicly stated this class of bug is the agent's job to fix (issue #53249). A Zed-side workaround PR has medium-high political risk. Reserve as nuclear option.

**Why not finish josephschmitt/opencode-acp:** 8 months stale, "early version" by author's admission, unanswered "response never gets finished" issue, would need to absorb 8 months of opencode SDK drift. Bigger surface, less certain payoff than a focused shim.
