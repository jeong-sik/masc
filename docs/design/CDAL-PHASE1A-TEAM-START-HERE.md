# CDAL Phase-1A Team Start Here

**Audience**: An experienced implementation team joining with no prior CDAL context
**Status**: Starter guide for pre-production single-run implementation
**Date**: 2026-03-28

## 1. What You Are Building

You are **not** building full production CDAL.
You are building:

- a pre-production
- single-run
- deterministic
- scoped runtime audit

The immediate deliverables are:

- `Cdal_loader`
- `Cdal_judge`
- optional `Cdal_friction_projection` for `Single_run`

You are **not** responsible for:

- cross-run windows
- automatic policy update
- training or optimization based on friction
- replay of `allowed_mutations` or `review_requirement` in v1

## 2. Read These First

Read in this order:

1. [contract-driven-agent-loop-rfc.md](./contract-driven-agent-loop-rfc.md)
2. [cdal-contract-kernel-and-advisory-split.md](./cdal-contract-kernel-and-advisory-split.md)
3. [check-evaluation-spec.md](./check-evaluation-spec.md)
4. [proof-bundle-check-mapping.md](./proof-bundle-check-mapping.md)
5. [mode-violations-evidence-v1.schema.json](./mode-violations-evidence-v1.schema.json)
6. [error-handling-and-operations-spec.md](./error-handling-and-operations-spec.md)

Do not start from the old evaluator and "improve it".
Start from the active-check spec and implement only that.

## 3. Ground Truth in Code

Before writing code, confirm the producer side:

- `oas/lib/risk_contract.mli` — contract type definitions
- `oas/lib/cdal_proof.mli` — proof bundle type interface
- `oas/docs/schemas/cdal-proof-bundle-v1.json` — proof bundle JSON Schema
- `oas/lib/mode_enforcer.ml` — runtime enforcement logic (producer side)
- `oas/lib/proof_capture.ml` — proof artifact writer (producer side)
- `oas/lib/proof_store.mli` — proof store read interface
- `masc-mcp/lib/cdal_eval.ml` — current evaluator (anti-pattern reference, not implementation guide)

These files tell you what exists today.
The docs tell you what you are allowed to claim from those fields.

## 4. Active Checks Only

Phase-1A active checks are only:

- `runtime.requested_execution_mode`
- `runtime.risk_class`
- `proof.contract_snapshot`
- `proof.required_artifact`

Explicitly unsupported in v1:

- `runtime.allowed_mutations`
- `runtime.review_requirement`

If your implementation tries to judge these unsupported checks, you are reintroducing fake determinism.

## 5. Selected Blocking Artifacts

Phase-1A may block on only these artifacts:

- `manifest.json`
- `contract.json`

Do not make these blocking in phase-1A:

- `evidence/mode_violations.json`
- `evidence/token_usage.json`
- `evidence/review_warning.json`
- `tool_traces/*.jsonl`
- `checkpoint_ref`

Those may be used for friction or later phases, but they are not phase-1A blocking inputs by default.

## 6. Mode Rule

For `runtime.requested_execution_mode`, use this order:

- `diagnose < draft < execute`

The phase-1A rule is:

- `effective_execution_mode <= requested_execution_mode`

Any upward escalation is contradiction.

## 7. Friction v1 Rule

If you implement `Single_run` friction, use only fields that actually exist in v1:

- `tool_name`
- `effective_mode`
- `violation_kind`

Treat these as unavailable in v1:

- `effect_class`
- `required_min_mode`
- `violated_rule_id`
- `trace_id`
- `turn`

Unavailable means `None`, not inference.

## 8. Non-Negotiable Constraints

- no ref-name substring counting
- no heuristic trace joins
- no semantic reconstruction from `input_summary`
- no silent green treatment of unsupported checks
- no advice-derived verdicts
- no cross-run support hidden behind `Single_run` codepaths

## 9. Suggested Implementation Order

1. build ref resolution and manifest/contract loading behind a small reader adapter
2. implement per-check result evaluation for the 5 active checks
3. implement run-level verdict derivation
4. validate new evaluator against known bundles (replay determinism test)
5. optionally add `Single_run` friction projection
6. add tests that replay the same bundle deterministically

Legacy cleanup (after Phase-1A validation):

- delete substring/ref-count logic from `cdal_eval.ml` only after the new evaluator passes replay tests on real bundles

## 10. Minimum Review Checklist

Before asking for review, confirm:

- every active check has a direct row in `check-evaluation-spec.md`
- every field you consume appears in `proof-bundle-check-mapping.md`
- every unsupported field remains unsupported in code
- every blocking artifact is listed in the selected-artifact table
- every emitted verdict carries `claim_scope = phase1_scoped_runtime_audit`

## 11. What Success Looks Like

Success for this phase is not "production-ready CDAL".
Success is:

- no fake pass
- no heuristic replay
- explicit `Inconclusive`
- deterministic replay from the same bundle and contract
- a clean base for evidence v2 and cross-run work later
