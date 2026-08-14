---
rfc: "0373"
title: Keeper turn-lane admission
status: Draft
created: 2026-08-12
---

# RFC-0373: Keeper turn-lane admission

## Problem

A Keeper's autonomous work stops for as long as a chat operation runs, and
nothing in the system bounds that wait or records that it was owed a turn.

Observed on the live fleet, 2026-08-12, rondo:

```
13:40:42  keepalive turn scheduled: channel=scheduled_autonomous
                                    reasons=scheduled_autonomous_turn,task_backlog
13:44:37  yielded autonomous Owner child to a queued operation after 4538 turn(s),
          checkpoint saved — will resume next cycle
13:45:38  Keeper Owner deferred autonomous work: reason=turn_busy
                                    holder_lane=chat_operation
                                    holder_started_at=1786542277.7464499
13:50:47  … same holder
13:55:50  … same holder
13:59:44  [fsm:transition] streaming -> failed:provider_error
```

One chat operation held the turn slot from 13:44:37 to 13:59:44 and ended in a
provider error. The autonomous lane's own log line promises "will resume next
cycle"; three consecutive cycles could not keep that promise.

## Current structure

`Keeper_owner` holds exactly one turn slot:

```ocaml
(* lib/keeper/keeper_owner.ml *)
type turn_lane =
  | Autonomous
  | Chat_operation
  | Maintenance

type turn_in_flight =
  { lane : turn_lane
  ; started_at : float
  }
```

The two lanes acquire it by opposite mechanisms.

| | `Chat_operation` | `Autonomous` / `Maintenance` |
|---|---|---|
| mechanism | push | pull |
| who acts | the owner itself, in `start_child_if_needed` | an external caller polling `run_autonomous_if_idle` |
| when | after 7 distinct owner state transitions | once per keepalive cycle (~5 min observed) |
| on contention | n/a — it only runs when the slot is free | returns `Busy`, caller abandons the cycle |
| exported in `.mli` | **no entry point exists** | `run_autonomous_if_idle`, `run_maintenance_if_idle` |

`start_child_if_needed` is re-entered from `Apply_meta`, `Submit_operation`,
`Wake_operation_drain`, `Rollback_shutdown`, `Restore_shutdown`,
`Child_finished`, and owner start. The decisive one is `Child_finished`: the
moment *any* turn ends, the owner synchronously offers the freed slot to a
queued chat operation. The autonomous lane is not on that path — it discovers
the slot freed only on its next poll.

On loss, `Defer_autonomous_work` records a skip reason and logs. There is no
queue, no retry, no aging, and no preemption:

```ocaml
(* lib/keeper/keeper_heartbeat_loop.ml *)
| Defer_autonomous_work block ->
   Keeper_registry.record_skip_reasons … ~reasons:[ "keeper_owner_" ^ … ];
   Log.Keeper.info … "Keeper Owner deferred autonomous work: %s; this keepalive
     cycle records no turn status, crash, or work-health refresh"
```

`turn_admission_open` gates only on `paused`. There is no structure in which
the autonomous lane can express "give me the slot when it frees".

So the slot is a try-lock that one of its three users re-arms continuously and
the others sample every five minutes. That asymmetry, not the exclusion itself,
is what produces starvation.

## What is not established

The exclusivity has no stated rationale. `keeper_owner.mli` documents the
mailbox contract and the behaviour of `run_autonomous_if_idle`, but
`turn_lane` carries no doc comment and no cross-lane ordering or fairness
guarantee is written anywhere. The plausible invariant — one agent-core
conversation per Keeper, so two concurrent turns would interleave one
transcript — is inference from the code, not a documented contract.

**Any admission policy has to start by writing that invariant down.** Choosing
a policy before knowing what the exclusion protects would be guessing.

## Measurements

Whole-day log, 2026-08-12, 7 keepers (`<base-path>/.masc/logs/system_log_2026-08-12.jsonl`):

| | |
|---|---|
| autonomous deferrals | 50 |
| holder lane was `chat_operation` | **50 / 50** |
| holder lane was `maintenance` | 0 |
| distinct blocking operations | 37 |
| …that blocked more than one cycle | 8 |
| longest single hold (lower bound) | **16.3 min**, costing 5 consecutive cycles |

Per keeper, autonomous cycles scheduled vs. lost:

| keeper | scheduled | deferred | loss |
|---|---:|---:|---:|
| sangsu | 136 | 31 | **18.6%** |
| rondo | 120 | 8 | 6.2% |
| analyst | 112 | 4 | 3.4% |
| kidsnote | 131 | 3 | 2.2% |
| code-reviewer | 104 | 2 | 1.9% |
| taskmaster | 119 | 1 | 0.8% |
| lane-smith | 123 | 1 | 0.8% |

Fleet-wide loss is 5.6%, but it concentrates on the keeper carrying the most
chat traffic: sangsu loses close to a fifth of its autonomous cycles. The
distribution is the argument — the more a Keeper is talked to, the less
autonomous work it does, which inverts the intent of both lanes.

## Rejected direction

Bounding the chat lane's hold with a cap, a timeout, or a cooldown, or
demoting the repeated deferral log. Each suppresses the symptom while leaving
admission unfair, and `CLAUDE.md` §워크어라운드 거부 기준 names
cap/cooldown/dedup/repair as a rejection signature. The 16.3-minute hold is
not a bug in the chat operation; it is a turn that legitimately took that
long. The defect is that a legitimate long turn silently costs another lane
its scheduled work with no record beyond a skip reason.

## Directions to evaluate

Listed with what each would cost, not ranked — the choice depends on the
invariant established above.

1. **Symmetric admission.** Let the autonomous lane register intent instead of
   polling, and have `Child_finished` consult a single admission decision
   rather than offering the slot to chat unconditionally. Keeps one turn at a
   time; makes the order explicit and testable. Cost: the owner gains an
   admission queue and the ordering policy becomes a contract that has to be
   specified in the `.mli`.

2. **Typed deferral debt.** Keep the try-lock, but make a lost cycle a value
   the next admission reads, so N consecutive losses change the decision.
   Smaller change; risks becoming aging-by-another-name if the debt only
   feeds a threshold.

3. **Separate the lanes.** Only viable if the one-conversation invariant turns
   out not to require exclusion, which is exactly what is undocumented today.

## Verification

Whichever direction is taken, the acceptance bar is a test that fails against
the current tree:

- Two lanes contend on one owner; assert the autonomous lane runs within a
  bounded number of admissions rather than "eventually".
- A chat operation longer than one keepalive cycle does not cost the
  autonomous lane more than the specified number of cycles.
- The `.mli` states the cross-lane ordering, and a test pins it.

## References

- `lib/keeper/keeper_owner.ml` — `turn_in_flight`, `start_child_if_needed`, `Run_if_idle`
- `lib/keeper/keeper_heartbeat_loop.ml` — `Defer_autonomous_work`
- `lib/keeper/keeper_unified_turn_success.ml` — the "will resume next cycle" yield
