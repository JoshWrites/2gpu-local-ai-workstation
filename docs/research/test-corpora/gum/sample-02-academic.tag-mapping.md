# GUM sample-02 (academic_huh) — tag mapping notes

Academic article on "huh?" as a universal conversational-repair
particle. ~1,097 words. Formal written prose with heavy
argumentation — rich in concession, contrast, and explanation.

## Why this sample

Academic prose is where RST/PDTB parsers were historically trained
(WSJ, PLOS). It's the **high-resource genre** for these taxonomies.
If a parser doesn't perform well on this sample, it likely won't
perform well anywhere else; a floor test.

## Target tags expected

Concession-heavy: "X has been argued, but Y" patterns abound in
academic argumentation. Contrast-heavy: comparisons between languages
(on huh? being cross-linguistic) invite parallel / contrast relations.

Elaboration-heavy: each claim is typically followed by evidence /
example / further unpacking → many `elaboration-additional`,
`elaboration-attribute`, `explanation-evidence`,
`explanation-justify`, `explanation-motivation` relations in eRST.

Directive/question/commitment/aside/reversal/supersession: mostly
absent. Academic prose doesn't supersede itself (within one paper),
doesn't issue directives, rarely asks open questions that go
unresolved.

## Mapping

See `sample-01-conversation.tag-mapping.md` for the full mapping
table — it applies equally here. The **difference** is frequency:

| Our tag       | sample-01 (conversation) | sample-02 (academic)   |
|---------------|--------------------------|------------------------|
| contrast      | common                   | very common            |
| concession    | occasional               | very common            |
| elaboration   | very common              | very common            |
| question      | occasional (rhetorical)  | rare (only rhetorical) |
| directive     | rare                     | rare                   |
| commitment    | occasional               | rare                   |
| reversal      | absent                   | absent                 |
| supersession  | absent                   | absent                 |
| aside         | common                   | occasional (footnotes) |
| unresolved    | occasional               | rare                   |

## Takeaway for the parser survey

Academic prose is the genre where parsers' self-reported accuracy
numbers are most valid. Cross-checking those numbers against this
sample is a sanity test. **Degraded performance** of the same parser
on the conversation sample (sample-01) is the diagnostic worth
watching.
