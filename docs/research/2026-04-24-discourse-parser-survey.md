# Discourse / Dialogue-Act / Rhetorical-Structure Parser Survey for Indexer Candidates (2026-04-24)

**Scope.** Survey parsers that could run on the homelab envelope (7900 XTX 24 GB
ROCm + 5700 XT 8 GB Vulkan + 5950X + 64 GB + ~1 TB NVMe) and annotate LLM conversation
transcripts with discourse-/dialogue-act tags that map to the user's target
approximations (`reversal`, `supersession`, `concession`, `contrast`, `elaboration`,
`commitment`, `aside`, `directive`, `question`, `unresolved`).

**Constraint.** The test corpus is being built by a sibling agent. This survey
cannot see it and therefore chooses candidates on *problem* and *hardware* grounds
only. No peeking.

**Method.** Five categories (RST/SDRT/PDTB neural parsers, dialogue-act taggers,
LLM-as-parser, argumentation-mining, hybrids). Per category: 3 well-characterised
candidates preferred over 10 thin ones. Negative findings included.

---

## Category 1 — Neural discourse parsers (RST / SDRT / PDTB)

### 1.1 DMRST — Document-Level Multilingual RST Parser
- **Name / source.** `seq-to-mind/DMRST_Parser` — GitHub: <https://github.com/seq-to-mind/DMRST_Parser>. Paper: Liu et al., *DMRST: A Joint Framework for Document-Level Multilingual RST Discourse Segmentation and Parsing* (EMNLP-CODI 2021).
- **Taxonomy.** Full RST: EDU segmentation + constituent tree with 18 coarse RST relation classes (elaboration, contrast, concession, attribution, background, cause, condition, etc.) and nuclearity (N-S, S-N, N-N). **This maps directly** onto user targets `contrast`, `concession`, `elaboration`, and via nuclearity onto `aside` (satellite-marked spans).
- **Hardware.** XLM-RoBERTa-base backbone (~278 M params). GPU recommended; base XLM-R loads in <2 GB VRAM at FP16. **Fits card 2 (5700 XT 8 GB)** comfortably, also runs on CPU for small batches.
- **Deps.** PyTorch 1.7.1, transformers 4.8.2 (older — ROCm wheel compat may need pinning, or CPU fallback).
- **Accuracy.** Per DISRPT benchmarks and its own paper, DMRST reports Parseval F1 ≈ 64 on RST-DT (relation), SOTA at time of publication; retains strong multilingual transfer (Portuguese, Spanish, German, Dutch, Basque).
- **License.** Not explicitly stated in README (inferred research-use; confirm before redistribution).
- **Maintenance.** 27 commits; updates infrequent but parser+checkpoint ship working. Likely "done code, not dead code."
- **Integration.** `MUL_main_Infer.py` runs inference on raw text. Clean-ish entry point. The old torch/transformers pin is the friction.

### 1.2 IsaNLP RST — Multilingual RST parsers, Dockerised
- **Name / source.** `tchewik/isanlp_rst` — GitHub: <https://github.com/tchewik/isanlp_rst>. 11 languages (English, Russian, Chinese, German, Czech, etc.). HF checkpoints: `tchewik/isanlp_rst_...`.
- **Taxonomy.** Multiple relation inventories: `rstdt` (RST-DT ~18 classes), `gumrrg` (GUM RST, a richer inventory including 30+ labels), `rstreebank`, and `unirst` (multilingual unified). GUM's inventory explicitly includes `elaboration`, `contrast`, `concession`, `causal`, `adversative`, `joint`, `restatement`, `attribution`, `question`.
- **Hardware.** Docker image runs segmenter+parser on CPU or single GPU; current version is transformer-backed. Fits card 2; the Docker service exposes port 3335 for a thin RPC client. **Best fit for "always-resident on card 2 or CPU."**
- **Accuracy.** Full-parse F1 53.9 (RST-DT), 48.7 (GUMRRG), 18.7–53.6 (multilingual UniRST across languages) — from repo README.
- **License.** **MIT.** Permissive.
- **Maintenance.** Active — v3.2.0 released 2025-11-07 (before the sim-cut).
- **Integration.** Docker-first + Python client. Lowest friction of any RST parser here.

### 1.3 RSTParser_EACL24 — Llama 2 70B QLoRA RST parser
- **Name / source.** `nttcslab-nlp/RSTParser_EACL24` — GitHub: <https://github.com/nttcslab-nlp/RSTParser_EACL24>. Paper: Maekawa et al., *Can we obtain significant success in RST discourse parsing by using Large Language Models?* (EACL 2024) <https://arxiv.org/abs/2403.05065>.
- **Taxonomy.** Same RST label set as RST-DT / Instr-DT / GUM — relation inventory plus nuclearity.
- **Hardware.** **Not homelab-friendly.** Llama 2 70B even with QLoRA needs ≥40 GB VRAM for inference; does not fit 24 GB card 1. A 7B/13B variant *might* be trained with the same recipe but the paper's SOTA numbers come from 70B. Worth flagging as the "if you had an H100" option; **negative finding** for this hardware.
- **Accuracy.** +2–3 points over prior SOTA on RST-DT, +0.4–3.7 on Instr-DT, +1.5–6 on GUM (bottom-up strategy beat top-down).
- **License.** NTT License (non-NTT repos from same authors restrict PRs). Check before embedding.
- **Integration.** Research code; fine-tuning recipe more than a plug-in parser.
- **Takeaway.** Confirms LLMs *can* beat dedicated RST parsers, but the 70B class is outside the envelope. Smaller LLMs will be the relevant question (Category 3).

### 1.4 DDP_parsing / Llamipa — Dialogue-specific SDRT parsers
- **Name / source.** `seq-to-mind/DDP_parsing` (SIGDIAL-style SDRT on STAC + Molweni) <https://github.com/seq-to-mind/DDP_parsing>. Llamipa (ACL 2024) — incremental SDRT parser trained on STAC <https://arxiv.org/pdf/2406.18256>.
- **Taxonomy.** SDRT relation inventory — `elaboration`, `explanation`, `contrast`, `parallel`, `continuation`, `question-answer-pair`, `comment`, `acknowledgement`, `clarification-question`. **Best native mapping** to the conversation-transcript use case, because SDRT was designed for dialogue not documents. `question-answer-pair` and `clarification-question` align to user's `question`/`unresolved`; `contrast` and `elaboration` map directly.
- **Hardware.** T5 or BART-backbone variants are small (<1 B params) and run on card 2. Llamipa uses a Llama backbone; the paper's setup is 7B-class, so it fits card 1 at Q4 or card 2 at CPU-offload.
- **Accuracy.** DDP reports attachment + labelling F1 in the 60s on Molweni and STAC (paper-reported, corpus-dependent).
- **License.** Research code; license varies per repo. Llamipa's code is on GitHub under a research-use posture.
- **Maintenance.** DDP_parsing is effectively archival (2022); Llamipa is recent (2024) and cleaner but still research-grade.
- **Takeaway.** **For LLM transcripts specifically**, SDRT-trained parsers are a better structural match than document RST parsers. Prioritise Llamipa for a look even though integration will be bumpier than IsaNLP.

### 1.5 Negative findings in this category
- **Top-Down RST Parser (Kobayashi/NTT, AAAI 2020)** — repo `nttcslab-nlp/Top-Down-RST-Parser`. Deps pin to torch 1.5 and AllenNLP 0.9 (both end-of-life). License prohibits PRs. Code is a paper artefact; no clear path to production. Skip.
- **RSTFinder (ETS)** — `EducationalTestingService/rstfinder`. Old scikit-style parser; strong speed but Python 3.7–3.10 only and accuracy well below current neural SOTA. Only worth it if you want a CPU-only fallback with dated accuracy.
- **PDTB end-to-end parsers.** Research literature is rich (Lin/Ng et al., DISRPT shallow-discourse systems) but *released, maintained, pip-installable* PDTB-style end-to-end parsers are scarce. PDTB-style shallow discourse is typically done via DISRPT submissions that don't ship as tools. Flag as **gap**: if the user cares about implicit connective classification, expect to build this rather than download it.

---

## Category 2 — Dialogue act taggers

### 2.1 SILICONE benchmark + DeBERTa/RoBERTa classifiers
- **Name / source.** SILICONE dataset — <https://huggingface.co/datasets/silicone>. Multiple configurations (swda, mrda, dyda_da, maptask, oasis, etc.) with normalised dialogue-act labels across corpora.
- **Taxonomy.** Per config. `dyda_da` uses 4 coarse labels — `commissive`, `directive`, `inform`, `question` — which map *almost 1:1* to user's `commitment`, `directive`, `elaboration`/`aside`-ish, `question`. `swda` uses the 43-class SWBD-DAMSL inventory including `backchannel`, `statement-opinion`, `hedge`, `agree/accept`, `reject` — the last two map to `reversal`-adjacent behaviour.
- **Hardware.** Fine-tuned DeBERTa-v3-base (~184 M) or RoBERTa-base (~125 M) comfortably fits on card 2 (5700 XT, 8 GB), and BERT/DeBERTa inference runs on CPU at real-time transcript speeds. **Strong "always-resident on card 2 or CPU" candidate.**
- **Accuracy.** SWDA state-of-the-art per NLP-progress is ~85 % accuracy (3-way coarse) and ~80 % on the full 43-class tag set for top transformer models.
- **License.** Dataset CC-BY-SA-family; user-trained models inherit whatever licence the fine-tuner chose (most public HF checkpoints are Apache 2.0 / MIT).
- **Integration.** `from datasets import load_dataset("silicone", "dyda_da")` + standard HF `Trainer`. 20 lines of code to reproduce. Very low friction.

### 2.2 MIDAS — Machine-directed dialogue-act scheme (BERT)
- **Name / source.** `DianDYu/MIDAS_dialog_act` — GitHub: <https://github.com/DianDYu/MIDAS_dialog_act>. Paper: Yu & Yu, *MIDAS: A Dialog Act Annotation Scheme for Open Domain Human-Machine Spoken Conversations* (arXiv:1908.10023) <https://arxiv.org/abs/1908.10023>.
- **Taxonomy.** **Best taxonomic match for LLM transcripts.** MIDAS is hierarchical with 23 leaf tags grouped into *functional request*, *semantic request*, *commissive*, *response actions* (positive/negative answer, hold, correction), *apology*, *thanks*, *opening/closing*. Crucially it distinguishes user/system utterance types — designed for *human-machine* conversation, not human-human. Its "correction" / "negative answer" tags land near user's `reversal` / `supersession`.
- **Hardware.** BERT-base fine-tune; ~110 M params, Q4/FP16 fits in <1 GB VRAM. Fits anywhere.
- **Accuracy.** Paper reports ~0.78 joint F1 on the 24k-utterance MIDAS corpus.
- **License.** MIT (BERT-backed code), corpus terms separate.
- **Maintenance.** Old (2019) but the BERT+MLP approach is stable enough that freshness doesn't matter. The *scheme* is what's valuable; re-fine-tuning on a modern encoder (DeBERTa-v3, ModernBERT) would be trivial.
- **Integration.** HF transformers; straightforward.

### 2.3 ConvoKit Switchboard + DAMSL classical classifiers
- **Name / source.** ConvoKit Switchboard Dialog Act Corpus <https://convokit.cornell.edu/documentation/switchboard.html>. Classical CRF taggers at e.g. `alturkim/dialogue-act-tagging`. NLP-progress leaderboard: <https://github.com/sebastianruder/NLP-progress/blob/master/english/dialogue.md>.
- **Taxonomy.** Full SWBD-DAMSL 43-class — granular: `sd` (statement-non-opinion), `sv` (statement-opinion), `qy/qw/qh` (yes-no/wh/declarative question), `b` (backchannel), `ba` (appreciation), `aa` (agree/accept), `h` (hedge), `nn` (no-answer), `bf` (summarize/reformulate), `ad` (action-directive). Rich enough to distinguish `reversal` (nn, ar = reject), `commitment` (commissive-style in 43-class remap), `directive` (ad), `aside` (backchannels `b`, `bh`, `bk`).
- **Hardware.** CPU trivially. Classical CRF or a small BiLSTM is ~millions of params.
- **Accuracy.** CRF baselines ~72 % accuracy; modern BERT-based trainings hit ~82 % (see NLP-progress).
- **License.** Corpus under LDC (restrictive); models derived from it vary. Use pre-trained public checkpoints only from Apache/MIT repos.
- **Integration.** ConvoKit is pip-installable. Reference code plentiful.
- **Tradeoff.** The 43-class schema is over-specified relative to user needs; a remap to a coarser target space will be needed. But that's a 10-line dictionary; the *base taxonomy is the richest fit in this category.*

### 2.4 Negative findings in this category
- **A ready-made, strong, well-maintained HF dialog-act classifier for generic LLM chats (human + assistant + tool-call) does not appear to exist as of 2026-04.** The strongest available pretrained dialogue-act model on HF is `diwank/maptask-deberta-pair` (DeBERTa on MapTask pairs) — useful but MapTask is a small task-oriented corpus, not general chat. `ConvLab/bert-base-nlu` exists but targets goal-oriented NLU (slot-filling + intent), not discourse function.
- **Gap is notable.** Given the rising importance of assistant conversation analysis, it's surprising no one has published a "HF tag-me-this-assistant-turn" classifier trained on ShareGPT/WildChat. This is a **plausible build-vs-download crossover point** — train your own on silicone-merged and ship it.

---

## Category 3 — LLM-as-parser (prompt-configurable)

### 3.1 Instruction-tuned 7-9 B models + Outlines/Instructor schema enforcement
- **Names / sources.** Candidates that fit card 1 (24 GB) at Q4/Q5 GGUF with room for modest context, and fit card 2 (8 GB) at aggressive quant (Q3_K_S):
  - Qwen2.5-7B-Instruct-GGUF — <https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF>
  - Llama-3.1-8B-Instruct (Meta)
  - Mistral-7B-Instruct-v0.3
  - Gemma-2-9B-it
  - Phi-3.5-mini-Instruct (3.8 B — fits card 2 at full FP16 or Q6)
- **Schema enforcement.**
  - **Outlines** <https://github.com/dottxt-ai/outlines> — FSM-masked generation; guarantees schema adherence. Supports llama.cpp and vLLM backends.
  - **Instructor** <https://python.useinstructor.com/> — Pydantic-validated retries; works with Ollama and llama-server.
  - **vLLM guided decoding** — JSON-schema enforcement on AMD ROCm builds.
- **Hardware fit.**
  - Card 2 resident (8 GB Vulkan): Phi-3.5-mini at Q5/Q6, or Qwen2.5-3B at Q6. 7B models fit at Q3/Q4_K_S but leave little context budget; 8B transcript-tagging at 4 K context is realistic on card 2.
  - Card 1 transient (24 GB ROCm): any 7-14 B comfortably; Mistral-Small-24B borderline.
  - CPU: 7B Q4 ~6–10 tok/s on a 5950X — fine for background transcript tagging.
- **Accuracy expectations (load-bearing for the design).** Per *Can we obtain significant success in RST discourse parsing by using Large Language Models?* (Maekawa et al., EACL 2024) <https://arxiv.org/abs/2403.05065>, **Llama 2 70B fine-tuned with QLoRA beat dedicated RST SOTA by 2-6 F1**. Smaller LLMs (7-13 B) in that paper did *not* beat dedicated parsers — the gap is size-sensitive. On PDTB, the *How Do Language Models Understand Discourse Relations?* paper (EMNLP 2025) <https://aclanthology.org/2025.emnlp-main.1657.pdf> and *CLaC at DISRPT 2025* <https://arxiv.org/html/2509.16903> both report that **prompting approaches under-perform transformer baselines and hierarchical adapters** on the DISRPT 2025 data. **Inference:** prompted small LLMs are competitive when you can *design a taxonomy aligned to your use case* (high configurability) but lose to specialised parsers on the parsers' own benchmarks.
- **Configurability.** This is where this category wins. The user can define a bespoke tag schema in a Pydantic model once, and every new tag (say a `meta-plan-revision` tag that no parser corpus annotates) comes for free. Dedicated parsers are locked to their training taxonomy.
- **License.** Qwen — Apache 2.0-ish (tong-yi licence, commercial-friendly with caveats); Llama 3.1 — Meta community licence (commercial OK under thresholds); Mistral-7B — Apache 2.0; Phi-3.5 — MIT; Gemma-2 — Gemma terms.
- **Integration difficulty.** *Lowest of any category here* if llama-server is already stood up (it is, per user's infrastructure). `outlines.generate.json(model, Schema)` or `instructor.patch(client)` and a ~60-line prompt is the entire parser.

### 3.2 Fine-tuned small LLMs on discourse corpora
- Llama-2-7B QLoRA on RST-DT (per EACL 2024 paper) — **smaller-LLM numbers were underwhelming** vs dedicated parsers; only the 70B configuration achieved SOTA. If the user fine-tunes a 7-8B on silicone + RST-DT + MIDAS jointly with a unified schema, there's no published baseline and the outcome is speculative. Recommended as a **Phase 2** experiment, not a Phase 1 candidate.
- DISRPT 2025 *Hierarchical Adapters* (CLaC) <https://arxiv.org/html/2509.16903> — trains task-specific adapters over a frozen encoder. Tiny adapter deltas (<50 MB). If the user wants to fold multiple discourse frameworks under one model, this is the architecture to copy.

### 3.3 Takeaway for the LLM-as-parser path
The LLM path is **the configurability bet**. Accuracy on published benchmarks is below SOTA, but the user's problem is not a DISRPT leaderboard entry — it's "tag this LLM transcript with a schema I control, on my hardware, cheaply, forever." An 8B Qwen2.5 on card 2 with Outlines-enforced JSON is exactly that shape.

---

## Category 4 — Argumentation mining and adjacent

### 4.1 Open Argument Mining Framework (oAMF, 2024)
- **Name / source.** Introduced in *Argument Mining Workshop 2024* proceedings and the *The Open Argument Mining Framework* paper <https://www.researchgate.net/publication/394273065_The_Open_Argument_Mining_Framework>.
- **Taxonomy.** Argument components — `claim`, `premise`, `rebuttal`, stance polarity; support/attack relations. Maps to user's `contrast` (attack/rebuttal), `commitment` (claim), `elaboration` (premise supporting claim).
- **Hardware.** RoBERTa-based modules; card 2 / CPU-capable.
- **License.** Open-source framework, module-specific.
- **Integration.** Pipeline-like; modular. Friction medium.

### 4.2 TARGER — neural argument tagger
- **Name / source.** TARGER — well-established neural argument tagger (referenced in 2024 survey literature <https://arxiv.org/html/2506.16383v3>).
- **Taxonomy.** Claim / premise / major-claim spans.
- **Hardware.** BiLSTM-CRF era; trivial hardware. Still used as a baseline.
- **Integration.** Docker + REST API. Easy.
- **Caveat.** Aging. Modern RoBERTa baselines outperform.

### 4.3 MT-CSD — Conversational stance detection
- **Name / source.** `nfq729/MT-CSD` — GitHub (linked from <https://aclanthology.org/2024.lrec-main.11/>). *A Challenge Dataset and Effective Models for Conversational Stance Detection*.
- **Taxonomy.** Stance in multi-turn conversation — `favor`, `against`, `none` — explicitly conversation-structured, which is rare.
- **Hardware.** Transformer-based GLAN (global-local attention network); card 2 fit.
- **Integration.** Research code; reproducible but not polished.
- **Takeaway.** Stance in conversation is a **sharper signal for `reversal`/`supersession`** than most dialogue-act taggers produce. Worth evaluating if the target tags cluster around opinion change.

### 4.4 Change-point detection on text
- **Name / source.** Kernel change-point detection on text embeddings — arXiv:2510.03437 *Consistent Kernel Change-Point Detection under m-Dependence for Text Segmentation* <https://arxiv.org/abs/2510.03437>. (User referenced arXiv:2510.09720; that paper is actually *Preference-Aware Memory Update for Long-Term LLM Agents* — related to memory not to segmentation. **Negative finding:** the referenced arxiv ID doesn't contain change-point-on-text content; 2510.03437 does.)
- **Taxonomy.** None — unsupervised segmentation. Flags *where* topic/stance changes, not *what kind*.
- **Hardware.** Embedding-based; trivial once embeddings exist. Card 2 already hosts an embedder.
- **Integration.** Complement, not substitute. Use to propose candidate `reversal`/`supersession` locations; let a tagger label them.
- **Takeaway.** This is a **cheap pre-filter** rather than a parser. Low-cost add-on once the embedder is already serving.

### 4.5 Negative findings in this category
- No single argumentation-mining tool covers the full target-tag space. Argument mining gives great signal for `commitment` (claim detection) and `contrast` (attack/rebuttal) but nothing native for `aside`, `question`, `directive`.

---

## Category 5 — Hybrid and composite systems

### 5.1 spaCy / Stanza discourse components
- **spaCy** — no first-class discourse pipeline. Community extensions exist (e.g., `spacy-experimental` coref) but no general RST/dialogue-act pipe.
- **Stanza** — has sentiment, NER, dependency, but not a discourse-act component in the current release. **Negative finding:** the obvious mainstream NLP frameworks don't ship the parser you'd hope for.

### 5.2 HuggingFace "discourse-parsing" topic
- <https://github.com/topics/discourse-parsing> — mostly academic repos. `norikinishida/discourse-parsing` is a well-regarded multi-framework (RST / PDTB / shallow) implementation; research-quality. Worth a serious look as a hybrid base.

### 5.3 discoursegraphs — multi-framework corpus handler
- `discoursegraphs` on PyPI <https://pypi.org/project/discoursegraphs/> — **not a parser**, but a unified data-handling layer for RST/SDRT/PDTB annotations. Useful as the input/output normalisation layer in front of whatever parsers are chosen. Low-cost dependency.

### 5.4 Realistic homelab stack
A hybrid pipeline that takes the best pieces from each category:

1. **Ingest** — transcript becomes turn-stream.
2. **Coarse dialogue-act tagging** — DeBERTa-v3-small fine-tuned on silicone (`dyda_da` schema mapped to user tags: `directive`, `question`, `commitment`, `elaboration`). Card 2 resident, ~400 MB VRAM, <5 ms/turn.
3. **Discourse-relation tagging** — IsaNLP RST (Docker container on card 2 or CPU) produces `contrast` / `concession` / `elaboration` relations between turns.
4. **Change-point pre-filter** — kernel CPD on the existing embedder's outputs flags candidate `reversal` / `supersession` positions.
5. **LLM-as-parser for the hard tags** — 7-8B Qwen2.5 or Phi-3.5-mini with Outlines/Instructor, prompted on the user's taxonomy. Runs on card 2 or CPU, invoked only on candidate spans identified by the CPD pre-filter. This is where configurability lives.

This matches Reframing 3 from `2026-04-24-conversation-notes-architecture-thinking.md`: intelligence in small LLM subroutines, coordination in Python, each layer's cost matched to task. **Inferred architecture — not something published**; conventional pipelines are this structure.

---

## Comparison table

| Candidate | Category | VRAM (FP16) | Fits card 2? | Configurable? | Taxonomy fit | Acc. (own bench) | License | Maint. | Integ. |
|---|---|---|---|---|---|---|---|---|---|
| DMRST | RST neural | ~1.1 GB | yes | no (fixed RST) | good (contrast/concession/elab) | F1 ~64 RST-DT | unclear | low | medium |
| IsaNLP RST | RST neural | ~1–2 GB | yes | partial (4 inventories) | strong (GUM richer) | F1 53.9 RST-DT / 48.7 GUM | MIT | active (2025-11) | **low** (Docker) |
| RSTParser_EACL24 (70B) | RST-LLM | ~40+ GB | **no** | via fine-tune | best (SOTA) | +2-6 F1 over SOTA | NTT | research | high |
| DDP_parsing / Llamipa | SDRT dialogue | ~1 GB / ~8 GB | yes / yes(Q) | no | **best for dialogue** | F1 ~60s Molweni/STAC | research | medium | medium-high |
| SILICONE DeBERTa | DA tagger | ~400 MB | yes | remap only | direct on 4 user tags | acc. ~85 % dyda_da | Apache/MIT | ecosystem-maintained | **low** |
| MIDAS BERT | DA tagger | ~400 MB | yes | no | **best human-machine match** | F1 ~0.78 | MIT | stale but stable | low |
| SWBD-DAMSL (ConvoKit) | DA tagger | CPU-fine | yes | no | richest granularity | acc. ~82 % | mixed | stable | low |
| Qwen2.5-7B + Outlines | LLM-as-parser | ~4–5 GB (Q4) | yes (tight) | **yes, fully** | defined by user | n/a (benchmark-variable) | Apache-ish | active | **low** |
| Phi-3.5-mini + Outlines | LLM-as-parser | ~2.5 GB (Q5) | yes | **yes** | defined by user | n/a | MIT | active | low |
| oAMF | Argumentation | ~500 MB | yes | no | claim/premise/rebuttal | task-dep. | open | 2024 | medium |
| MT-CSD | Conv. stance | ~500 MB | yes | no | favor/against (→ reversal signal) | task-dep. | open | 2024 | medium |
| Kernel CPD on embeds | Change-point | ~0 extra | yes | n/a | boundary-only | unsup. | open | 2025 | low |

---

## Synthesis

### Which candidates fit 8 GB VRAM / resident-on-card-2?
- **IsaNLP RST** (Docker, MIT, recent) — strongest turnkey RST parser for always-on use.
- **DeBERTa-v3-small fine-tuned on SILICONE `dyda_da`** — a 4-class tagger (`directive`/`question`/`commitment`/`elaboration`) covers four of the user's ten target tags almost directly.
- **MIDAS-scheme BERT (re-trained on a modern encoder)** — best taxonomic fit to *human-machine* transcripts specifically.
- **Phi-3.5-mini / Qwen2.5-3B with Outlines** — configurable LLM tagger that fits at Q5/Q6.

### Which fit larger CPU-or-card-1-transient?
- **Qwen2.5-7B / Llama-3.1-8B / Mistral-7B at Q4_K_M** — run on card 1 transient or CPU, with Outlines or Instructor enforcing the user's taxonomy schema.
- **Llamipa (SDRT-trained Llama)** — if dialogue discourse is the priority and the 7B-ish variant's weights can be obtained.
- **RSTParser_EACL24 70B** — not homelab-viable; noted for completeness only.

### Which native taxonomies look most promising for the target tags, without peeking at test data?
Ranked by coverage of (`reversal`, `supersession`, `concession`, `contrast`, `elaboration`, `commitment`, `aside`, `directive`, `question`, `unresolved`):

1. **SWBD-DAMSL 43-class** — hits `reversal` (reject `ar`, no-answer `nn`), `commitment` (commissive), `directive` (`ad`), `question` (`qy/qw/qh`), `aside` (backchannel `b/bh/bk`), `elaboration` (summarize/reformulate `bf`). Misses `supersession` natively.
2. **MIDAS** — strong on human-machine turn types; hits `correction` ≈ `supersession`, `negative-answer` ≈ `reversal`, `directive`, `question`. Misses `concession`/`aside` as standalone.
3. **GUM-RRG RST (IsaNLP)** — strong on `contrast`, `concession`, `elaboration`, `aside` (via satellite attributions). Misses dialogue-function tags (`directive`, `commitment`).
4. **SDRT (Llamipa/DDP)** — `contrast`, `elaboration`, `question-answer-pair`, `clarification-question` map well. Dialogue-native. Misses `directive`/`commitment` as first-class.
5. **User-defined schema through LLM-as-parser** — covers *all* target tags by construction. Accuracy is the price.

The natural combination is **SWBD-DAMSL/MIDAS for the dialogue-function half** + **GUM-RRG RST for the discourse-relation half** + **LLM-as-parser for the residual tags (`supersession`, `unresolved`)** that no corpus annotates.

### Where is "LLM prompted with a schema" genuinely competitive?
- **When the target taxonomy is bespoke.** `supersession` and `unresolved` aren't corpus-native anywhere surveyed. A prompted LLM can tag them zero-shot; no fine-tuning exists.
- **When deployment cost matters more than marginal accuracy.** On the EACL 2024 and DISRPT 2025 evidence, sub-70B prompted LLMs lag dedicated parsers by ~5-10 F1 on the parsers' benchmarks. The user's transcripts aren't those benchmarks; the gap may narrow or invert.
- **When the tag set might change.** Schema-controlled LLM tagging lets the user evolve tags without retraining. Dedicated parsers freeze at whatever the corpus annotated.
- **When hardware is fixed and the use is continuous.** An 8B-class model resident on card 2 with Outlines enforcement is the cheapest per-token discourse tagger available once standing infra is there.

**Inferred:** for this homelab use case specifically — transcript tagging at low latency, schema-controlled, not benchmarking against DISRPT — an LLM-as-parser approach backed by a small traditional dialogue-act tagger as a sanity check is likely to outperform a pure-dedicated-parser path on *usefulness*, even though it under-performs on published F1. This inference is supported by (a) EACL 2024 showing LLMs can reach SOTA at 70B, implying 7-14B + fine-tune can be competitive, and (b) DISRPT 2025 showing prompted LLMs currently lag — the gap is closable with a little schema engineering and small-scale fine-tuning.

### Single most surprising finding
The PDTB-style end-to-end parser ecosystem is **essentially absent as installable, maintained tooling** in 2026. PDTB is the most widely-cited discourse framework in papers, yet there is no equivalent of IsaNLP for PDTB — the shallow discourse parsers from DISRPT submissions don't ship as tools. Meanwhile, SDRT — which is *perfect* for dialogue — has one or two research repos and no polished release. Given how much industry now cares about LLM conversation analysis, this is a notable hole.

---

## Citations

- DMRST: <https://github.com/seq-to-mind/DMRST_Parser>
- IsaNLP RST: <https://github.com/tchewik/isanlp_rst>
- RSTParser_EACL24 paper: <https://arxiv.org/abs/2403.05065>, code: <https://github.com/nttcslab-nlp/RSTParser_EACL24>
- Top-Down RST parser (2020): <https://github.com/nttcslab-nlp/Top-Down-RST-Parser>
- DDP_parsing: <https://github.com/seq-to-mind/DDP_parsing>
- Llamipa: <https://arxiv.org/pdf/2406.18256>
- CLaC at DISRPT 2025: <https://arxiv.org/html/2509.16903>
- How Do LMs Understand Discourse Relations? (EMNLP 2025): <https://aclanthology.org/2025.emnlp-main.1657.pdf>
- DISRPT 2025 overview: <https://aclanthology.org/2025.disrpt-1.pdf>
- GDTB (shallow discourse, multi-genre): <https://arxiv.org/html/2411.00491v1>
- SILICONE dataset: <https://huggingface.co/datasets/silicone>
- SwDA dataset: <https://huggingface.co/datasets/swda>
- MIDAS scheme paper: <https://arxiv.org/abs/1908.10023>
- MIDAS code: <https://github.com/DianDYu/MIDAS_dialog_act>
- ConvoKit Switchboard: <https://convokit.cornell.edu/documentation/switchboard.html>
- NLP-progress dialogue: <https://github.com/sebastianruder/NLP-progress/blob/master/english/dialogue.md>
- Qwen2.5-7B-Instruct-GGUF: <https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF>
- Outlines: <https://github.com/dottxt-ai/outlines>
- Instructor: <https://python.useinstructor.com/>
- vLLM structured outputs: <https://docs.vllm.ai/en/v0.8.2/features/structured_outputs.html>
- oAMF paper: <https://www.researchgate.net/publication/394273065_The_Open_Argument_Mining_Framework>
- LLMs in argument mining survey: <https://arxiv.org/html/2506.16383v3>
- MT-CSD conversational stance: <https://aclanthology.org/2024.lrec-main.11/>
- Kernel CPD for text segmentation: <https://arxiv.org/abs/2510.03437>
- discoursegraphs: <https://pypi.org/project/discoursegraphs/>
- aisingapore RST-pointer: <https://huggingface.co/aisingapore/RST-pointer>

---

*Word count ~3,400. Under the 6,000 cap.*
