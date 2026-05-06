# RFC-0034: Task Oscillation Mitigation (Cooldown + Severe-Level Human Escalation)

- **Status**: Draft
- **Author**: Claude (autonomous, audit-driven from issue #13302 P0-4)
- **Created**: 2026-05-06
- **Related**: #10421 (claim-next preservation observability), #13302 (umbrella tracking)

## Problem

Boot-time observation (2026-05-06, `~/me/.masc/playground` server, port 8935) shows
sustained claim/release loops on multiple tasks within ~90 seconds:

```
[WARN] [RoomTask] task_oscillation_major task=task-125 agent=keeper-executor-agent
       cycle_count=10 threshold=10 (sustained claim->release loop, candidate for triage)
```

`task-125` (Base Purge Phase 4) cycles between `executor` and `scholar` 10 times
within 5 minutes. `task-150`, `task-185`, `task-151` show the same pattern.

The detection is real, but the current implementation is narrower than the
initial audit assumed: `coord_task.ml` emits WARN lines at the 5/10/20 threshold
crossings, and its own comment keeps Prometheus/JSONL as follow-up work rather
than an existing surface. The action surface is still observation-only:
`coord_task.ml:390` explicitly states "Pure observation: does not block the
release." Cycle thresholds fire once per crossing and let the loop continue.

### Current semantics boundary

#10421 no longer makes `task_claim_next` auto-release active work. The current
implementation preserves an existing claim and surfaces
`task_claim_next_preserved`; `released_task_id` is a legacy field retained for
wire compatibility.

This RFC therefore does not verify or depend on an implicit auto-release path.
It proposes a new mitigation for any remaining oscillation path that still
increments `cycle_count` through explicit releases, handoffs, or future
transition sources. Before implementation, PR-2 must attach a concrete trace
showing continued oscillation after #10421's preservation semantics; otherwise
the RFC should be marked superseded by #10421.

## Goals

1. **Stop sustained release/reclaim churn** when current traces prove it still
   exists after #10421's claim-preservation behavior.
2. **Escalate to human** when automated mitigation has been exhausted.
3. **Extend observability without overstating current behavior**: preserve the
   existing WARN surface and add JSONL/Prometheus wiring in the implementation
   phase.

## Non-Goals

- Changing `task_claim_next` preservation semantics — active work should remain
  protected while this RFC targets only proven residual oscillation.
- Persisting cooldown state across server restarts. Cooldown is a runtime-only
  scheduler overlay; server restart clears cooldowns. Severe human escalation is
  the only persisted mitigation state, because it requires explicit operator
  review.

## Design

### Two-stage mitigation

| Stage | Trigger | Action | Recovery |
|-------|---------|--------|----------|
| **Cooldown** | `cycle_count` reaches 10 (oscillation_major) | Record `cooldown_until = now() + COOLDOWN_SEC` in a runtime-only scheduler overlay keyed by `task_id`; claim attempts during cooldown are rejected with `TaskInCooldown` error | Auto-clear when `now() >= cooldown_until`; reset `cycle_count` to 0 on first claim after cooldown |
| **Human escalation** | `cycle_count` reaches 20 (oscillation_severe) | Transition task to a new human-paused task status; emit `task_oscillation_human_escalation` JSONL event; broadcast to assignee + room | Manual: human reviews, resets, resumes via dashboard or `task_resume_after_human_escalation` action |

### Domain changes

Do not add `cooldown_until`, `paused_for_human`, or `paused_at` as serialized
task fields. Cooldown belongs to an in-memory scheduler overlay so restarts
clear it by construction. Human escalation uses one persisted source of truth:
the task status.

```ocaml
module Task_cooldowns : sig
  val set : task_id:string -> until:float -> unit
  val get : task_id:string -> float option
  val clear : task_id:string -> unit
end
```

Add a new task status variant as part of PR-1; it does not exist today:

```ocaml
type task_status =
  | ...
  | PausedHuman of {
      assignee: string option;
      paused_at: string;
      reason: string;
    }
```

The wire string should be `paused_human`. Required surface:

- `lib/types/types_core.ml`: add the variant and update
  `task_status_to_string`, `task_status_icon`, assignee extraction, terminal
  helpers, and schema enum witnesses.
- `lib/coord/coord_task_schedule.ml`: exclude human-paused tasks from claim
  candidates.
- `lib/coord/coord_task.ml`: add severe escalation and resume transition.
- Dashboard/cockpit task views: render the human-paused badge/state.
- Tests: cover serialization compatibility and state-machine transitions.

### Claim path changes

In `coord_task_schedule.ml::task_claim_next` and `coord_task.ml::claim_action`,
gate the candidate filter:

```ocaml
let task_is_in_cooldown ~now (t : Masc_domain.task) =
  match Task_cooldowns.get ~task_id:t.task_id with
  | Some until when until > now -> true
  | _ -> false

let task_is_human_paused (t : Masc_domain.task) =
  match t.task_status with PausedHuman _ -> true | _ -> false

(* In claim candidate filter *)
let claimable t =
  not (task_is_in_cooldown ~now t)
  && not (task_is_human_paused t)
  && task_is_primary_claim_pool_candidate t
```

### Release path additions

In `coord_task.ml`, after the existing oscillation WARN block (line 392-417):

```ocaml
| Masc_domain.Release ->
  let cc = task.cycle_count + 1 in
  let escalation = ... in
  (* existing escalation WARN *)

  (* New: cooldown stamp at oscillation_major *)
  if cc >= 10 && not (task_is_in_cooldown ~now task) then
    Task_cooldowns.set
      ~task_id:task.task_id
      ~until:(now +. cooldown_sec ());

  (* New: human-paused status at oscillation_severe *)
  let with_paused =
    if cc >= 20 && not (task_is_human_paused task) then
      Some { task with
             task_status = PausedHuman {
               assignee = task_assignee_of_status task.task_status;
               paused_at = Masc_domain.now_iso ();
               reason = "task_oscillation_severe";
             };
           }
    else None
  in
```

### Configuration

Three env knobs (default values are conservative; tunable via cascade or
operator config):

| Env var | Default | Purpose |
|---------|---------|---------|
| `MASC_TASK_OSCILLATION_COOLDOWN_SEC` | 300 | Cooldown duration after `oscillation_major` |
| `MASC_TASK_OSCILLATION_MAJOR_THRESHOLD` | 10 | Cycle count triggering cooldown (existing) |
| `MASC_TASK_OSCILLATION_SEVERE_THRESHOLD` | 20 | Cycle count triggering human escalation (existing) |

### Observability additions

| Surface | Wiring |
|---------|--------|
| WARN | Existing oscillation_major/severe WARN augmented with `action=cooldown_applied` / `action=paused_human` |
| JSONL event | `task_cooldown_applied { task_id, until }`, `task_oscillation_human_escalation { task_id, cycle_count }` |
| Prometheus counter | New: `masc_task_cooldown_applied_total{task,reason}`, `masc_task_human_escalation_total{task}` |
| Dashboard | Show cooldown countdown + paused_human badge in task list |

### Recovery actions

| Recovery | Trigger | Path |
|----------|---------|------|
| Cooldown expires | Time-based | First `task_claim_next` after `now >= cooldown_until` clears the runtime overlay entry and resets `cycle_count = 0`. Claim proceeds normally |
| Human resume | Manual | New action `task_resume_after_human_escalation { task_id }` transitions from `PausedHuman` back to `Todo` and resets `cycle_count`. Requires admin/dashboard auth |

## Compatibility

- Existing keepers continue to work — cooldown/paused_human only activate at high
  `cycle_count`, which by definition has not been reached for non-oscillating
  tasks.
- `task_claim_next` active-work preservation semantics (`#10421`) are preserved.
- Cooldown adds no on-disk task JSON fields. Restart clears runtime cooldowns,
  while `cycle_count` remains available for audit.
- Human escalation adds one new serialized task-status value, `paused_human`.
  PR-1 must update compatibility fixtures and unknown-status handling before any
  production transition can emit it.

## Test plan

| Test | Assertion |
|------|-----------|
| Cooldown gate | After 10 release cycles, next `claim_next` returns `TaskInCooldown` until `cooldown_until` expires |
| Cooldown expiry | After cooldown expires, claim succeeds and `cycle_count` reset to 0 |
| Severe escalation | After 20 cycles, `task.task_status = PausedHuman`, JSONL `task_oscillation_human_escalation` emitted |
| Human-paused gate | `claim_next` skips paused_human tasks even when other tasks are blocked |
| `task_resume_after_human_escalation` | Restores task to claimable state, resets cycle_count |
| Claim-next preservation preserved | Re-entrant `claim_next` while already holding work preserves the active task and does not create release churn |

## Implementation phases

| Phase | Scope | Files |
|-------|-------|-------|
| **PR-1** | Domain fields + new human-paused status serialization | `lib/types/types_core.ml`, task JSON fixtures |
| **PR-2** | Cooldown gate at oscillation_major | `lib/coord/coord_task.ml`, `lib/coord/coord_task_schedule.ml`, env_config |
| **PR-3** | Severe-level paused_human + resume action | `lib/coord/coord_task.ml`, MCP tool addition |
| **PR-4** | Dashboard surface | `dashboard/src/components/...` |
| **PR-5** | Prometheus counters + alert rules | `lib/prometheus.ml`, monitoring config |

PR-1 is prerequisite for PR-2/PR-3; PR-4/PR-5 can land in parallel after PR-3.

## Open questions

1. **Cooldown reset on first claim vs on cooldown expiry**: Does the cycle counter
   reset the moment cooldown expires (background sweep) or on the first successful
   claim afterward? The latter avoids a sweep loop but delays observability of
   "this task is healthy now".
2. **Human-paused auto-resume**: Should `PausedHuman` auto-clear after a long
   timeout (e.g. 24h with no further oscillation activity)? Or strictly manual
   intervention?
3. **Cross-keeper attribution**: When task-125 oscillates between `executor` and
   `scholar`, which agent gets attributed in the Prometheus counter? Consider
   labeling by the keeper that triggered the threshold crossing.

## Decision log

- **2026-05-06**: RFC drafted from issue #13302 P0-4 audit, after caller-context
  inspection of `coord_task_schedule.ml:380-422` and `coord_task.ml:380-417`.
  Follow-up review corrected the premise: `task_claim_next` now preserves active
  work after #10421, so implementation must first prove a residual oscillation
  path and then apply A (cooldown) + B (human escalation) only to that path.

## References

- `#10421` — `task_claim_next` active-work preservation observability
- `lib/coord/coord_task_schedule.ml:380-422` — `task_claim_next_preserved` handling
- `lib/coord/coord_task.ml:380-417` — oscillation threshold detection (5/10/20)
- `lib/coord/coord_hooks.ml:219` — `#10421` hook definition
- Issue #13302 P0-4 audit: https://github.com/jeong-sik/masc-mcp/issues/13302#issuecomment-4380878513
