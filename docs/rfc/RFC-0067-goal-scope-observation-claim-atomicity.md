# RFC-0067: Goal-Scope Observation→Claim Atomicity

**Issue**: #13738
**Status**: Draft
**Author**: Claude (agent)
**Date**: 2026-05-09 (renumbered 2026-05-11 from RFC-0057 — number collided with RFC-0057-tool-descriptor-codegen.md, which was authored ~30 minutes earlier the same day and now has implementation PRs #14396/#14400/#14405/#14412/#14416/#14417/#14421 merged on main. The codegen RFC keeps the 0057 slot per established-precedent convention.)

## 1. Problem

Keeper observation captures `meta.active_goal_ids` at T1, but `keeper_task_claim` re-reads `meta.active_goal_ids` at T2. Between T1 and T2 (LLM inference latency, typically 2–30 seconds), another agent or keeper can modify the goal store — adding, completing, or removing goals. The claim operates on a potentially stale scope.

**Observed failure mode**: Keeper observes goal G1 → LLM decides to claim a task linked to G1 → Between observation and claim, G1 is marked completed by another agent → Claim still succeeds (goal still in `meta.active_goal_ids` in-memory) but the task is now irrelevant.

**Current mitigation**: PR #13673 added `resolve_observation_claim_goal_scope` with `allow_empty_goal_scope_fallback` for auto-keeper goals. This is a fallback, not atomicity — it widens scope instead of detecting staleness.

## 2. Non-Goals

- Distributed transaction across keeper turns (single-process in-memory state is sufficient)
- Retry-loop for stale observations (keeper simply re-observes on next turn)
- Changing the goal store to event-sourced (version counter is sufficient)

## 3. Design

### 3.1 Scope-Version Token in Observation

Add `goal_store_version : int` to `world_observation` record:

```ocaml
(* keeper_world_observation.ml *)
type world_observation = {
  (* ... existing fields ... *)
  active_goals : string list;
  goal_store_version : int;  (* NEW: snapshot of Goal_store.state.version *)
  (* ... *)
}
```

At observation construction (`keeper_world_observation.ml:983`):

```ocaml
let goal_state = Goal_store.read_state config in
{ (* ... *)
  active_goals = meta.active_goal_ids;
  goal_store_version = goal_state.version;
}
```

### 3.2 Claim-Side Version Check

`keeper_task_claim` receives the observation's `goal_store_version` and compares before claiming:

```ocaml
(* keeper_exec_task.ml, "keeper_task_claim" branch *)
| "keeper_task_claim" ->
  let observation_version = (* extracted from last observation *) in
  let current_version = (Goal_store.read_state config).version in
  if observation_version <> current_version then begin
    (* Goal store mutated since observation *)
    error_json (Printf.sprintf
      "Goal scope stale: observed at version %d, current is %d. \
       Re-observe before claiming."
      observation_version current_version)
  end else
    (* proceed with existing claim logic *)
```

### 3.3 Observation Version Storage

The observation is created in `keeper_unified_turn.ml` and passed to the LLM. The LLM's `keeper_task_claim` tool call needs access to the version from the current turn's observation.

Option: Store in `keeper_meta.runtime` as `last_observation_goal_version : int option`.

```ocaml
(* keeper_types_profile.ml, in runtime sub-record *)
last_observation_goal_version : int option;  (* NEW *)
```

Updated at observation construction time, read at claim time.

### 3.4 Rejection → Re-Observe Flow

When claim rejects with "goal scope stale", the LLM receives the error in its tool result. On next turn, the keeper re-observes with fresh version.

No automatic retry within the same LLM turn — the error message is actionable ("Re-observe before claiming").

## 4. Impact Analysis

### Files Changed (estimated)

| File | Change | LOC |
|------|--------|-----|
| `lib/keeper/keeper_world_observation.ml` | Add `goal_store_version` field + populate | +5 |
| `lib/keeper/keeper_world_observation.mli` | Expose new field | +3 |
| `lib/keeper/keeper_types_profile.ml` | Add `last_observation_goal_version` to runtime | +2 |
| `lib/keeper/keeper_exec_task.ml` | Version check in claim branch | +10 |
| `lib/keeper/keeper_unified_turn.ml` | Store version after observation | +3 |
| `test/test_keeper_*.ml` | Test stale version rejection | +30 |

**Total**: ~53 LOC across 6 files

### Dependency Risk

- `Goal_store.read_state` already used in keeper modules (`keeper_runtime_contract.ml`, `keeper_turn_up_create.ml`, etc.)
- No new external dependencies
- Version check is O(1) — `read_state` is already cached behind Coord config

### Backward Compatibility

- `goal_store_version` defaults to `0` for existing observations (no migration needed)
- `0 <> current_version` always true for non-empty goal stores → stale detection works on first upgrade
- Existing keepers without the field simply skip the check (option type)

## 5. Alternatives Considered

### A. Compare-and-Swap on Goal IDs (Rejected)

Compare the full `active_goal_ids` list rather than a version counter.
- **Pro**: Detects semantic change, not just any write
- **Con**: O(n) comparison, fragile with ordering, doesn't catch goal property changes (status, phase)

### B. Optimistic Lock on Goal Store (Rejected)

Lock the goal store during observation→claim window.
- **Pro**: True atomicity
- **Con**: Lock contention across all keepers, defeats cooperative scheduling, unnecessary for this granularity

### C. Observation ID + Server-Side Validation (Future)

Assign a UUID to each observation and validate server-side. More general but over-engineered for the current problem.

## 6. Test Plan

1. **Unit test**: Create observation with version V, mutate goal store (version V+1), assert claim rejection
2. **Integration test**: Two keepers, one observes then other modifies goals, first keeper's claim fails with stale message
3. **Regression test**: Existing claim tests pass unchanged (version check bypassed when `goal_store_version = 0`)

## 7. Open Questions

1. Should `read_state` be cached per-turn to avoid double-read? Current `read_state` is a file read — cheap but not free.
2. Should the version check be advisory (warn + proceed) or hard (reject)? Proposing hard reject for correctness.
3. Should we add a `goal_store_version` metric to Prometheus for observability? Optional, can be deferred.
