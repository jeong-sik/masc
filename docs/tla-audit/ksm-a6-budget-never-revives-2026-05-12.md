# A-6 Liveness Audit — `BudgetNeverRevives` Structural Gap

**Iteration**: 14 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperStateMachine.tla` §S3 `BudgetNeverRevives`
**Risk**: MID — invariant currently *holds in practice* but not *structurally enforced*.
**Type**: Audit-only (no code change in this PR).

## TLA+ contract

```tla
\* S3: Budget never revives once exhausted
BudgetNeverRevives ==
    [](~restart_budget_remaining => [](~restart_budget_remaining))
```

The flag is monotonic: once cleared, it stays cleared.  Paired with
`RestartBudgetExhausted` action (line 371-380), which has the
precondition `restart_budget_remaining = TRUE` (you can only exhaust
budget if it isn't already exhausted) and sets it to FALSE.

## OCaml topology

Two parallel "budget" axes:

| Axis | Type | Set by | Read by |
|---|---|---|---|
| `restart_count` (registry entry) | `int` | `record_restart` (incrementing) | `supervisor.ml:1468` gate `>= max_restarts` |
| `restart_budget_remaining` (conditions) | `bool` | `Restart_budget_exhausted` event + `mark_dead` | `derive_phase` Dead routing (line 505) |

The **supervisor uses the counter, not the flag**, to decide
restart-vs-mark-dead.  The flag is set as a *side-effect* inside the
same `to_mark_dead` loop, after the routing decision is already made.

## How `BudgetNeverRevives` is currently honored

Single-path coupling — `keeper_supervisor.ml`:

```
sweep_and_recover()
  └─ if restart_count >= max_restarts:
        to_mark_dead ← entry
            └─ dispatch Restart_budget_exhausted  (sets flag=false)
            └─ mark_dead                          (also sets flag=false)
     else if restart_count < max_restarts AND now - last_restart >= delay:
        to_restart ← entry
            └─ dispatch Supervisor_restart_attempt
            └─ register_restarting(...)            (overwrites flag=true)
```

Two flag-changing paths.  They **happen to** be mutually exclusive
because the supervisor only ever sends a keeper down one branch per
sweep.  The exclusivity is a consequence of `if/else`, not a typed
invariant.

## Structural gap (what would break it)

`register_restarting` is a registry-level primitive that
unconditionally writes `restart_budget_remaining = true`
(`keeper_registry.ml:771`).  Any future caller that invokes it on a
keeper whose flag was previously cleared — via *any* path — would
silently revive the budget and violate `BudgetNeverRevives`.

Three concrete vectors that could materialize:

1. **Operator-driven re-registration**: a `/masc_keeper_revive` command
   that calls `register_restarting` after operator inspection.  No
   guard against entry-with-budget=false → silent invariant violation.
2. **Non-supervisor recovery path**: if heartbeat-keeper or
   work-pipeline adds a "best-effort restart" path that bypasses the
   `restart_count >= max_restarts` gate, but the keeper had budget
   cleared via some other event sequence.
3. **Direct `Restart_budget_exhausted` event injection**: a manual
   admin command, debug tool, or migration script that dispatches the
   event *without* subsequently calling `mark_dead`.  The keeper is
   then in `restart_budget_remaining=false ∧ phase∈{Crashed, Failing,
   ...}`, eligible for the supervisor's restart branch on the next
   sweep — `register_restarting` revives it.

In all three cases, the compiler stays silent.  The first failure
surfaces only when an invariant check runs (`keeper_invariant_check.ml`
has `DeadRequiresNoBudget` but no symmetric "no-revive" assertion) or
when a downstream consumer relies on the BudgetNeverRevives semantics
(e.g., dashboards rendering "permanently dead" badges).

## Spec-side adjacent gap — `Restart_budget_exhausted` non-idempotency

`update_conditions` at `lib/keeper/keeper_state_machine.ml:644`:

```ocaml
| Restart_budget_exhausted -> { c with restart_budget_remaining = false }
```

Unconditional set.  Spec §RestartBudgetExhausted requires the
precondition `restart_budget_remaining = TRUE` (non-idempotency:
re-exhausting an already-exhausted budget is a logical no-op but masks
a duplicate dispatch in the caller).

This is the same systematic gap class as iter 9 F-9.1 (5
condition-setter events).  `Restart_budget_exhausted` was not on the
original list — making this the **6th candidate** for the R-A-9
precondition layer.

## Suggested fix paths (RFC candidates)

| ID | Scope | Action | Risk |
|---|---|---|---|
| R-A-6.a | Registry boundary | `register_restarting` returns `Result.t`, refuses to revive when an existing entry has `restart_budget_remaining=false`.  Distinguishes "new keeper registration" (no prior entry) from "restart of existing" (prior entry must have budget). | MID — touches 1 supervisor caller, 2 test callers. |
| R-A-6.b | FSM precondition layer | Add `Restart_budget_exhausted` arm to `check_event_precondition` (R-A-9 6th event): require `restart_budget_remaining=true`.  Idempotency violation → typed `Precondition_violation`. | LOW — single helper arm, follows the same pattern as PR-1/PR-2/PR-3. |
| R-A-6.c | Invariant checker | Add `BudgetNeverRevives` invariant to `keeper_invariant_check.ml` so an out-of-band revival surfaces at the next sweep instead of silently propagating. | LOW — pure read-only check, no flow change. |

R-A-6.b is the highest-leverage minimal fix and aligns with the closed
R-A-9 stack.  R-A-6.a is structurally cleaner but requires supervisor
touch.  R-A-6.c is defensive — useful regardless of which structural
fix lands.

## Verification target (for future PR)

- TLA+ Bug Model: add `BudgetRevivesAction == ... restart_budget_remaining'
  = TRUE` and `INVARIANT BudgetNeverRevives` — confirm spec catches the
  revival in N steps.
- OCaml test: simulate the three vectors above and assert
  `register_restarting` (or the FSM event) refuses or surfaces typed
  error.

## Out-of-scope for this iteration

- TLC re-verify of `BudgetNeverRevives` against the current spec —
  blocked by KNOWN_FAILURES #8710 until R-A-8 PR-2 closes.
- Supervisor restart-decision refactor (gate on flag vs counter) —
  RFC-scope.

## References

- iter 9 audit memo (R-A-9 systematic gap class): `ksm-precondition-enforcement-gap-2026-05-12.md`
- TLA+ S3 property line 543-544
- `register_restarting`: `lib/keeper/keeper_registry.ml:768-775`
- Supervisor restart decision: `lib/keeper/keeper_supervisor.ml:1468-1473`
- Mark-dead path: `lib/keeper/keeper_supervisor.ml:1639-1646`
- `Restart_budget_exhausted` event handler: `lib/keeper/keeper_state_machine.ml:644`
