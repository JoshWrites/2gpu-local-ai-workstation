# GUM -- Georgetown University Multilayer Corpus

## Description

GUM (Zeldes et al., 2017-present) is a multi-genre open-license English
corpus developed at Georgetown. It is unusual in offering **both**
eRST (enhanced Rhetorical Structure Theory) and GDTB (GUM Discourse
Treebank; PDTB-style shallow-discourse-relation) annotations on the
**same** texts. This makes it an ideal test corpus because a parser
whose output is RST can be evaluated against the eRST gold, and a
parser whose output is PDTB can be evaluated against GDTB gold,
without having to switch corpora.

Genres covered: academic articles, biographies, court opinions,
essays, fiction, interviews, letters, news, podcasts, reddit (requires
separate download), textbooks, vlogs (voyage/travel), wikihow,
wikivoyage, and (for this corpus set) face-to-face **conversation**.

## Two annotation layers per sample

### GDTB (PDTB-style)

Pipe-delimited, one row per discourse relation. Column schema
(from GUM's gdtb README):

```
type | conn_span | ... | connective_text | sense | ... | arg1_span | ... | arg2_span | ... | conn_head | provenance
```

- `type` -- `Explicit`, `Implicit`, `Hypophora`, `EntRel`, `NoRel`,
  `AltLex`, etc.
- `connective_text` -- the discourse connective if explicit, or
  underscore `_` if implicit/none.
- `sense` -- PDTB 3.0 sense hierarchy: `Expansion.Conjunction`,
  `Contingency.Cause.Reason`, `Comparison.Contrast`,
  `Temporal.Synchronous`, etc.
- `arg1_span`, `arg2_span` -- character offsets into the raw text.

### eRST (enhanced RST)

XML `.rs4` format (rstweb tool). Declares a relation inventory in the
`<header>` and the tree of EDUs with `parent`/`relname`/`nuclearity`
attributes. Sample relation names:

```
adversative-antithesis, adversative-concession, adversative-contrast,
attribution-negative, attribution-positive, causal-cause, causal-result,
context-background, context-circumstance, contingency-condition,
elaboration-additional, elaboration-attribute, evaluation-comment,
explanation-evidence, explanation-justify, explanation-motivation,
joint-disjunction, joint-list, joint-other, joint-sequence,
mode-manner, mode-means, organization-heading, organization-phatic,
organization-preparation, purpose-attribute, purpose-goal,
restatement-partial, restatement-repetition, same-unit,
topic-question, topic-solutionhood
```

eRST extends classical Mann-Thompson RST by permitting multiple
signals per relation and more fine-grained sub-types.

## Source

- GitHub: <https://github.com/amir-zeldes/gum>
- Project page: <https://gucorpling.org/gum/>

## How to reobtain

```
git clone --depth 1 https://github.com/amir-zeldes/gum.git
# raw text per document: rst/gdtb/pdtb/raw/00/<doc_id>
# PDTB-style gold: rst/gdtb/pdtb/gold/00/<doc_id>
# eRST .rs4: rst/rstweb/<doc_id>.rs4
# DISRPT .rels format: rst/gdtb/disrpt/<doc_id>.rels
```

## License

- **Code / build scripts**: see repository LICENSE.md.
- **Annotations**: CC BY 4.0.
- **Texts**: vary by document; all are CC-licensed (BY, BY-SA,
  BY-NC-SA variants). See `LICENSE.md` in the repo for the per-genre
  breakdown. All samples in this directory are from non-Reddit sources
  and carry CC-BY-compatible licenses (detail in each `.clean.txt`
  file's source note below).

## Samples in this directory

- **sample-01-conversation** -- `GUM_conversation_christmas`: a family
  Christmas-morning conversation (gift opening). ~1,112 words. Good
  for dialogue with real-world topic shifts, asides ("she's been
  saying for months that you would never wear it"), contrasts
  ("though it doesn't say Stanford over here"). License: CC BY (per
  GUM conversations sourced under CC BY).
- **sample-02-academic** -- `GUM_academic_huh`: an academic article
  about the universal word "huh?" as a conversational repair
  mechanism. ~1,097 words. Heavy on concession, contrast, and
  explanation -- classic academic-prose discourse moves. License:
  CC BY 4.0.
- **sample-03-bio** -- `GUM_bio_byron`: a Wikipedia biography of Lord
  Byron. ~746 words. Mostly narration + elaboration, with some
  causal/result relations. License: Wikipedia CC BY-SA 3.0.

Each sample has three annotation files:

- `sample-XX.clean.txt` -- raw whitespace-tokenized text (same as
  what GUM distributes under `rst/gdtb/pdtb/raw/00/`).
- `sample-XX.annotated.pdtb.txt` -- GDTB (PDTB-style) gold relations.
  Pipe-delimited, see column schema above.
- `sample-XX.annotated.rst.rs4` -- eRST gold tree, XML (rstweb format).
