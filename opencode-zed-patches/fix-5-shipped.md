# Fix 5 - what shipped

Branch: `rules-refinement`. Built 2026-05-02 (build tag
`0.0.0--202605012057`). Continues the file-tool UX work begun in
fix-3 and fix-4.

## What works now

- **Write/edit approval cards preview the proposed content** before
  the user clicks approve. The preview is capped at 15 lines.
- **The preview is syntax-highlighted** for known languages. Python,
  JavaScript, TypeScript, Go, Rust, Ruby, Java, C/C++, Bash, JSON,
  YAML, TOML, Markdown, HTML, CSS, SQL, Lua, PHP, Swift, Kotlin,
  Scala, R, Dart - tag derived from the file extension. Unknown
  extensions get an untagged fence (still preformatted, no
  highlighting).
- **The truncation note appears above the code**, not below. The
  headline content block carries the description on line 1 and a
  truncation note like `(showing first 15 of 47 lines; 32 more
  lines truncated)` on line 2 when applicable. Putting it above
  keeps the code block visually clean.

## How the rendering works

Three Zed renderers were considered:

1. **`type: "diff"` content block** (the structured diff with
   `oldText`/`newText`). Renders as a colorful diff card but does
   not collapse on the approval prompt - a full-file write expands
   the prompt to the file's height. Rejected for that reason.
2. **`type: "content"` text block, raw text.** Goes through Zed's
   markdown renderer. Indented source code (Python especially)
   collapses paragraphs across soft line breaks and treats
   four-space-indented blocks as nested cards. Rejected because
   the result was unreadable.
3. **`type: "content"` text block, markdown-fenced.** Same
   renderer, but wrap the body in ` ```<lang> ... ``` `. Markdown
   treats the fence as preformatted code, preserving line breaks
   and indentation. Language tag enables syntax highlighting.
   Shipped.

## How it surfaced

User feedback after fix 4 ("the description shows but I can't see
what's about to be written before approving"). Iterating through
the three renderer choices above produced visible regressions
along the way - useful to capture in this doc so future-us does
not re-derive the same dead ends.

## What changed

`packages/opencode/src/acp/agent.ts`, in the `requestPermission`
block (`promptContent` construction). Two content blocks pushed
when path and description are both present:

1. Headline: description on line 1, optional truncation note on
   line 2. Plain text content block.
2. Body: first 15 lines of `newString` (edit) or `content` (write),
   wrapped in a fenced code block with a language tag derived from
   the file extension.

The 15-line cap is a constant `PREVIEW_LINES`. Adjust at the call
site if you want a different threshold.

## What this does NOT change

- The completed-card rendering. After approval the existing
  `type: "diff"` content block fires (live and replay paths) and
  the user sees the full structured diff. The 15-line preview is
  approval-card-only.
- Bash. Bash's `_meta.terminal_info` treatment is untouched - it
  already renders correctly as a collapsible terminal cell.
- File-tool failure mode. If the model emits a write/edit call
  without `newString`/`content` (e.g. malformed), the headline
  block still appears with description; only the code preview
  is omitted.

## Verifying the fix

1. Open Zed in the isolated profile.
2. Ask GLM to write a Python script of at least 30 lines.
3. Confirm the approval card shows: title (`write /path/foo.py`),
   headline (description + truncation note), code preview (gray
   box, syntax-highlighted, ~15 lines, copy icon).
4. Click approve. Confirm the post-approval card still shows the
   full structured diff (no regression).
5. Repeat with an edit on a smaller file (under 15 lines).
   Confirm no truncation note appears and the full new content
   shows in the code preview.
