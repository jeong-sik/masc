# KCAF D-2 Audit — `exhausted_normal` vs `exhausted_hard_quota` asymmetry

**Iteration**: 36 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperCascadeAttemptFSM.tla:79-84, 153-174, 240-241` (terminal phase set + ResolveExhaustedNormal/ResolveHardQuota + HardQuotaTerminalImmediate invariant)
**OCaml**: `lib/cascade/cascade_fsm.ml:20, 44-52` (single `Exhausted` constructor + decide branches), `lib/keeper/keeper_turn_driver.ml:644-672` (hard-quota fast-path)
**Risk**: MID — spec distinguishes two terminal phases with a load-bearing invariant; OCaml collapses both into one constructor, recovering the distinction only through caller-side flow and side-effects (cooldown record).
**Type**: Audit-only.  Terminal-phase analog of iter 30 D-1 Gap 1 (input-level `Call_err` runtime classifier).

## Spec model (3 paths to terminal)

```tla
PhaseSet ==
    {"idle", "attempting", "awaiting_response",
     "success", "exhausted_normal", "exhausted_hard_quota"}

TerminalSet == {"success", "exhausted_normal", "exhausted_hard_quota"}

\* Normal exhaustion: last tier + cascadeable error
ResolveExhaustedNormal ==
    /\ attempt_phase = "awaiting_response"
    /\ tier_index = MaxTiers - 1
    /\ \E outcome \in (ProviderOutcomes \ {"call_ok", "call_err_hard_quota"}):
         /\ attempt_phase' = "exhausted_normal"
         /\ slot_held' = FALSE
         /\ UNCHANGED <<tier_index, hard_quota_taken>>

\* Hard-quota: ANY tier, force terminal, slot released, flag set
ResolveHardQuota ==
    /\ attempt_phase = "awaiting_response"
    /\ last_outcome' = "call_err_hard_quota"
    /\ attempt_phase' = "exhausted_hard_quota"
    /\ slot_held' = FALSE
    /\ hard_quota_taken' = TRUE
    /\ UNCHANGED <<tier_index>>

\* Load-bearing invariant
HardQuotaTerminalImmediate ==
    attempt_phase = "exhausted_hard_quota" => hard_quota_taken
```

Two distinct terminal phases.  `hard_quota_taken` flag tracks whether
the hard-quota fast-path fired.  Spec asserts: if FSM landed in
`exhausted_hard_quota`, the flag MUST be true.  This is what
`BugHardQuotaBypass` (spec line 191) violates.

## OCaml model (single constructor, branch in caller)

```ocaml
(* lib/cascade/cascade_fsm.ml:20 — single typed surface *)
| Exhausted of { last_err : Llm_provider.Http_client.http_error option }
    [@tla.symbol "exhausted"]

(* lib/cascade/cascade_fsm.ml:44, 52 — decide returns Exhausted from
   two distinct semantic paths *)
| Accept_rejected { response; reason } when is_last && not accept_on_exhaustion ->
    Exhausted { last_err = Some (AcceptRejected { reason }) }
| Call_err err when not should_cascade ->
    Exhausted { last_err = Some err }
```

`decide` is *agnostic to hard-quota*.  The classification happens upstream:

```ocaml
(* lib/keeper/keeper_turn_driver.ml:654-672 *)
match sdk_error_to_cascade_outcome sdk_err with
| Some outcome ->
  let decision =
    if sdk_error_is_hard_quota sdk_err then
      let last_err = ... in
      Cascade_fsm.Exhausted { last_err }    (* fast-path: skip decide *)
    else
      Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome
  in
  ...
```

Both branches return the **same** `Exhausted` constructor.  The
distinction is:
- *Whether the hard-quota predicate fired* (runtime branch taken).
- *Cooldown side effect* recorded ~line 1760 (before this match).
- *Tier index* (hard-quota fires on any tier, normal only on last).

None of these are visible to the caller's `| Cascade_fsm.Exhausted _ ->`
pattern at line 512, 722.  Once `decide`-or-fast-path returns, the
two semantic paths are indistinguishable.

## Why this is the terminal-phase analog of D-1 Gap 1

| Gap level | D-1 (iter 30) | D-2 (this) |
|---|---|---|
| Spec abstract alphabet | `call_err_cascadeable` / `_terminal` / `_hard_quota` | `exhausted_normal` / `exhausted_hard_quota` |
| OCaml type | single `Call_err` | single `Exhausted` |
| Classifier location | `Cascade_health_filter.should_cascade_to_next` (input side) + `sdk_error_is_hard_quota` | `sdk_error_is_hard_quota` (already noted in D-1) + tier_index check |
| Cross-file coupling | `keeper_turn_driver.ml:657-669` | same site + line 1760 cooldown record |
| Load-bearing invariant | `BugHardQuotaBypass` violates `HardQuotaTerminalImmediate` | identical |
| Production preservation | Cascade_health_filter corpus tests + Fun.protect finalizer | + cooldown side effect persists to next turn |

D-1 caught the spec asymmetry at the *error input* level; D-2 catches it at the *terminal output* level.  Both share the same classifier (`sdk_error_is_hard_quota`) and the same cross-file location.

## Where production stays correct (today)

- Hard-quota cooldown side effect (`record_failure` ~line 1760) persists across the `Exhausted` collapse — next turn's selector skips the keeper anyway.
- `Cascade_metrics.on_exhausted` (cascade_fsm.ml:133) fires for both flavors but with the same `cascade_name` — the metric loses the distinction without the side effect.
- The bug model in `KeeperCascadeAttemptFSM-buggy.cfg` already covers
  `BugHardQuotaBypass` at TLC level: it asserts that if the override
  isn't used, `HardQuotaTerminalImmediate` is violated.  TLC catches
  the regression spec-side; production catches it via cooldown
  divergence (a hard-quota retry burning OAS turn budget) — different
  observability paths.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| **R-D-2.a** | OCaml — split `Cascade_fsm.Exhausted` into typed sub-variants `Exhausted_normal of {...}` and `Exhausted_hard_quota of {...}`.  Removes the runtime-classifier-recovery requirement at every caller.  Pairs cleanly with R-D-1.a (Call_err split) since both share `sdk_error_is_hard_quota`. | MID — type sig change in cascade_fsm.ml/.mli + keeper_turn_driver.ml caller arm + dashboard metric updates + tests.  ~10-15 call sites. |
| R-D-2.b | Spec — drop the spec asymmetry, merge `exhausted_normal` and `exhausted_hard_quota` into a single `exhausted` terminal.  `hard_quota_taken` flag remains but no longer gates a phase.  Bug model adapts: `BugHardQuotaBypass` instead asserts that `hard_quota_taken` is correctly set rather than that the phase is `_hard_quota`.  LESS recommended — gives up safety surface. | LOW-MID — spec change + TLC re-verify, but reduces drift-catching power. |
| R-D-2.c | Spec — add inline commentary noting the OCaml classifier lives outside `decide` (in `keeper_turn_driver.ml:657-669`), so the spec's two terminal phases are *role identities* captured by `hard_quota_taken`, not OCaml constructor distinctions.  Honest-doc pattern (iter 27 KCT, iter 35 KTC precedents). | LOW (doc only) |

R-D-2.c is the cheapest LOW alignment fix and matches the established honest-doc pattern.  R-D-2.a is the structurally cleanest correctness fix and could land as a bundle with R-D-1.a (Call_err split) since both share the `sdk_error_is_hard_quota` predicate, which would close both iter 30 Gap 1 and this D-2 gap in one PR.  R-D-2.b is NOT recommended — gives up the spec's load-bearing distinction without commensurate benefit.

## Pattern family: outcome-level classifier drift

iter 30 (D-1) and iter 36 (this D-2) together define a **family of drift**:

```
Spec:    [typed alphabet at input] → [decision FSM] → [typed alphabet at output]
              ↑                             ↑                          ↑
              D-1 gap                       —                          D-2 gap
              ↓                             ↓                          ↓
OCaml:   [single Call_err] → [runtime classifier outside decide] → [single Exhausted]
              ↑                             ↑                          ↑
              flattens here                 — same classifier —        flattens here
```

Both gaps share:
- The same upstream-of-decide classifier (`sdk_error_is_hard_quota`).
- The same cross-file location (`keeper_turn_driver.ml:654-672`).
- The same recovery path (the OCaml caller's behavior matches spec's
  intent through *separately-stored side effects* — cooldown record,
  tier index — rather than constructor distinctions).

This pattern is a **flat-vs-typed alphabet collapse** at the FSM boundary.
Closing it structurally requires R-D-2.a + R-D-1.a *together*, treating
the `sdk_error_is_hard_quota` boundary as the single classifier site to
move from runtime to constructor.

## R-D-2.a bundled with R-D-1.a (proposed PR shape)

If R-D-1.a (Call_err split) and R-D-2.a (Exhausted split) land in the
same PR, the diff shape becomes:

1. Update `cascade_fsm.ml/.mli` `provider_outcome` to 6 typed
   constructors (call_ok, call_err_cascadeable, call_err_terminal,
   call_err_hard_quota, accept_rejected, slot_full) — matches spec's
   ProviderOutcomes alphabet.
2. Update `cascade_fsm.ml/.mli` `decision` to 5 typed constructors
   (accept, accept_on_exhaustion, try_next, exhausted_normal,
   exhausted_hard_quota) — matches spec's PhaseSet's terminal members.
3. Move `sdk_error_is_hard_quota` *into* `cascade_fsm.decide` as a
   classifier parameter, so the runtime decision is centralized.
4. Update `keeper_turn_driver.ml:654-672` to remove the fast-path
   branch — `decide` handles it via constructor selection.
5. Remove `provider_outcome:call_err` baseline entry from iter 33's
   addition (paired-removal policy).

This is a sizeable refactor — ~150-300 LOC across cascade + keeper +
tests — but it closes 3 gaps simultaneously (D-1, D-2, and iter 33
baseline).  Recommended as a future multi-iteration RFC.

## Out-of-scope for this iteration

- R-D-2.a/b/c implementation — separate PR.
- Cross-spec invariant linking KCAF terminal phases to KTC `exhausted`
  in routing projection — Phase E observer concern.
- `Cascade_metrics.on_exhausted` distinguishing the two flavors —
  observability follow-up; landing R-D-2.a unlocks it trivially.

## References

- KCAF spec §79-84 (PhaseSet), §153-174 (ResolveExhaustedNormal/Hard),
  §191-200 (BugHardQuotaBypass), §240-241 (HardQuotaTerminalImmediate).
- `lib/cascade/cascade_fsm.ml:20, 44-52, 116-133` (decide + caller pattern).
- `lib/keeper/keeper_turn_driver.ml:644-672, 512, 722` (fast-path +
  caller-arm pattern matches).
- iter 30 D-1 audit (`kcaf-d1-attempt-fsm-coverage-2026-05-12.md`) —
  input-level analog.
- iter 33 R-D-1.b activation (#14804) — baseline-listed `provider_outcome:call_err`.
- iter 27 (#14789), iter 35 (#14811) — honest-doc precedents for R-D-2.c.
