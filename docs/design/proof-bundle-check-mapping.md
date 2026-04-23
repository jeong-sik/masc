# Proof Bundle to Check Mapping

**Status**: Draft, pre-production scope
**Date**: 2026-03-28
**Scope**: Cross-reference between contract surface, proof bundle v1, evidence v1, and phase-1A checks
**One sentence**: Make schema coverage explicit so no check claims support that current proof artifacts do not actually provide.

## Related Documents

- `./contract-driven-agent-loop-rfc.md`
- `./cdal-contract-kernel-and-advisory-split.md`
- `./check-evaluation-spec.md`
- `./mode-violations-evidence-v1.schema.json`
- `./CDAL-PHASE1A-TEAM-START-HERE.md`
- `../../../oas/docs/schemas/cdal-proof-bundle-v1.json`
- `../../../oas/lib/risk_contract.mli`

## 1. Problem

The contract surface and proof bundle surface are not identical.
Without an explicit mapping table, it is easy to write check logic for fields that the proof does not actually preserve.

## 2. Contract Surface to Check Mapping

| contract surface | check_id | proof bundle v1 support | evidence v1 support | phase-1A status | note |
|---|---|---|---|---|---|
| `runtime_constraints.requested_execution_mode` | `runtime.requested_execution_mode` | direct top-level field | not needed beyond contract snapshot | Active | propagation / integrity only |
| `runtime_constraints.risk_class` | `runtime.risk_class` | direct top-level field | not needed beyond contract snapshot | Active | propagation / integrity only |
| `runtime_constraints.allowed_mutations` | `runtime.allowed_mutations` | no top-level field | insufficient typed replay evidence | Unsupported_in_v1 | enforced at run time, not replayable generally |
| `runtime_constraints.review_requirement` | `runtime.review_requirement` | no top-level field | warning-only bridge evidence via `raw_evidence_refs` | Active | routes to `Inconclusive + blocking gap`; explicit review satisfaction is still not replayable |
| full input contract snapshot | `proof.contract_snapshot` | `contract_id` only | `contract.json` by run convention | Active | integrity only |
| required refs for active checks | `proof.required_artifact` | refs exist in manifest | referenced artifacts | Active | availability / parseability only |

## 3. Proof Bundle v1 Field Consumers

| proof field | consumed by which checks | role | phase-1A meaning |
|---|---|---|---|
| `schema_version` | all | compatibility gate | unsupported version -> `Inconclusive` |
| `run_id` | loader only | addressing / identity | selects contract and artifact namespace |
| `contract_id` | `proof.contract_snapshot`, `runtime.requested_execution_mode`, `runtime.risk_class` | snapshot integrity anchor | binds proof to exact contract |
| `requested_execution_mode` | `runtime.requested_execution_mode` | propagation check | must match contract snapshot |
| `effective_execution_mode` | `runtime.requested_execution_mode` | no-upward-escalation check | must not exceed requested |
| `mode_decision_source` | `runtime.requested_execution_mode` | explanatory field | supports traceability, not by itself a verdict |
| `risk_class` | `runtime.risk_class` | propagation check | must match contract snapshot |
| `provider_snapshot` | none in phase-1A | informational | reserved for later drift analysis |
| `capability_snapshot` | none in phase-1A | informational | reserved for later drift / mode analysis |
| `tool_trace_refs` | `proof.required_artifact` | artifact availability | blocking only if selected by active checks |
| `raw_evidence_refs` | `proof.required_artifact` | artifact availability | blocking only if selected by active checks |
| `checkpoint_ref` | `proof.required_artifact` | artifact availability | blocking only if selected by active checks |
| `result_status` | run-level context | execution outcome | not itself contract truth |
| `started_at` | none in phase-1A | informational | reserved for ordering / ops |
| `ended_at` | none in phase-1A | informational | reserved for ordering / ops |

## 4. Evidence Artifact Coverage

| artifact | current producer | fields available now | consumed in phase-1A? | can support friction v1? | can support friction v2? |
|---|---|---|---|---|---|
| `contract.json` | OAS | full `runtime_constraints` + opaque `eval_criteria` | yes | no | no |
| `evidence/mode_violations.json` | OAS | `ts`, `tool_name`, `input_summary`, `effective_mode`, `violation_kind` | no for active checks | yes | insufficient |
| `evidence/effects.json` | OAS | pre-tool effect decision rows, including allowed / denied / pending evidence | no | advisory only | potential typed effect ledger input |
| `evidence/token_usage.json` | OAS | turn token snapshots | no | optional annotation | no |
| `evidence/review_warning.json` | OAS | warning string + effective mode | yes for bridge routing | yes as review tripwire source | still insufficient for full typed review satisfaction |
| `tool_traces/*.jsonl` | OAS | tool trace rows | only as selected artifact presence | optional | partial, still missing typed join fields |

## 4.1 Phase-1A Selected Artifact List

| selected artifact | source path pattern | blocks phase-1A verdict? | used by |
|---|---|---|---|
| manifest | `{run}/manifest.json` | yes | all phase-1A checks |
| contract snapshot | `{run}/contract.json` | yes | `runtime.requested_execution_mode`, `runtime.risk_class`, `proof.contract_snapshot` |
| mode violations | `{run}/evidence/mode_violations.json` | no | phase-1B friction only |
| effect evidence | `{run}/evidence/effects.json` | no | advisory effect decision ledger only |
| token usage | `{run}/evidence/token_usage.json` | no | advisory only |
| review warning | `{run}/evidence/review_warning.json` | conditionally yes | active only when `runtime.review_requirement` is declared |
| tool traces | `{run}/tool_traces/*.jsonl` | no by default | reserved for future active checks |
| checkpoint | ref target of `checkpoint_ref` | no by default | reserved for future active checks |

This table is authoritative for phase-1A blocking behavior.
If a new check wants to block on another artifact, this table and `check-evaluation-spec.md` must be updated together.

## 5. Friction v1 vs v2 Mapping

| friction field | v1 source | v1 support | v2 target source |
|---|---|---|---|
| `tool_name` | `mode_violations.tool_name` | yes | evidence v2 blocked-attempt row |
| `effective_mode` | `mode_violations.effective_mode` | yes | evidence v2 blocked-attempt row |
| `violation_kind` | `mode_violations.violation_kind` | yes | evidence v2 blocked-attempt row |
| `effect_class` | none | no | evidence v2 |
| `required_min_mode` | none | no | evidence v2 |
| `violated_rule_id` | none | no | evidence v2 |
| `trace_id` | none | no | evidence v2 |
| `turn` | none | no | evidence v2 |

Rule:

- phase-1B `Single_run` friction may group only by fields actually present in v1
- richer friction keys remain `None` or unsupported until evidence v2 exists

## 6. Gaps Revealed by This Mapping

- the contract surface is broader than the replayable phase-1A surface
- proof bundle v1 is sufficient for integrity and availability checks, not for full runtime constraint replay
- OAS evidence v1 is enough for basic friction v1, not enough for rich blocked-attempt semantics
- cross-run friction needs separate infrastructure beyond this mapping table

## 7. Exit Criteria

This mapping is considered closed for pre-production when:

- every phase-1A active check maps only to fields that actually exist today
- every unsupported contract field is explicitly marked unsupported rather than silently ignored
- every friction v1 field can be traced to an existing emitted artifact
- every friction v2 field is explicitly marked future work
