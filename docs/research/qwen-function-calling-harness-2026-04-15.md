# Qwen Function Calling Harness Notes

**Date**: 2026-04-15
**Source**: https://dev.to/samchon/qwen-meetup-function-calling-harness-from-675-to-100-3830
**Status**: saved for local adoption review

## What mattered

The useful part is not the headline number. The useful part is the harness shape:

1. `parse -> coerce -> validate -> structured feedback -> bounded retry`
2. keep the validator deterministic and cheap before asking the model to try again
3. measure `first try` and `final converged` separately
4. use weaker local models as QA probes because they expose brittle schema and recovery paths faster

The article's concrete examples that map well to `masc-mcp`:

- lenient parse + type coercion before hard rejection
- field-path feedback instead of generic "bad args"
- staged validators from cheap to expensive
- retry only inside the internal autonomous harness, not on the public client-facing path

## What already exists in `masc-mcp`

- Internal OAS-backed keeper/runtime path already opts into structured validation retry. See `lib/keeper/keeper_agent_run.ml`.
- The repo already documents the public/internal boundary in `docs/design/tool-calling-quality-and-self-healing-rfc.md`.
- Tool argument validation already has machine-readable field-path errors in `lib/tool_args.ml`.

So the article is mostly confirmation, not a new direction.

## Immediate actions worth adopting

### 1. Keep public MCP one-shot

Do not leak hidden retry into public MCP calls. The article is pro-harness, not pro-silent-retry everywhere.

Applied interpretation for this repo:

- public MCP: deterministic, one-shot, explicit error
- internal OAS/keeper path: bounded retry with structured feedback

### 2. Make dashboard/tooling distinguish truth axes

If we compare inventory, visibility, direct-call policy, and runtime mode in one panel, the UI must say they are different axes. Otherwise operators read bad numbers and chase fake regressions.

### 3. Prefer exact field-path feedback over prose

When tool validation fails, the most reusable feedback shape is:

- path
- expected
- actual or failure reason
- retryable/non-retryable

This is more important than richer prose.

### 4. Benchmark weakest useful models first

For local harness QA, weaker local models are useful because they reveal:

- ambiguous schema slots
- over-broad tool contracts
- missing recovery hints
- places where "first try" and "converged" diverge too much

### 5. Report `first_try` and `final_converged` separately

The article's strongest operational point is that low first-pass quality can still be acceptable if the repair loop is bounded and deterministic. That should be visible in benchmark outputs rather than collapsed into one success number.

## Concrete `masc-mcp` follow-ups

1. Keep tool inventory/dashboard counts tied to reliable backend truth only.
2. Extend tool-calling benchmark reporting so `first_try` and `final` are always shown together.
3. Audit internal validator feedback for cases that still collapse to generic error text instead of field-path diagnostics.

## Related local docs

- `docs/design/tool-calling-quality-and-self-healing-rfc.md`
- `docs/research/tool-parameter-hallucination-harness.md`
