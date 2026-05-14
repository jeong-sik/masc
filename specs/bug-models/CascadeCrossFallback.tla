---- MODULE CascadeCrossFallback ----
\* Bug Model: cross-cascade fallback per-turn budget.
\*
\* Models the cross-cascade promotion path around strict provider resolution,
\* tool-support filtering, and keeper cascade execution:
\*   lib/cascade/cascade_catalog_runtime.ml:resolve_named_providers_strict_with_secondary_resolver
\*   lib/cascade/cascade_oas_runner.ml:filter_candidate_providers_for_tool_support
\*   lib/keeper/keeper_turn_driver.ml:run_named
\* The old resolve_tool_capable_provider_across_cascades helper was removed
\* when runtime routing fallbacks were purged; the safety obligation now lives
\* on the strict provider resolution + secondary-resolver path above.
\*
\* The intended behavior: when a primary cascade exhausts in a turn, the
\* runtime is allowed to promote ONE provider from the fleet inventory as
\* a one-shot fallback. A second cross-cascade promotion within the same
\* turn would defeat the cooldown semantics (the just-rejected provider
\* could otherwise be re-elected via the fleet view) and starve the
\* normal cascade-rotation path of any back-pressure signal.
\*
\* Bug hypothesis: callers forget the per-turn guard and re-enter
\* cross-cascade promotion every time the inventory has *some* idle
\* provider. We model that as PromoteUnbounded — Promote without
\* updating the guard counter.
\*
\* Verified against (2026-05-14):
\*   lib/cascade/cascade_catalog_runtime.ml
\*       — strict provider resolution + secondary resolver
\*   lib/cascade/cascade_oas_runner.ml
\*       — tool-support filtering with secondary_resolver
\*   lib/keeper/keeper_turn_driver.ml
\*       — keeper named-cascade execution entry point
\*
\* The spec is intentionally narrow: it does not model provider ranking or
\* request execution. Those are covered by cascade runtime/unit tests; this
\* spec only enforces the safety property "at most one cross-cascade
\* promotion per turn".

EXTENDS Naturals

CONSTANTS
    NumCascades,            \* size of the fleet inventory (e.g. 3)
    PrimaryCascadeFails     \* Boolean: does the primary cascade exhaust?

VARIABLES
    turn_state,             \* "running" | "primary_done" | "promoted" | "finished"
    primary_outcome,        \* "pending" | "ok" | "exhausted"
    cross_promotions,       \* counter of cross-cascade promotions so far this turn
    final_provider          \* "none" | "primary" | "promoted" | "failed"

vars == <<turn_state, primary_outcome, cross_promotions, final_provider>>

TypeOK ==
    /\ turn_state \in {"running", "primary_done", "promoted", "finished"}
    /\ primary_outcome \in {"pending", "ok", "exhausted"}
    /\ cross_promotions \in 0..NumCascades
    /\ final_provider \in {"none", "primary", "promoted", "failed"}

Init ==
    /\ turn_state = "running"
    /\ primary_outcome = "pending"
    /\ cross_promotions = 0
    /\ final_provider = "none"

\* Primary cascade returns a working provider — turn ends successfully.
PrimaryOk ==
    /\ turn_state = "running"
    /\ ~PrimaryCascadeFails
    /\ primary_outcome' = "ok"
    /\ turn_state' = "finished"
    /\ final_provider' = "primary"
    /\ UNCHANGED cross_promotions

\* Primary cascade exhausts; runtime is now eligible for cross-cascade
\* promotion (subject to the per-turn budget).
PrimaryExhaust ==
    /\ turn_state = "running"
    /\ PrimaryCascadeFails
    /\ primary_outcome' = "exhausted"
    /\ turn_state' = "primary_done"
    /\ UNCHANGED <<cross_promotions, final_provider>>

\* Cross-cascade promotion. The guard increments cross_promotions and
\* refuses to fire again. After one promotion the turn ends — either the
\* fleet had a runner (final_provider = "promoted") or it didn't, in
\* which case the turn fails outright (final_provider = "failed"). Either
\* way, no second promotion is allowed.
Promote ==
    /\ turn_state = "primary_done"
    /\ cross_promotions = 0
    /\ cross_promotions' = 1
    /\ turn_state' = "finished"
    /\ final_provider' \in {"promoted", "failed"}
    /\ UNCHANGED primary_outcome

Next ==
    \/ PrimaryOk
    \/ PrimaryExhaust
    \/ Promote

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants ──────────────────────────────────

\* Core invariant: at most ONE cross-cascade promotion per turn.
\* This is the property PR4 must preserve as the keeper runtime evolves.
AtMostOneCrossCascadePerTurn ==
    cross_promotions <= 1

\* If the turn finished via promotion, the primary cascade had to exhaust
\* first — promotion never fires while the primary is still viable.
PromotionRequiresExhaustion ==
    final_provider = "promoted" => primary_outcome = "exhausted"

\* No "double-spend": once the turn is finished, the counter is frozen.
PromotionFrozenAfterFinish ==
    turn_state = "finished" => cross_promotions \in {0, 1}

\* ── Bug Model ──────────────────────────────────────────

\* Bug: caller forgets the per-turn guard and re-enters Promote multiple
\* times. Models the regression where the cross-cascade resolver is
\* invoked from a retry loop without updating cross_promotions.
PromoteUnbounded ==
    /\ turn_state = "primary_done"
    /\ cross_promotions < NumCascades
    /\ cross_promotions' = cross_promotions + 1
    \* Bug variant: stays in "primary_done" so the action can fire again.
    /\ UNCHANGED <<turn_state, primary_outcome, final_provider>>

NextBuggy ==
    \/ PrimaryOk
    \/ PrimaryExhaust
    \/ PromoteUnbounded

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(NextBuggy)

====
