---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/cdal/
  - lib/keeper/keeper_accountability.ml
  - lib/eval_gate.ml
---

# CDAL Check Evaluation Spec

**Status**: Draft, pre-production scope
**Date**: 2026-03-28
**Scope**: Phase-1A single-run deterministic audit
**One sentence**: Define exactly which checks are decidable from proof bundle v1 plus evidence v1, and how each check yields `Satisfied`, `Violated`, or `Inconclusive`.

## Related Documents

- `./contract-driven-agent-loop-rfc.md`
- `./cdal-contract-kernel-and-advisory-split.md`
- `./proof-bundle-check-mapping.md`
- `./mode-violations-evidence-v1.schema.json`
- `./CDAL-PHASE1A-TEAM-START-HERE.md`
- `../../../oas/docs/schemas/cdal-proof-bundle-v1.json`

## 1. Purpose

This document closes the gap between:

- the abstract `check_id` registry
- the actual proof bundle v1 fields
- the actual OAS evidence emitted today

Without this document, a deterministic kernel can silently overclaim support for checks that current artifacts cannot justify.

## 2. Phase-1A Scope

Phase-1A is intentionally narrow.
It is not a full contract-satisfaction engine.

Supported in Phase-1A:

- single-run deterministic replay
- contract snapshot integrity checks
- manifest propagation / integrity checks
- artifact availability / parseability checks

Not supported in Phase-1A:

- general replay of `allowed_mutations`
- general replay of `review_requirement`
- cross-run windows
- semantic reconstruction from truncated summaries

## 3. Output Model

Each check yields one of:

- `Satisfied`
  - the proposition was decidable from supported evidence and held
- `Violated`
  - supported evidence was sufficient and contradicted the proposition
- `Inconclusive`
  - required supported evidence was missing, unreadable, unparsable, or semantically insufficient

Check-level results feed the run-level rule:

- any active-check `Violated` may produce run-level `Violated`
- otherwise any blocking `Inconclusive` may produce run-level `Inconclusive`
- otherwise run-level `Satisfied`

Run-level metadata:

- `claim_scope = phase1_scoped_runtime_audit`
- this marker must be present on the emitted `contract_verdict`
- downstream systems must not erase or relabel this scope marker as generic `pass` / `safe`

## 4. Active Checks in v1

| check_id | proposition | required contract fields | required proof fields | required evidence artifacts | evaluation rule | v1 status | verdict impact |
|---|---|---|---|---|---|---|---|
| `runtime.requested_execution_mode` | proof faithfully carries the requested mode from the contract, and proof does not show an upward escalation beyond the requested mode | `runtime_constraints.requested_execution_mode` | `contract_id`, `requested_execution_mode`, `effective_execution_mode`, `mode_decision_source` | `contract.json` | load contract snapshot by run convention; require `contract_id` hash match; require `contract.requested_execution_mode = proof.requested_execution_mode`; require `effective_execution_mode <= requested_execution_mode` | Active in v1 | `Violated` on contradiction, `Inconclusive` on missing basis |
| `runtime.risk_class` | proof faithfully carries the risk class from the contract | `runtime_constraints.risk_class` | `contract_id`, `risk_class` | `contract.json` | load contract snapshot by run convention; require `contract_id` hash match; require `contract.risk_class = proof.risk_class` | Active in v1 | `Violated` on contradiction, `Inconclusive` on missing basis |
| `proof.contract_snapshot` | the contract snapshot used for replay is the exact immutable input contract referenced by `contract_id` | full contract snapshot | `contract_id` | `contract.json` | load contract snapshot by run convention; recompute content-addressed `contract_id`; require equality with manifest `contract_id` | Active in v1 | `Violated` on hash mismatch, `Inconclusive` on load/parse failure |
| `proof.required_artifact` | artifacts required by active checks are present and parseable | none directly | `tool_trace_refs`, `raw_evidence_refs`, `checkpoint_ref` | referenced artifacts selected by the active checks | for every artifact selected by phase-1A rules, resolve ref, read file, parse payload; no heuristic fallback | Active in v1 | `Inconclusive` if blocking artifact missing or unreadable |
| `runtime.review_requirement` | proof bundle v1 does not carry a typed review verdict, so any declared review requirement must route through the verification FSM instead of being silently treated as satisfied | `runtime_constraints.review_requirement` | `raw_evidence_refs` | `evidence/review_warning.json` | if no review requirement is declared, satisfy immediately; if one is declared, emit `Inconclusive` with a blocking gap so downstream uses explicit verification / approval | Active in v1 | `Inconclusive` on any declared review requirement until explicit verification occurs downstream |

### 4.1 Mode Order Rule

For phase-1A, the order relation used by `runtime.requested_execution_mode` is:

- `diagnose < draft < execute`

So:

- `effective_execution_mode <= requested_execution_mode` is required
- equality is allowed
- any upward escalation is a contradiction

## 4.2 Selected Artifacts for `proof.required_artifact`

The `proof.required_artifact` check is not "all refs must always parse".
It is limited to the artifacts selected by the active phase-1A checks.

| artifact | selected in Phase-1A | blocking? | why |
|---|---|---|---|
| `manifest.json` | yes | yes | base proof input |
| `contract.json` | yes | yes | required for contract snapshot integrity and propagation checks |
| `evidence/mode_violations.json` | no in Phase-1A judge | no | not required by active phase-1A checks; used in Phase-1B friction |
| `evidence/token_usage.json` | no | no | advisory / annotation only |
| `evidence/review_warning.json` | conditional | yes when `runtime.review_requirement` is declared | warning-only bridge artifact that routes the run into the verification FSM |
| `tool_traces/*.jsonl` | no by default | no | only selected when a later active check explicitly consumes them |
| `checkpoint_ref` target | no by default | no | only selected when a later active check explicitly consumes it |

Rule:

- active phase-1A checks may block only on artifacts explicitly listed as selected and blocking
- adding a new blocking selected artifact requires updating this table and the mapping table

## 5. Unsupported Checks in v1

| check_id | why unsupported in v1 | what is missing | required next step |
|---|---|---|---|
| `runtime.allowed_mutations` | OAS enforces it at run time, but proof bundle v1 and evidence v1 do not preserve enough typed post-run evidence to replay it generally | no top-level proof field; no stable typed evidence for mutation class decision; current violation rows do not expose `effect_class` or `decision` | evidence v2 plus mapping update |

Rule:

- unsupported checks must not be silently treated as satisfied
- unsupported checks must not participate in deterministic pass conditions
- unsupported checks may appear in documentation as contract surface, but not as active phase-1A checks

Note:

- `runtime.review_requirement` is now a bridge check, not a full satisfaction check
- phase-1A can route declared review requirements into `Inconclusive + blocking gap`
- phase-1A still cannot prove that review was satisfied from proof bundle v1 alone

## 6. Blocking vs Annotation Inputs

| input | role in Phase-1A | if missing |
|---|---|---|
| `manifest.json` / proof bundle | blocking | `Inconclusive` |
| `contract.json` snapshot | blocking for active contract checks | `Inconclusive` |
| refs consumed by active checks | blocking | `Inconclusive` |
| opaque `eval_criteria` semantics | annotation only | record `not_evaluated`; do not block by itself |
| unused traces or evidence not consumed by active checks | non-blocking | no effect on verdict |

## 7. Prohibited Shortcuts

- no ref-name substring counting
- no timestamp-nearest trace joins
- no semantic reconstruction from `input_summary`
- no treating unsupported checks as green by omission
- no using `advice` to close a deterministic check

## 8. Implementation Notes

Phase-1A implementation should produce:

- per-check result rows
- run-level `contract_verdict`
- `completeness_gaps`
- explicit `unsupported_in_v1` metadata for excluded contract checks

Recommended order:

1. load and validate manifest
2. load and validate contract snapshot
3. evaluate active checks only
4. evaluate blocking artifact availability for those checks
5. derive run-level verdict

## 9. Exit Criteria

This document is ready for code generation when:

- every active check has a concrete evaluation rule
- every unsupported check has an explicit reason
- no active check depends on fields absent from proof bundle v1 plus evidence v1
- the run-level derivation rule is consistent with the split design document
