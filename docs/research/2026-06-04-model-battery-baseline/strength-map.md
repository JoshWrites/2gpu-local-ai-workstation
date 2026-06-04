# Pool strength map (from model cards + web research, 2026-06-04)

| Model | Reported strengths | Reported weaknesses |
|-------|-------------------|---------------------|
| gemma-4-12b | Multilingual (incl. Hebrew/RTL), fast generalist, thinking model, very context-efficient | Not a coding specialist; over-thinks if unguided; 12B knowledge ceiling |
| glm-4.7-flash | Coding (SWE-bench ~59%), agentic tool sequencing, math (AIME) | Weak general knowledge (MMLU-Pro ~60); English+Chinese only; severe context degradation past ~15-30K; logic puzzles |
| qwen3-coder-30b | Agentic coding, repo-scale understanding, function-call format, 256K ctx | Verbose; not for general chat/translation; non-reasoning |
| qwen3-next-80b-thinking | Frontier reasoning, math (AIME 87.8%), GPQA, traceable steps, planning | Slow (~25-35 tok/s); overkill for simple tasks |
| qwen3-next-80b-instruct | Stable formatting over long inputs, RAG/tool/agent orchestration, predictable | Slow; no surfaced reasoning; not for hard step-by-step proofs |

## Coverage dimensions the battery must probe
1. Multilingual / RTL (gemma, [aya on disk])
2. Coding generation (glm, qwen3-coder)
3. Agentic coding / tool sequencing (qwen3-coder, glm)
4. Hard reasoning / math (qwen3-next-thinking, glm)
5. Logic puzzles (thinking models; glm reported weak)
6. General world knowledge (qwen-80b; glm reported weak)
7. Long-context stability (qwen-80b instruct; glm reported weak)
8. Tool use - real Library MCP (instruct/orchestration models)
9. Instruction-following / formatting (instruct variants)
10. Reasoning modulation (gemma - our prompt's job)
