# Coding-outcome baseline — 2026-08-29 (RFC-0396 W2 smoke)

> Superseded the same day: the 0/2 below turned out to measure the approval
> gate, not the model — see [`../20260829-ungated`](../20260829-ungated/NOTES.md)
> for the resolution (#31640) and the 2/2 collection that followed. This file
> stays as the record of the gated state.

First live collection through `scripts/harness_coding_eval.sh`. One case
(`l1-calc-add`, L1 single-file bug fix), n=2, local Ollama, isolated server
per invocation. The pass verdict is the case verify script's exit code
(RFC-0396 D2).

## Configuration

| Item | Value |
|---|---|
| Model | `ollama:qwen3:8b` (runtime declared per-run by the harness into the isolated config copy) |
| Case | `l1-calc-add`, `timeout_sec = 900` |
| Repeats | 2 |
| Host | MacBook M3 Max 128GB; ollama serving 100% GPU |
| Cloud fallback | disabled — the harness unsets `OLLAMA_CLOUD_API_KEY` so a broken local runtime fails loudly instead of silently measuring another model |

## Result

**pass@1 = 0.00 over n=2 (`min_runs_met=false` — below the n≥5 gate).**
Both runs hit the 900s episode budget: `timeout` bucket, `verify_exit=1`,
workspace unchanged, zero recorded tool calls.

## What the episodes actually did (issue #31640)

The failure is not slow generation. From the isolated server's turn telemetry
(`live-*/server.log`):

- Keeper prompt is **17,950 tokens** against a 32,768 context window. First
  prefill 380 tok/s (~49s); subsequent rounds hit the prompt cache and cost
  `latency_ms≈2000`.
- Rounds emit almost nothing (+~50 tokens each, `thinking_present=false`) and
  produce **no tool dispatch**, yet consecutive rounds are **~182s apart**
  (14:52:24 → 14:55:26 → 14:58:29 → 15:01:31 → 15:04:33). Five rounds spend
  the whole 900s budget.
- A larger local model (`Qwen3.8-27B` GGUF, single probe run at the same
  budget) managed exactly two successful `Read` calls and then the same
  pattern.

Interpretation: the LLM round-trip is ~2s, so ~180s per round lives in the
agent loop between rounds — an apparent wait/backoff when the round output
does not parse into a tool call. That loop behavior is masc's, not the
harness's, and is filed as **#31640**. The 17.9k-token keeper prompt is the
other measured cost driver, which makes RFC-0389-style per-keeper tool-surface
reduction a measurable improvement for this suite.

## Reading these numbers

This is the honest starting line the corpus exists to draw: with today's
keeper surface and a local model, even an L1 one-line fix does not complete.
Tool-improvement PRs (RFC-0396 D6) and #31640 get judged against exactly this
report shape — same case, same command, before/after.

```bash
scripts/harness_coding_eval.sh --models "ollama:qwen3:8b" \
  --case-ids l1-calc-add --repeats 2 --out <dir>
```
