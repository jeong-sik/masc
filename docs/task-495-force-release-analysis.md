# Task-495: Force-release stuck tasks — Code Analysis

## Summary

Investigation of the force-release mechanism for stuck tasks consuming capacity slots.

## Key Findings

### 1. `force_release_task_r` exists at `lib/coord/coord_task.ml:834`

Uses `~force:true` flag on `transition_task_r` to bypass assignee check. Any keeper can
force-release any task regardless of who claimed it.

```ocaml
let force_release_task_r config ~agent_name ~task_id ?handoff_context () =
  transition_task_r config ~agent_name ~task_id
    ~action:Masc_domain.Release ?handoff_context ~force:true ()
```

### 2. Stuck Detection Mechanisms

Three layers of detection:

1. **`keeper_stale_watchdog.ml`** — 4-mode stall detection:
   - `Idle_turn`: last_turn_ts older than threshold, keeper Running but no turn observation
   - `In_turn_hung`: turn started and exceeded timeout_threshold
   - `Mid_turn_no_progress`: turn within outer cap but streaming/tool progress silent
   - `Noop_failure_loop`: consecutive_noop_count reached watchdog threshold

2. **`keeper_turn_slot.ml`** — Semaphore-based capacity management with Hashtbl holder tracking

3. **`keeper_supervisor_alive_but_stuck.ml`** — Detects keepers that are alive but stuck

### 3. Gap: No Automatic Claim-Release on Keeper Restart

The watchdog detects stalls and triggers supervisor restart, but the **claim itself is not
automatically released**. A restarted keeper may retain claims from before the restart,
leaving tasks in a claimed/in_progress state with no active worker.

### 4. Related: `force_done_task_r` and `force_cancel_task_r`

- `force_done_task_r` (line ~847): Force-complete regardless of assignee
- `force_cancel_task_r` (line ~855): Used by `Verification_protocol.check_timeouts` to expire
  awaiting_verification tasks past their verifier deadline

## Recommendation

Add an automatic stale-claim sweep that:
1. Checks `last_turn_ts` for claimed/in_progress tasks
2. If the claiming keeper's heartbeat is stale beyond a threshold, calls `force_release_task_r`
3. Emits a board post documenting the auto-release

## Board Evidence

- Board post: `p-c8a9d4ead7649b752af7fca09c293602` (ops channel)