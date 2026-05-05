# RFC-0034: Task Oscillation Mitigation (Cooldown + Severe-Level Human Escalation)

- **Status**: Draft
- **Author**: Claude (autonomous, audit-driven from issue #13302 P0-4)
- **Created**: 2026-05-06
- **Related**: #10421 (implicit auto-release observability), #13302 (umbrella tracking)

## Problem

Boot-time observation (2026-05-06, `~/me/.masc/playground` server, port 8935) shows
sustained claim/release loops on multiple tasks within ~90 seconds:

```
[WARN] [RoomTask] task_oscillation_major task=task-125 agent=keeper-executor-agent
       cycle_count=10 threshold=10 (sustained claim->release loop, candidate for triage)
```

`task-125` (Base Purge Phase 4) cycles between `executor` and `scholar` 10 times
within 5 minutes. `task-150`, `task-185`, `task-151` show the same pattern.

The detection is real (#10421 wired observability — JSONL event, WARN, Prometheus
counter). The action surface is not: `coord_task.ml:390` explicitly states
"Pure observation: does not block the release." Cycle thresholds at 5/10/20 fire
WARN once per crossing and let the loop continue.

### Why this happens (root cause)

`task_claim_next` semantics (introduced in #10421) implicitly auto-release any
prior claim:

```ocaml
(* coord_task_schedule.ml:380-422 *)
log_event ... ("type", `String "task_claim_next_auto_release") ...
Log.RoomTask.warn
  "task_claim_next auto-released prev claim: agent=%s task=%s ..."
let updated = List.map (fun (t : Masc_domain.task) ->
  if String.equal t.id prev.id then { t with task_status = Todo }
  else t
) backlog.tasks
```

A keeper that calls `task_claim_next` while still holding a task does not need to
explicitly release/finish it — the prior task is silently moved back to `Todo`.
This is by design (graceful re-entry from broken keeper turns), but it removes
the contract that would otherwise prevent abandoned-mid-work churn:

1. Keeper A calls `claim_next` → claims task-125.
2. Keeper A calls `claim_next` again before finishing → task-125 returns to `Todo`.
3. Keeper B calls `claim_next` → claims task-125.
4. Keeper B calls `claim_next` again → task-125 returns to `Todo`.
5. Loop continues until external intervention.

`cycle_count` increments on every `Release` action (which the implicit auto-release
also triggers via `task_claim_next_auto_release` → `Todo` transition), and the
oscillation_major/severe WARNs fire, but no transition gates the next claim.

## Goals

1. **Stop sustained churn** without breaking the implicit auto-release semantic
   that broken keeper turns rely on.
2. **Escalate to human** when automated mitigation has been exhausted.
3. **Preserve observability** wired in #10421 (counters, JSONL events).

## Non-Goals

- Removing the implicit auto-release semantic of `task_claim_next` (Option C in
  the audit comment) — too high a compatibility cost; requires touching every
  keeper code path that relies on graceful re-entry.
- Persisting cooldown state across server restarts (in-memory is enough for the
  common case; `cycle_count` itself is already on-disk and survives restarts).

## Design

### Two-stage mitigation

| Stage | Trigger | Action | Recovery |
|-------|---------|--------|----------|
| **Cooldown** | `cycle_count` reaches 10 (oscillation_major) | Set `task.cooldown_until = now() + COOLDOWN_SEC` (default 300s); claim attempts during cooldown are rejected with `TaskInCooldown` error | Auto-clear when `now() >= cooldown_until`; reset `cycle_count` to 0 on first claim after cooldown |
| **Human escalation** | `cycle_count` reaches 20 (oscillation_severe) | Transition task to `paused_human` status; emit `task_oscillation_human_escalation` JSONL event; broadcast to assignee + room | Manual: human reviews, resets, resumes via dashboard or `task_resume` action |

### Domain changes

Add fields to `Masc_domain.task`:

```ocaml
type task = {
  ...
  cooldown_until : float option;  (* unix timestamp; None when not in cooldown *)
  paused_for_human : bool;        (* true after oscillation_severe escalation *)
  paused_at : string option;      (* ISO8601 timestamp of paused_human transition *)
}
```

`task_status` already has a `Paused_human` variant per recent additions (verify
in `masc_domain.ml`); if not, add it.

### Claim path changes

In `coord_task_schedule.ml::task_claim_next` and `coord_task.ml::claim_action`,
gate the candidate filter:

```ocaml
let task_is_in_cooldown ~now (t : Masc_domain.task) =
  match t.cooldown_until with
  | Some until when until > now -> true
  | _ -> false

let task_is_human_paused (t : Masc_domain.task) = t.paused_for_human

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
  let with_cooldown =
    if cc >= 10 && Option.is_none task.cooldown_until then
      Some { task with
             cooldown_until = Some (now +. cooldown_sec ());
             (* Do NOT reset cycle_count yet — preserve audit trail until cooldown expires *)
           }
    else None
  in

  (* New: paused_human at oscillation_severe *)
  let with_paused =
    if cc >= 20 && not task.paused_for_human then
      Some { task with
             paused_for_human = true;
             paused_at = Some (Masc_domain.now_iso ());
             task_status = Paused_human;  (* if status variant exists *)
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
| Cooldown expires | Time-based | First `task_claim_next` after `now >= cooldown_until` clears `cooldown_until` and resets `cycle_count = 0`. Claim proceeds normally |
| Human resume | Manual | New action `task_resume_after_human_escalation { task_id }` clears `paused_for_human`, transitions back to `Todo`, resets `cycle_count`. Requires admin/dashboard auth |

## Compatibility

- Existing keepers continue to work — cooldown/paused_human only activate at high
  `cycle_count`, which by definition has not been reached for non-oscillating
  tasks.
- `task_claim_next` implicit auto-release semantic (`#10421`) is preserved.
- On-disk task JSON gains 3 optional fields, all `null` by default → backward-
  compatible with existing fixtures and tests.

## Test plan

| Test | Assertion |
|------|-----------|
| Cooldown gate | After 10 release cycles, next `claim_next` returns `TaskInCooldown` until `cooldown_until` expires |
| Cooldown expiry | After cooldown expires, claim succeeds and `cycle_count` reset to 0 |
| Severe escalation | After 20 cycles, `task.task_status = Paused_human`, JSONL `task_oscillation_human_escalation` emitted |
| Human-paused gate | `claim_next` skips paused_human tasks even when other tasks are blocked |
| `task_resume_after_human_escalation` | Restores task to claimable state, resets cycle_count |
| Implicit auto-release preserved | Single-keeper churn (re-entrant claim_next without release) still works for `cycle_count < 10` |

## Implementation phases

| Phase | Scope | Files |
|-------|-------|-------|
| **PR-1** | Domain fields + serialization | `lib/masc_domain.ml`, `lib/masc_domain.mli`, fixtures |
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
2. **Paused_human auto-resume**: Should `paused_for_human` auto-clear after a
   long timeout (e.g. 24h with no further oscillation activity)? Or strictly
   manual intervention?
3. **Cross-keeper attribution**: When task-125 oscillates between `executor` and
   `scholar`, which agent gets attributed in the Prometheus counter? Consider
   labeling by the keeper that triggered the threshold crossing.

## Decision log

- **2026-05-06**: RFC drafted from issue #13302 P0-4 audit, after caller-context
  inspection of `coord_task_schedule.ml:380-422` and `coord_task.ml:380-417`.
  Option C (claim_next strict mode) rejected for compatibility cost; A (cooldown)
  + B (human escalation) chosen as the staged escalation path.

## References

- `#10421` — implicit auto-release observability
- `lib/coord/coord_task_schedule.ml:380-422` — `task_claim_next_auto_release` emit
- `lib/coord/coord_task.ml:380-417` — oscillation threshold detection (5/10/20)
- `lib/coord/coord_hooks.ml:219` — `#10421` hook definition
- Issue #13302 P0-4 audit: https://github.com/jeong-sik/masc-mcp/issues/13302#issuecomment-4380878513
