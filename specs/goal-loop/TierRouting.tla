---- MODULE TierRouting ----
\* Prompt-level GOAL LOOP tier-routing contract.
\*
\* This is not a provider implementation model. It pins the verification
\* claim from the supplied GOAL LOOP prompt set: fallback routing may only
\* occur after the primary tier has been probed and found unavailable, and
\* any selected tier must be healthy at the abstraction boundary.
\*
\* Runtime evidence still comes from metrics/logs; this spec only covers the
\* finite-state safety contract consumed by scripts/goal_loop_verify_pipeline.py.

EXTENDS TLC

VARIABLES primary_health, secondary_health, decision, used_fallback

vars == <<primary_health, secondary_health, decision, used_fallback>>

HealthSet == {"unknown", "healthy", "unhealthy"}
DecisionSet == {"none", "primary", "fallback", "exhausted"}

TypeOK ==
    /\ primary_health \in HealthSet
    /\ secondary_health \in HealthSet
    /\ decision \in DecisionSet
    /\ used_fallback \in BOOLEAN

Init ==
    /\ primary_health = "unknown"
    /\ secondary_health = "unknown"
    /\ decision = "none"
    /\ used_fallback = FALSE

ProbePrimaryHealthy ==
    /\ primary_health = "unknown"
    /\ primary_health' = "healthy"
    /\ UNCHANGED <<secondary_health, decision, used_fallback>>

ProbePrimaryUnhealthy ==
    /\ primary_health = "unknown"
    /\ primary_health' = "unhealthy"
    /\ UNCHANGED <<secondary_health, decision, used_fallback>>

ProbeSecondaryHealthy ==
    /\ secondary_health = "unknown"
    /\ secondary_health' = "healthy"
    /\ UNCHANGED <<primary_health, decision, used_fallback>>

ProbeSecondaryUnhealthy ==
    /\ secondary_health = "unknown"
    /\ secondary_health' = "unhealthy"
    /\ UNCHANGED <<primary_health, decision, used_fallback>>

RoutePrimary ==
    /\ decision = "none"
    /\ primary_health = "healthy"
    /\ decision' = "primary"
    /\ used_fallback' = FALSE
    /\ UNCHANGED <<primary_health, secondary_health>>

RouteFallback ==
    /\ decision = "none"
    /\ primary_health = "unhealthy"
    /\ secondary_health = "healthy"
    /\ decision' = "fallback"
    /\ used_fallback' = TRUE
    /\ UNCHANGED <<primary_health, secondary_health>>

Exhaust ==
    /\ decision = "none"
    /\ primary_health = "unhealthy"
    /\ secondary_health = "unhealthy"
    /\ decision' = "exhausted"
    /\ used_fallback' = FALSE
    /\ UNCHANGED <<primary_health, secondary_health>>

Next ==
    \/ ProbePrimaryHealthy
    \/ ProbePrimaryUnhealthy
    \/ ProbeSecondaryHealthy
    \/ ProbeSecondaryUnhealthy
    \/ RoutePrimary
    \/ RouteFallback
    \/ Exhaust

Spec == Init /\ [][Next]_vars

FallbackAfterPrimaryFailure ==
    used_fallback => primary_health = "unhealthy"

SelectedTierHealthy ==
    /\ decision = "primary" => primary_health = "healthy"
    /\ decision = "fallback" => secondary_health = "healthy"

ExhaustOnlyAfterAllUnavailable ==
    decision = "exhausted" =>
        /\ primary_health = "unhealthy"
        /\ secondary_health = "unhealthy"

Safety ==
    /\ TypeOK
    /\ FallbackAfterPrimaryFailure
    /\ SelectedTierHealthy
    /\ ExhaustOnlyAfterAllUnavailable
====
