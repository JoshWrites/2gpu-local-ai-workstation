// permission-classifier — opencode plugin
//
// Intercepts `permission.ask` to classify bash commands into three tiers:
//
//   read    → auto-allow (idempotent, non-mutating)
//   write   → ask (reversible-with-work mutations)
//   remove  → deny with instructions to use confirm_destructive MCP
//
// Classification is transport-independent: `ssh host -- rm -rf /foo`
// classifies identically to `rm -rf /foo`. SSH prefix is stripped before
// the tier match runs.
//
// The full doc lives in `~/Documents/Repos/Workstation/docs/opencode-conventions.md`.
// If you need to change tier definitions, update that doc in the same
// commit as this file so they don't drift.

// ── Tier patterns ────────────────────────────────────────────────────────
//
// Each tier is a list of regex patterns. A command matches a tier if ANY
// pattern matches anywhere in the (SSH-stripped) command string. Classification
// precedence: remove > write > read. If a command matches multiple tiers
// (e.g., `rm` and `ls` on the same line), the most restrictive wins.

const REMOVE_PATTERNS = [
  // File removal
  /\brm\b(?!\s+-ri\b)/,            // rm (any form), but not `rm -ri` (interactive by nature)
  /\bunlink\b/,
  /\brmdir\b/,
  /\bshred\b/,
  /\btruncate\b/,

  // Git destructive
  /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\s+-[a-z]*f/,      // any clean with -f variant
  /\bgit\s+push\s+(-f|--force|--force-with-lease)\b/,
  /\bgit\s+branch\s+-D\b/,
  /\bgit\s+stash\s+(drop|clear)\b/,
  /\bgit\s+checkout\s+--\s/,       // discards uncommitted changes to files
  /\bgit\s+restore\s+.*--staged\b.*--worktree\b/,  // aggressive restore
  /\bgit\s+worktree\s+remove\b/,

  // Docker destructive
  /\bdocker\s+(rm|rmi)\b/,
  /\bdocker\s+image\s+rm\b/,
  /\bdocker\s+volume\s+rm\b/,
  /\bdocker\s+network\s+rm\b/,
  /\bdocker\s+system\s+prune\b/,
  /\bdocker\s+compose\s+down\s+(-v|--volumes)\b/, // down with volumes removed

  // Package removal
  /\bapt(-get)?\s+(purge|remove)\b/,
  /\bdpkg\s+(-P|--purge|-r|--remove)\b/,
  /\bpip\s+uninstall\b/,
  /\bnpm\s+uninstall\b/,
  /\byarn\s+remove\b/,
  /\bsnap\s+remove\b/,

  // Proxmox destructive
  /\bpct\s+(destroy|rm|unlink)\b/,
  /\bqm\s+(destroy|stop)\b/,       // qm stop is forceful; see note

  // Block-device destruction
  /\bdd\s+/,                       // any dd
  /\bmkfs(\.\w+)?\b/,
  /\bwipefs\b/,
  /\bblkdiscard\b/,

  // Power state
  /\breboot\b/,
  /\bshutdown\b/,
  /\bhalt\b/,
  /\bpoweroff\b/,
  /\binit\s+[06]\b/,
  /\bsystemctl\s+(reboot|poweroff|halt)\b/,

  // User/group removal
  /\buserdel\b/,
  /\bgroupdel\b/,

  // Forceful process kill (kill -9, killall, pkill)
  /\bkill\s+-(9|KILL)\b/,
  /\bkillall\b/,
  /\bpkill\b/,

  // Database destructive
  /\bdropdb\b/,
  /\bDROP\s+(TABLE|DATABASE|SCHEMA)\b/i,
  /\bFLUSHALL\b/i,
  /\bTRUNCATE\s+TABLE\b/i,
];

const WRITE_PATTERNS = [
  // Filesystem mutation (non-destructive)
  /\bmkdir\b/,
  /\btouch\b/,
  /\bcp\b/,
  /\bmv\b/,
  /\bchmod\b/,
  /\bchown\b/,
  /\bchgrp\b/,
  /\bln\b/,

  // File writes / redirection
  /\btee\b/,
  /\bsed\s+-i\b/,
  /\bawk\s+-i\b/,
  />\s*\S/,                        // redirect to file
  />>\s*\S/,                       // append to file

  // Git write (non-destructive)
  /\bgit\s+(add|commit|merge|rebase|stash|cherry-pick|checkout|switch|tag|fetch|pull|push)\b/,
  // Note: `git push -f` was caught above as remove; plain `git push` is write.

  // Service lifecycle
  /\bsystemctl\s+(start|stop|restart|reload|enable|disable|daemon-reload|mask|unmask)\b/,

  // Docker lifecycle (non-destructive)
  /\bdocker\s+(run|start|stop|restart|build|create|exec|pull|push|tag)\b/,
  /\bdocker\s+compose\s+(up|start|stop|restart|build|pull|exec)\b/,
  // docker compose down WITHOUT -v is write (reversible by up)

  // Package install (not remove)
  /\bapt(-get)?\s+(update|upgrade|install|dist-upgrade)\b/,
  /\bpip\s+install\b/,
  /\bnpm\s+install\b/,
  /\byarn\s+(add|install)\b/,
  /\bcargo\s+(install|build)\b/,
  /\bgem\s+install\b/,
  /\bsnap\s+install\b/,

  // Proxmox lifecycle (non-destructive)
  /\bpct\s+(start|stop|reboot|set|resize|push|pull)\b/,

  // Mount ops
  /\bsshfs\b/,
  /\bfusermount\s+-u\b/,
  /\bmount\b/,
  /\bumount\b/,

  // Non-lethal signals
  /\bkill\b/,                      // kill without -9 (-9 caught in remove above)

  // Network writes
  /\bcurl\s+.*-X\s+(POST|PUT|PATCH|DELETE)\b/,
  /\bwget\s+--post-data\b/,
];

const READ_PATTERNS = [
  // File inspection
  /^ls\b/,
  /^cat\b/,
  /^head\b/,
  /^tail\b/,
  /^less\b/,
  /^more\b/,
  /^file\b/,
  /^stat\b/,
  /^wc\b/,
  /^grep\b/,
  /^rg\b/,
  /^ag\b/,
  /^find\b(?!.*-delete)(?!.*-exec\s+rm)/,   // find without destructive exec

  // Process/system info
  /^ps\b/,
  /^ss\b/,
  /^netstat\b/,
  /^top\b/,
  /^htop\b/,
  /^free\b/,
  /^df\b/,
  /^du\b/,
  /^uptime\b/,
  /^lsof\b/,
  /^lsblk\b/,
  /^lscpu\b/,
  /^lspci\b/,
  /^lsusb\b/,

  // Service inspection
  /^systemctl\s+(status|list-|is-|cat|show)\b/,
  /^journalctl\b/,

  // Docker inspection
  /^docker\s+(ps|logs|inspect|images|stats|version|info|history)\b/,
  /^docker\s+compose\s+(ps|logs|config|top)\b/,

  // Git read
  /^git\s+(status|log|diff|show|blame|branch|remote|config\s+--get|describe|rev-parse|ls-files|ls-tree|reflog)\b/,

  // Proxmox read
  /^pct\s+(list|config|status|enter|exec)\b/,   // pct exec is read because the inner command is itself classified
  /^pveversion\b/,
  /^pvesm\s+status\b/,
  /^pvesh\s+get\b/,

  // Shell introspection
  /^which\b/,
  /^whereis\b/,
  /^type\b/,
  /^echo\b/,
  /^pwd\b/,
  /^date\b/,
  /^whoami\b/,
  /^id\b/,
  /^env\b/,
  /^hostname\b/,
  /^uname\b/,

  // Network read
  /^dig\b/,
  /^nslookup\b/,
  /^host\b/,
  /^ping\b/,
  /^traceroute\b/,
  /^mtr\b/,
  /^curl\s+-s(\s|$)(?!.*-X\s+(POST|PUT|PATCH|DELETE))/, // silent curl without mutation method
  /^nc\s+-z\b/,

  // Data tools
  /^jq\b/,
  /^yq\b/,

  // Python / shell one-liners that are clearly non-mutating
  /^python3?\s+-c\s+["']print\(/,
];

// ── Transport stripping ─────────────────────────────────────────────────

// Strip `ssh <host>` or `ssh <host> --` from the front of a command so
// classification is transport-independent.
function stripSshPrefix(command) {
  return command.replace(/^\s*ssh\s+\S+\s+(?:--\s+)?/, '').trim();
}

// Also handle `pct exec N --` which opencode sessions use to reach into LXC
// containers. The command inside should be classified, not the pct wrapper.
function stripPctExecPrefix(command) {
  return command.replace(/^\s*(sudo\s+)?pct\s+exec\s+\d+\s+--\s+/, '').trim();
}

// Strip leading `sudo` so `sudo rm` classifies like `rm`.
// We do NOT classify sudo as write-tier on its own — the content is what matters.
function stripSudoPrefix(command) {
  return command.replace(/^\s*sudo\s+(-[A-Za-z]+\s+)*/, '').trim();
}

// Apply all strips in order. For a command like
// `ssh levinelabsserver1 -- sudo pct exec 100 -- docker rm jellyfin`,
// this returns `docker rm jellyfin`.
function normalize(command) {
  let prev;
  let cur = command;
  // Loop until fixed point so nested ssh -> pct exec -> sudo layers collapse
  do {
    prev = cur;
    cur = stripSshPrefix(cur);
    cur = stripPctExecPrefix(cur);
    cur = stripSudoPrefix(cur);
  } while (cur !== prev);
  return cur;
}

// ── Classification ──────────────────────────────────────────────────────

function matchesAny(command, patterns) {
  return patterns.some((re) => re.test(command));
}

function classify(command) {
  const normalized = normalize(command);
  // Safety-biased ordering: check remove first, then write, then read.
  // A command matching both remove and read (`grep "rm -rf" log.txt` — actually
  // should NOT match remove because we use word boundaries, but even if
  // edge cases slip through, we fail safe toward remove).
  if (matchesAny(normalized, REMOVE_PATTERNS)) return 'remove';
  if (matchesAny(normalized, WRITE_PATTERNS)) return 'write';
  if (matchesAny(normalized, READ_PATTERNS)) return 'read';
  // Unclassified → fall back to write (ask). Bias toward friction, not danger.
  return 'write';
}

// ── Phrase derivation (kept in sync with confirm_destructive.py) ────────

const DESTRUCTIVE_VERBS = [
  'shutdown', 'reboot', 'halt', 'poweroff',
  'mkfs', 'wipefs', 'blkdiscard', 'shred', 'dd',
  'purge', 'uninstall',
  'rmi', 'destroy',
  'reset', 'clean',
  'killall', 'pkill',
  'rm', 'kill', 'unlink', 'truncate', 'rmdir',
  'dropdb', 'flushall', 'drop',
  'userdel', 'groupdel',
];

function extractVerb(command) {
  for (const verb of DESTRUCTIVE_VERBS) {
    const re = new RegExp(`\\b${verb}\\b`);
    if (re.test(command)) return verb;
  }
  return null;
}

function extractIdentifier(command, verb) {
  const cmd = normalize(command);
  // Loose tokenization
  const tokens = cmd.split(/\s+/).filter(Boolean);

  // Unwrap bash -c "..." or sh -c "..."
  let effectiveTokens = tokens;
  if (tokens.length >= 3 && /^(bash|sh|zsh)$/.test(tokens[0]) && tokens[1] === '-c') {
    const inner = tokens.slice(2).join(' ').replace(/^['"]|['"]$/g, '');
    effectiveTokens = inner.split(/\s+/).filter(Boolean);
  }

  // Strategy 1: last path segment
  for (let i = effectiveTokens.length - 1; i >= 0; i--) {
    const tok = effectiveTokens[i];
    if (tok.includes('/')) {
      const segment = tok.replace(/\/+$/, '').split('/').pop();
      if (segment) return segment;
    }
  }

  // Strategy 2: last non-flag token that isn't the verb
  for (let i = effectiveTokens.length - 1; i >= 0; i--) {
    const tok = effectiveTokens[i];
    if (tok && !tok.startsWith('-') && tok !== verb) return tok;
  }

  return 'this';
}

function computeExpectedPhrase(command) {
  const stripped = normalize(command);
  const verb = extractVerb(stripped);
  if (!verb) return null;
  const identifier = extractIdentifier(command, verb);
  return `yes ${verb} ${identifier}`;
}

// ── Plugin entry ────────────────────────────────────────────────────────

// Diagnostic logger: writes every permission.ask input to a file we can
// inspect. Keep this until classifier is stable; delete when retired.
import { appendFileSync } from 'node:fs';
const DIAG_LOG = '/tmp/permission-classifier-diag.log';
function diagLog(label, obj) {
  try {
    appendFileSync(
      DIAG_LOG,
      `${new Date().toISOString()} ${label}\n${JSON.stringify(obj, null, 2)}\n---\n`
    );
  } catch (e) {
    // diagnostic logging must never break the plugin
  }
}

// Fires at module load time — confirms opencode actually imported us.
diagLog('module loaded', { pid: process.pid, cwd: process.cwd(), argv: process.argv.slice(0, 2) });

// ── Plugin entry ────────────────────────────────────────────────────────
//
// Opencode's `permission.ask` hook is declared in its TypeScript types but
// never actually dispatched at runtime (upstream issue sst/opencode#7006 as
// of 2026-04-23). We use `tool.execute.before` instead, which DOES fire.
//
// Trade-offs of this hook:
// - We see every tool call, not just ones that fell through the ruleset —
//   so we always get a chance to classify
// - Denial is by throwing an error; GLM sees a tool failure with our message
// - Read-tier "auto-allow" is implicit (we just don't throw)
// - Known limitation (upstream #5894): subagent-spawned bash calls bypass
//   this hook. For our flows this is acceptable; documented in the
//   conventions doc

export const PermissionClassifier = async (ctx) => {
  diagLog('plugin factory invoked', { ctxKeys: Object.keys(ctx || {}) });

  return {
    'tool.execute.before': async (input, output) => {
      // Only classify bash. Other tools (edit, read, write, etc.) have
      // their own handling via opencode's native permission system.
      if (input?.tool !== 'bash') return;

      const command =
        typeof output?.args?.command === 'string' ? output.args.command : null;

      diagLog('tool.execute.before bash', {
        tool: input?.tool,
        command,
        classifiedAs: command ? classify(command) : 'NO_COMMAND',
      });

      if (!command) {
        // No command visible — don't interfere.
        return;
      }

      const tier = classify(command);

      // Read tier: let it run. Opencode's own ruleset will auto-allow it
      // if it has a matching `allow` pattern, or will ask if it doesn't.
      // We bias toward not creating friction for reads.
      if (tier === 'read') return;

      // Write tier: pass through to opencode's native ask flow. We don't
      // block or modify anything; opencode's dialog handles approval.
      if (tier === 'write') return;

      // Remove tier: block execution with an instructive error. GLM sees
      // this as a tool failure and should recover by asking the user for
      // the confirmation phrase and calling confirm_destructive_confirm.
      if (tier === 'remove') {
        const expected = computeExpectedPhrase(command);
        const message = [
          `REMOVE-TIER COMMAND BLOCKED by the permission classifier.`,
          ``,
          `Command:`,
          `  ${command}`,
          ``,
          `This command is destructive or irreversible and requires typed`,
          `confirmation from the user. Do the following:`,
          ``,
          `1. Ask the user in chat to type this phrase verbatim:`,
          `   ${expected}`,
          `2. Take the user's typed reply verbatim (no paraphrasing).`,
          `3. Call the confirm_destructive MCP tool:`,
          `   confirm_destructive_confirm(`,
          `     command=${JSON.stringify(command)},`,
          `     phrase=<what-the-user-typed>`,
          `   )`,
          `4. If the MCP returns status "rejected", show the expected phrase`,
          `   to the user again and let them retry.`,
          ``,
          `Do NOT try to work around this by rewording the command, chaining`,
          `it with other operations, or calling a different tool. The`,
          `challenge exists to protect the user from accidental destruction.`,
        ].join('\n');

        diagLog('blocking remove-tier command', { command, expected });
        throw new Error(message);
      }

      // Fall through (unclassified): do nothing, let opencode handle via
      // its native `bash *` → ask rule.
    },
  };
};

export default PermissionClassifier;
