# KTC B-2 Audit — Routing/Exhausted action modeling

**Iteration**: 34 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperTurnCycle.tla:127` (TurnPhaseSet) + actions §174-306
**OCaml**: `lib/keeper/keeper_registry.ml:234-275` (7 GADT routing transitions)
**Risk**: MID — type extension landed in iter 28 (#14793), but reachable state graph never grew.  Modeling routing/exhausted actions expands TLC state space; existing 7 cross-axis invariants need re-verification, and TLC re-verify cost is real (clean cfg today: 10 distinct states; estimate post-B-2: 40-80).
**Type**: Audit-only (action modeling deferred to B-2 implementation PR; this memo proposes the action set + state-space impact + RFC candidates).

## What's already done (iter 28, #14793 merged)

```tla
TurnPhaseSet == {"idle", "prompting", "routing", "executing",
                 "compacting", "finalizing", "exhausted"}
```

Type widening only.  No action transitions into `routing` or `exhausted`.
Init = "idle"; existing actions still drive idle → prompting → executing
→ {finalizing, compacting} → finalizing.  Reachable state graph: 10 states.

The R-B-1.c drift validator (CI workflow #14772) now passes with zero
turn_phase drift, but the spec lacks behavioral coverage of the two
new phases.

## OCaml GADT transitions (the truth source)

```ocaml
(* lib/keeper/keeper_registry.ml:234-244 *)
| Prompting_to_routing      : (turn_prompting,  turn_routing)    t
| Prompting_to_exhausted    : (turn_prompting,  turn_exhausted)  t
| Routing_to_prompting      : (turn_routing,    turn_prompting)  t
| Routing_to_routing        : (turn_routing,    turn_routing)    t
| Routing_to_executing      : (turn_routing,    turn_executing)  t
| Routing_to_exhausted      : (turn_routing,    turn_exhausted)  t
| Executing_to_routing      : (turn_executing,  turn_routing)    t
```

Seven distinct transitions, three of which involve `exhausted` as
terminal.  The GADT phantom types make this compile-time exhaustive on
the OCaml side — drift here is impossible without modifying the GADT.

## Proposed B-2 spec actions

Minimum 6 actions cover the 7 GADT transitions (Prompting_to_exhausted
and Routing_to_exhausted share `RoutingExhausted` with phase-source
guard).  Cross-axis guards keep TLC bounded:

| Action | OCaml transition(s) | Cross-axis guards | New variables touched |
|---|---|---|---|
| **RoutingStart** | Prompting_to_routing | `turn_phase = "prompting" /\ decision_stage = "tool_policy_selected" /\ cascade_state = "selecting"` | `turn_phase' = "routing" /\ cascade_state' = "trying"` (or selecting?) |
| **RoutingRetry** | Routing_to_routing | `turn_phase = "routing" /\ cascade_state = "trying"` | UNCHANGED most; advances internal tier (not modeled) |
| **RoutingToPrompting** | Routing_to_prompting | `turn_phase = "routing"` (overflow retry?) | `turn_phase' = "prompting" /\ cascade_state' = "idle"` |
| **RoutingToExecuting** | Routing_to_executing | `turn_phase = "routing" /\ cascade_state = "trying"` | `turn_phase' = "executing"` |
| **RoutingExhausted** | Routing_to_exhausted, Prompting_to_exhausted | `turn_phase \in {"routing", "prompting"} /\ cascade_state \in {"trying", "selecting"}` | `turn_phase' = "exhausted" /\ cascade_state' = "exhausted"` |
| **ExecutingToRouting** | Executing_to_routing | `turn_phase = "executing" /\ cascade_state = "trying"` (retry vector) | `turn_phase' = "routing" /\ cascade_state' = "trying"` |

Note: `Routing_to_routing` (self-loop) is *attempt-level* not phase-level — the cascade attempt FSM (KCAF, #14798) handles per-attempt tier advance.  In KTC's phase axis, `RoutingRetry` is effectively a no-op except for a side-effect counter that KTC doesn't track.  This may not need a spec action.

## Cross-axis invariant impact (7 existing invariants)

| Invariant | Routing addition impact |
|---|---|
| `NoLiveTurnClearsState` | Add `~turn_live => turn_phase /= "routing" /\ turn_phase /= "exhausted"` cleanups; FinishTurn already covers via `TurnPhaseSet \ {"idle"}` |
| `IdleRequiresNotLive` | No change |
| `GateRejectedRequiresFinalizing` | Need to add: GateRejected only fires in executing today — does it fire in routing too?  Probably not (gate is per-tool-call); confirm with OCaml `keeper_guards.ml`. |
| `SelectingRequiresToolPolicy` | `cascade_state = "selecting"` only in prompting or routing; routing entry preserves invariant. |
| `ExecutingRequiresTrying` | Add routing arm: `turn_phase \in {"executing", "routing"} /\ cascade_state \in {"trying", ...}` — but routing's cascade_state semantics may differ; needs OCaml inspection. |
| `CompactingRequiresTrying` | No routing impact (compacting is post-execution overflow). |
| `TerminalCascadeRequiresFinalizing` | Add exhausted arm: `cascade_state = "exhausted" => turn_phase \in {"finalizing", "exhausted"}`. |

## TLC state-space estimate

Current (iter 28 + main): 10 distinct states, depth 6.

Estimate post-B-2:
- 6 new actions × 4-5 distinct (turn_phase, cascade_state) combinations per action = ~25 new transitions.
- Reachable state space: ~40-80 distinct states.
- Depth: ~8-10.

If state space grows >100, the bug model (`KeeperTurnCycle-buggy.cfg`)
may need adjusted bounds or additional `MaxSteps`-style constraints to
keep TLC under 30s wall.  Pre-implementation TLC dry-run on a draft
PR is mandatory.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| **R-B-2.a** | Spec — add 5-6 actions (RoutingStart / RoutingToPrompting / RoutingToExecuting / RoutingExhausted / ExecutingToRouting; defer RoutingRetry as attempt-level).  Update 2-3 cross-axis invariants (ExecutingRequiresTrying, TerminalCascadeRequiresFinalizing).  TLC re-verify both clean + buggy. | MID — single-spec change but state-space growth + invariant edits |
| R-B-2.b | Spec — partial modeling: only add **RoutingExhausted** (the terminal absorber) to capture the `Prompting_to_exhausted` early-out + `Routing_to_exhausted` late-out.  Defers cycle modeling.  Easier TLC verification. | LOW-MID — single action add |
| R-B-2.c | Document-only: extend KTC header `Adding new constructors` comment (line 85) to note "routing/exhausted are spec-typed but not action-modeled; per-attempt tier advance lives in KCAF.tla".  Acknowledge the architectural choice without modeling.  Defers full coverage. | LOW (doc only) |

R-B-2.b is the cheapest implementable path — closes the "exhausted is reachable" axis without modeling routing's internal loop.  R-B-2.a is full coverage.  R-B-2.c is documentation honesty (matches iter 27's KCT abstraction comment pattern).

## Why production stays correct (today)

- OCaml GADT compile-time exhaustiveness blocks malformed routing transitions at the type level — drift here requires modifying `keeper_registry.ml:234-244` itself.
- Cascade attempt-level state lives in KCAF (KeeperCascadeAttemptFSM.tla #14798 entry) which already models the 6-phase attempt FSM with 3 BugActions.  KTC's routing phase is the *projection* of KCAF onto the keeper-facing turn axis.
- Cross-axis invariants in the current spec all condition on `turn_phase` values they don't reach — they're true vacuously for routing/exhausted.

So this is a **coverage-breadth** gap, not a runtime bug.  The spec is *narrower* than OCaml on the keeper-projection axis.

## Comparison with sibling audits

| Audit | Spec form | OCaml form | Gap class |
|---|---|---|---|
| iter 19 KTC B-1 (#14767) | TurnPhaseSet = 5 | turn_phase = 7 | Spec narrower (type level) — closed iter 28 |
| **iter 34 KTC B-2 (this)** | Actions = 11 covering 5 phases | GADT transitions = 7 covering 7 phases | Spec narrower (action level) |
| iter 30 KCAF D-1 (#14798) | ProviderOutcomes = 6 (cfg) | `Call_err` = 1 (runtime-classified) | Spec wider; OCaml runtime-collapses |

B-2 is the action-level analog of B-1's type-level gap.  Same pattern, same fix shape, larger TLC re-verify burden.

## Out-of-scope for this iteration

- Implementation of any R-B-2.{a,b,c} — separate PR with TLC re-verify.
- KCAF cross-spec invariant linking routing in KTC to attempt FSM in KCAF — that's a higher-level joint property suitable for `KeeperCompositeLifecycle.tla` observer (Phase E).
- `Routing_to_routing` attempt-level modeling — belongs in KCAF, not KTC.

## References

- KTC spec §127 (TurnPhaseSet, iter 28-extended), §174-306 (Next actions).
- `lib/keeper/keeper_registry.ml:234-275` (7 GADT transitions + dispatch labels).
- KTC B-1 audit (`ktc-b1-turn-phase-spec-gap-2026-05-12.md`) — sibling type-level gap, closed iter 28.
- KCAF D-1 audit (`kcaf-d1-attempt-fsm-coverage-2026-05-12.md`) — attempt-level FSM that the routing phase projects from.
- iter 28 (#14793) — R-B-1.a closure precedent for spec extension + paired-baseline pattern.
