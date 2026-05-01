# Global agent rules

## The Library MCP

The `library` MCP server is the preferred path for five things:

1. **Question-shaped file access** -- `library_read_file(path, query)`
2. **Web research** -- `library_research(question)`
3. **On-demand instruction sets** -- `library_get_skill(name)`
4. **Full document conversion to disk** -- `library_convert(src_path, ...)`
5. **Markdown export to binary formats** -- `library_export(src_path, ...)`

The first three share a *summary layer* return contract: by default they
return a summary, with the option to escalate to *raw chunks* if the
summary is insufficient. This protects primary-model context from being
flooded with verbatim source material.

`library_convert` and `library_export` are different: they write the
result to disk and return only metadata (path, byte count). The agent
never sees the converted content. Use them when the user wants the full
file, not a summary.

---

## `library_read_file` -- prefer over `read` for question-shaped access

When the user asks a question *about* a file's contents ("how does X work
in this config?", "what does the plan say about Y?", "summarize the
security policy"), call `library_read_file(path, query)` instead of
`read`.

The Library chunks the file, embeds it on the secondary card, and returns
either a summary (default) or the top-ranked chunks. Reading the whole
file costs primary-model context proportional to the file size; the
Library costs ~1-5K regardless.

**Supported formats:**
- Text: `.md` `.txt` `.py` `.js` `.ts` `.go` `.json` `.yaml` `.toml` etc.
- Binary documents (auto-converted via the docling sidecar):
  `.pdf` `.docx` `.pptx` `.xlsx` `.epub` `.html` `.htm`
  Images with text: `.png` `.jpg` `.jpeg` `.tiff`

Use `read` only when:
- The user wants the *whole file* verbatim (e.g., to reproduce it).
- You need to edit the file.
- The file is tiny (< 100 lines).
- The Library is unavailable (call failed, tool not listed).

---

## Multilingual retrieval

The Library uses `multilingual-e5-large` for embeddings, which supports
Hebrew, Arabic, Russian, Chinese, and 90+ other languages alongside
English. This means:

- A query in any supported language finds chunks in any supported
  language. You can ask "what does this MRI report say?" in English
  and the Library will rank Hebrew chunks correctly.
- The user can ask the same question in their preferred language;
  retrieval works either way.

**Caveat (current):** the summarizer model is still English-primary.
For non-English source documents, the *retrieval* finds the right
content, but the *summary* may be lower quality, generic, or default
to English explanations of non-English material. A bilingual summarizer
swap is planned but not yet shipped -- see the multilingual plan in
`local-mcp-servers/docs/superpowers/plans/`.

In the meantime: if a user is working with non-English documents and
the summary seems thin, escalate to `return_chunks=True` early. The
chunks will be in the source language, faithful to the original.

---

## `library_research` -- prefer over self-fetching for the web

When you need information that isn't in context -- documentation, current
events, third-party API docs, error messages -- call `library_research(question)`
**before** falling back to `webfetch`.

The Library searches via SearxNG, fetches the top sources, chunks and
embeds them on the secondary card, and returns a summary with citations.
Self-fetching with `webfetch` bloats context with raw HTML; the Library
returns ~1-5K of distilled answer regardless of source size.

Pages are cached in DRAM for the session -- calling `library_research` again
on a related question reuses the fetches automatically.

---

## `library_get_skill` - on-demand instruction sets

Skills are full instruction sets stored in the Library and pulled into
context only when needed. The Library exposes whatever skill files exist
in its `library/skills/` directory at the time of the call.

Discover available skills by calling `library_get_skill` with no name,
or with a name you expect to exist. The Library responds with the skill
content if found, or with a list of available skills if the name does
not match.

The skill content is returned verbatim. Follow its instructions
directly.

---

## `library_convert` -- full binary doc to text on disk

When the user wants the *full* converted document (e.g. "convert
foo.docx to markdown", "give me the markdown of this PDF", "extract the
text from this scanned page"), call `library_convert(src_path, ...)`
instead of `read_file` or `read`.

The Library reads the source bytes, sends them to the docling sidecar,
and writes the result to disk. The response contains only metadata --
src/dest path, output format, byte count. No content reaches your
context, so this works for arbitrarily large documents at constant cost.

**Supported source extensions:** `.pdf` `.docx` `.pptx` `.xlsx` `.epub`
`.html` `.htm` `.png` `.jpg` `.jpeg` `.tiff` `.tif`. 50 MB cap per file.

**Output formats:** `md` (default), `json`, `html`, `text`, `doctags`.

**`dest_path` defaults** to `<src_dir>/<src_stem>.<ext>` -- e.g.
`foo.docx` becomes `foo.md` in the same directory. Pass an explicit
`dest_path` if the user wants it elsewhere.

**`overwrite=False` by default.** If the destination exists, the call
returns an error rather than clobbering. Only pass `overwrite=True`
when the user has explicitly said to replace the existing file.

Use `library_read_file` instead when the user asks a *question about*
the file rather than asking for the full conversion.

---

## `library_export` -- markdown to binary doc on disk

Inverse of `library_convert`. When the user wants to produce a `.docx`,
`.pdf`, `.odt`, `.html`, `.epub`, etc. from markdown, call
`library_export(src_path, output_format=...)`.

Backed by `pandoc` (system binary). Same metadata-only return contract
as `library_convert`.

**Source formats accepted:** `.md` (default), `.markdown`, `.rst`,
`.html`, `.tex`, `.org`, `.txt`. Other extensions are read as markdown.

**Output formats:** `docx` (default), `odt`, `rtf`, `html`, `epub`,
`pdf`, `latex`. PDF output requires `texlive-xetex` on the system.

`dest_path` and `overwrite` behave the same as in `library_convert`.

---

## The two-layer return contract

The summary-layer tools (`library_research`, `library_read_file`,
`library_get_skill`) return one of:

```
{ "layer": "summary",  "summary": "...", "sources": [...], "confidence": "high|medium|low",
  "can_escalate": true }

{ "layer": "chunks",   "results": [{ "score": ..., "content": ..., "metadata": {...} }, ...],
  "can_escalate": false }

{ "layer": "skill",    "name": "...", "content": "..." }

{ "layer": "error",    "error": "...", "can_escalate": false }
```

- **Default call returns `summary`.** Read it. If it answers the question,
  you're done.
- **If the summary is insufficient**, call the same tool again with
  `return_chunks=True`. You get the top-ranked verbatim chunks. This does
  *not* count as a new research round.
- **If chunks still don't answer the question**, refine your query and
  call again. That *does* count as a new round.

The disk-write tools (`library_convert`, `library_export`) return one of:

```
{ "layer": "converted", "src_path": "...", "dest_path": "...",
  "output_format": "md", "bytes": 12345 }

{ "layer": "exported",  "src_path": "...", "dest_path": "...",
  "output_format": "docx", "bytes": 23456 }

{ "layer": "error",     "error": "...", "can_escalate": false }
```

These do not have a chunks/summary layer -- the result is on disk, not
in the response. Confirm the write to the user (path, byte count); do
not read the file back into context unless they ask for its contents.

---

## The 3-round escalation protocol

For each distinct topic, the protocol is:

| Round | Action |
|-------|--------|
| 1 | `library_research(question)` -> summary. If insufficient, `return_chunks=True` (same round). |
| 2 | `library_research(refined_question)` -> summary, optionally chunks. |
| 3 | `library_research(further_refined_question)` -> summary, optionally chunks. |
| Fallback | If no round produced sufficient information, fall back to `webfetch` directly. |

A **new topic** in the same turn always resets to round 1. The Library is
stateless across calls; you carry the round count.

The same protocol applies to `library_read_file` for distinct queries
about the same file.

---

## When the user says "force refresh" or "the doc has changed"

Call `library_research(question, force_refresh=True)` to bypass the cache
and re-fetch from source. The user is a more reliable judge of staleness
than you are, since they can see the source and you cannot. **Only set
`force_refresh=True` when the user instructs it.**
