---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/cdal/
  - lib/proof_artifact_reader.ml
  - lib/keeper/keeper_agent_run.ml
---

# Cross-Run Loader and Window Spec

**Status**: Draft (v2 — late-arrival, schema compat, API signatures added)
**Date**: 2026-03-30 (v2), 2026-03-28 (v1)
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

## 9. Late-Arrival Policy

A run may complete after the window query has already been issued. This happens when:

- a keeper or swarm agent is still writing its proof bundle while another agent queries cross-run data
- clock skew causes `ended_at` to appear out of order
- a run's manifest is written before all evidence artifacts are flushed

Rules:

- a window query is a snapshot: it captures runs visible at query time and does not retroactively include late arrivals
- `basis_hash` (section 6) makes the snapshot deterministic: the same selected run IDs produce the same hash regardless of what arrives later
- callers that need consistency across retries must compare `basis_hash` values; a hash change means the underlying run set changed
- late-arriving runs are picked up by the next window query, not patched into the previous result
- timestamp proximity (e.g., "runs within 5 seconds of now") must not be used as an ordering key. Use `ended_at` from the proof manifest, which is written atomically at the end of proof capture

This avoids the complexity of retroactive window mutation and keeps aggregation results reproducible.

## 10. Schema Version Compatibility

Runs may use different proof manifest schema versions. The loader must handle version heterogeneity:

| Scenario | Behavior |
| --- | --- |
| All runs same schema version | normal aggregation |
| Mixed versions, all loadable | normalize to latest schema, note version in metadata |
| Unknown schema version | treat as corruption, apply partial-failure policy (section 5) |
| Schema version too old to normalize | same as unknown |

Since the current schema remains at version 1 (with optional fields added via `[@yojson.default]`), normalization is handled by the existing `Cdal_proof.of_json` decoder. A separate `normalize_manifest` function is not needed at this time. If a future schema v2 introduces breaking field changes, an explicit normalizer should be added.

## 11. Proof_store Read-Side API (OAS, Implemented)

OAS now owns the `proof-store://` read side through `Agent_sdk.Proof_store`.
MASC must consume that public surface through `lib/proof_artifact_reader.ml`
instead of reconstructing proof-store paths.

Current public read surface in OAS `proof_store.mli`:

- `resolve_ref`
- `read_json`
- `read_jsonl`
- `load_manifest`
- `load_contract`
- `list_runs`
- `list_runs_ordered`
- `load_window`

The cross-run window APIs use the following public types:

```ocaml
(** Run metadata for ordering and filtering. *)
type run_info = {
  run_id: string;
  ended_at: float;         (** from Cdal_proof.t.ended_at *)
  schema_version: int;     (** proof manifest schema version *)
  scope: string option;    (** opaque scope label set by producer *)
}

type window_bounds = {
  max_runs: int;           (** hard limit on run count, default 50 *)
  max_bytes: int;          (** hard limit on total bytes scanned, default 50MB *)
}

(** List runs with metadata, ordered by [ended_at] ascending,
    tie-broken by [run_id].
    Corrupted manifests are excluded and reported in the errors list. *)
val list_runs_ordered :
  config ->
  ?scope:string ->
  ?bounds:window_bounds ->
  unit ->
  (run_info list * string list, string) result

(** Load manifests for a window of runs.
    Readable runs returned; unreadable runs reported as errors. *)
val load_window :
  config ->
  run_ids:string list ->
  ?bounds:window_bounds ->
  unit ->
  ((Cdal_proof.t * Yojson.Safe.t) list * string list, string) result
```

These signatures keep the existing `list_runs` backward compatible and add
structured alternatives for deterministic window queries. Implementation and
layout validation stay in OAS `proof_store.ml`; MASC adapters only delegate.

## 12. Regression Checklist

Future cross-run reader changes must preserve:

- `list_runs_ordered` is implemented with stable ordering
- scope and ordering rules are explicit
- late-arrival policy is enforced (snapshot semantics, no retroactive mutation)
- retention is documented and enforced
- schema version normalization handles all known versions
- aggregation errors have a documented policy
- basis-hash composition is frozen
- resource bounds are configured and enforced
