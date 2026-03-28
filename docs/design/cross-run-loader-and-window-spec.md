# Cross-Run Loader and Window Spec

**Status**: Draft, post-pre-production scope
**Date**: 2026-03-28
**Scope**: Cross-run `friction_projection` enumeration, window semantics, and loader requirements
**One sentence**: Define the infrastructure and selection rules required before `Last_n_runs`, `Session`, or `Rolling_seconds` become valid CDAL surfaces.

## Related Documents

- `./contract-driven-agent-loop-rfc.md`
- `./cdal-contract-kernel-and-advisory-split.md`
- `./proof-bundle-check-mapping.md`
- `./error-handling-and-operations-spec.md`

## 1. Current Shipping Boundary

Pre-production Phase-1 supports:

- `Single_run`

It does not support:

- `Last_n_runs`
- `Session`
- `Rolling_seconds`

Reason:

- no public read-side run enumeration API
- no stable cross-run ordering rule
- no retention guarantee by window type
- no aggregation error policy

## 2. Required Read-Side APIs

Cross-run windows require at least:

- `Proof_store.resolve_ref`
- `Proof_store.read_json`
- `Proof_store.read_jsonl`
- `Proof_store.load_contract`
- `Proof_store.load_manifest`
- `Proof_store.list_runs`

`list_runs` must define:

- stable ordering key
- filtering scope
- corruption handling
- compatibility behavior across schema versions

## 3. Window Semantics

| window | selection rule | required infra | allowed in pre-production |
|---|---|---|---|
| `Single_run(run_id)` | exactly one run by ID | manifest + artifact reader | yes |
| `Last_n_runs(n)` | latest `n` runs within a declared scope and ordering | run index + stable ordering + retention | no |
| `Session(session_id)` | all runs bound to one declared session identifier | session/run link + run index | no |
| `Rolling_seconds(s)` | all runs whose selected timestamp falls within the last `s` seconds in a declared scope | run index + clock basis + retention + late-arrival policy | no |

## 4. Scope and Ordering Rules

Cross-run aggregation must declare both:

- scope
  - for example keeper, task, room, benchmark cohort, or explicit run set
- ordering basis
  - for example `ended_at`, evaluator completion time, or manifest creation time

These must not be implicit.

Recommended initial ordering:

- `ended_at` ascending for replay order
- tie-break by `run_id`

## 5. Missing-Run and Partial-Failure Policy

Cross-run aggregation must specify what happens when:

- a listed run is missing
- a manifest exists but some refs are unreadable
- some runs are schema v1 and some are schema v2
- a window would exceed configured resource limits

Recommended default:

- missing or unreadable runs become aggregation-level completeness gaps
- aggregation may still emit partial observability artifacts only if declared policy allows it
- gate-authoritative verdicts must not be synthesized from partial cross-run windows

## 6. Basis Hash Composition

Cross-run `friction_projection.basis_hash` should include:

- declared window
- scope selector
- ordering basis
- selected run IDs in order
- projection semantics version
- tripwire policy ID

This prevents the same summary label from hiding different underlying run sets.

## 7. Retention Dependency

No cross-run window may be enabled unless artifact retention is at least as long as the maximum enabled window.

Examples:

- `Last_n_runs(5)` requires at least the last 5 runs in the selected scope
- `Rolling_seconds(2592000)` requires at least 30-day manifest and evidence retention

## 8. Resource Bounds

Cross-run aggregation must define:

- max runs per aggregation
- max artifacts dereferenced per aggregation
- max bytes scanned
- timeout behavior

If a bound is exceeded:

- emit an explicit aggregation error
- do not silently shrink the window

## 9. Exit Criteria

Cross-run windows may ship when:

- run enumeration is implemented
- scope and ordering rules are explicit
- retention is documented
- aggregation errors have a documented policy
- basis-hash composition is frozen
