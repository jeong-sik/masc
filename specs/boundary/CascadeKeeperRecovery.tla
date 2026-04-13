---- MODULE CascadeKeeperRecovery ----
\* Cross-domain boundary spec: Cascade (OAS) x Keeper lifecycle (MASC).
\*
\* Models the end-to-end recovery path from cascade exhaustion through
\* keeper retry loop, Failing phase, and eventual recovery when providers
\* come back online.
\*
\* Gap identified in cascade-fsm-gap-2026-04-13.md: existing specs model
\* cascade exhaustion (CascadeExhaustion.tla) and keeper lifecycle
\* (KeeperStateMachine.tla) in isolation. No spec connects them to verify
\* that cascade exhaustion -> keeper retry -> Failing -> recovery is live.
\*
\* The real code path:
\*   1. cascade_executor.ml tries providers in order. All fail -> Error.
\*   2. keeper_unified_turn.ml:retry_loop retries up to MaxRetries times.
\*   3. If all retries fail, TurnFailed dispatched to FSM -> Failing.
\*   4. After MaxFailures consecutive failures, keeper crashes.
\*   5. Supervisor restarts (if budget permits) -> Running.
\*   6. If providers recover, next turn succeeds -> exit Failing.
\*
\* Domain boundary: lib/llm_provider/cascade_executor.ml (OAS cascade) x
\*                  lib/keeper/keeper_unified_turn.ml (retry loop) x
\*                  lib/keeper/keeper_state_machine.ml (phase transitions) x
\*                  lib/keeper/keeper_supervisor.ml (restart budget)

EXTENDS Naturals, FiniteSets

CONSTANTS
    NumProviders,       \* Number of providers in cascade (e.g. 2: GLM, Ollama)
    MaxRetries,         \* Retries per turn (e.g. 2, total attempts = 1 + MaxRetries)
    MaxFailures,        \* Consecutive failures before crash (e.g. 3)
    MaxRestarts         \* Supervisor restart budget (e.g. 2)

ASSUME NumProviders > 0 /\ MaxRetries >= 0 /\ MaxFailures > 0
ASSUME MaxRestarts >= 0

P == 1..NumProviders

VARIABLES
    \* Cascade layer (OAS)
    provider_health,    \* [P -> {"healthy", "unhealthy"}]
    \* Keeper turn layer (MASC)
    keeper_phase,       \* "running" | "failing" | "crashed" | "dead"
    retry_count,        \* current cascade retry count (0..MaxRetries)
    fail_count,         \* consecutive turn failures (0..MaxFailures)
    restart_count       \* supervisor restarts consumed (0..MaxRestarts)

vars == <<provider_health, keeper_phase, retry_count, fail_count,
          restart_count>>

KeeperPhases == {"running", "failing", "crashed", "dead"}

TypeOK ==
    /\ provider_health \in [P -> {"healthy", "unhealthy"}]
    /\ keeper_phase \in KeeperPhases
    /\ retry_count \in 0..MaxRetries
    /\ fail_count \in 0..MaxFailures
    /\ restart_count \in 0..MaxRestarts

\* Derived: at least one provider is healthy.
SomeProviderHealthy == \E p \in P : provider_health[p] = "healthy"

\* ---- Init ----

Init ==
    /\ provider_health = [p \in P |-> "healthy"]
    /\ keeper_phase = "running"
    /\ retry_count = 0
    /\ fail_count = 0
    /\ restart_count = 0

\* ---- Environment Actions ----

\* Provider health can toggle at any time (models network failure,
\* rate limiting, Ollama crash, etc.).
ProviderFail(p) ==
    /\ provider_health[p] = "healthy"
    /\ provider_health' = [provider_health EXCEPT ![p] = "unhealthy"]
    /\ UNCHANGED <<keeper_phase, retry_count, fail_count, restart_count>>

ProviderRecover(p) ==
    /\ provider_health[p] = "unhealthy"
    /\ provider_health' = [provider_health EXCEPT ![p] = "healthy"]
    /\ UNCHANGED <<keeper_phase, retry_count, fail_count, restart_count>>

\* ---- Cascade Actions ----

\* Cascade attempt: the keeper tries a turn via the cascade.
\* If any provider is healthy, the cascade succeeds.
\* If all providers are unhealthy, the cascade fails.
CascadeSucceeds ==
    /\ keeper_phase \in {"running", "failing"}
    /\ SomeProviderHealthy
    /\ retry_count' = 0
    /\ fail_count' = 0
    /\ keeper_phase' = "running"
    /\ UNCHANGED <<provider_health, restart_count>>

CascadeFails ==
    /\ keeper_phase \in {"running", "failing"}
    /\ ~SomeProviderHealthy
    /\ IF retry_count < MaxRetries
       THEN \* Retry (transient error, backoff)
            /\ retry_count' = retry_count + 1
            /\ UNCHANGED <<keeper_phase, fail_count, restart_count>>
       ELSE \* All retries exhausted: turn fails
            /\ retry_count' = 0
            /\ fail_count' = fail_count + 1
            /\ IF fail_count + 1 >= MaxFailures
               THEN keeper_phase' = "crashed"
               ELSE keeper_phase' = "failing"
            /\ UNCHANGED restart_count
    /\ UNCHANGED provider_health

\* ---- Keeper Lifecycle Actions ----

\* Supervisor restarts a crashed keeper (if budget permits).
SupervisorRestart ==
    /\ keeper_phase = "crashed"
    /\ restart_count < MaxRestarts
    /\ keeper_phase' = "running"
    /\ restart_count' = restart_count + 1
    /\ fail_count' = 0
    /\ retry_count' = 0
    /\ UNCHANGED provider_health

\* Supervisor cannot restart: budget exhausted -> Dead.
BudgetExhausted ==
    /\ keeper_phase = "crashed"
    /\ restart_count >= MaxRestarts
    /\ keeper_phase' = "dead"
    /\ UNCHANGED <<provider_health, retry_count, fail_count, restart_count>>

\* ---- Clean Next ----

Next ==
    \/ \E p \in P : ProviderFail(p)
    \/ \E p \in P : ProviderRecover(p)
    \/ CascadeSucceeds
    \/ CascadeFails
    \/ SupervisorRestart
    \/ BudgetExhausted

\* Fairness:
\* - ProviderFail is NOT fair (adversarial environment).
\* - ProviderRecover: WF (if continuously enabled, eventually fires).
\* - CascadeSucceeds: SF (if repeatedly enabled, eventually fires).
\*   WF is too weak because provider health can toggle between cascade
\*   attempts, making CascadeSucceeds intermittently disabled. SF models
\*   the real system where a cascade attempt is atomic with respect to
\*   provider health at invocation time.
\* - SupervisorRestart: WF (supervisor always attempts restart if budget).
Fairness ==
    /\ \A p \in P : WF_vars(ProviderRecover(p))
    /\ SF_vars(CascadeSucceeds)
    /\ WF_vars(CascadeFails)
    /\ WF_vars(SupervisorRestart)
    /\ WF_vars(BudgetExhausted)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ---- Safety Invariants ----

\* S1: restart_count bounded.
RestartBounded ==
    restart_count <= MaxRestarts

\* S2: fail_count bounded.
FailCountBounded ==
    fail_count <= MaxFailures

\* S3: retry_count bounded.
RetryCountBounded ==
    retry_count <= MaxRetries

\* S4: Dead only when budget is exhausted.
DeadRequiresNoBudget ==
    keeper_phase = "dead" => restart_count >= MaxRestarts

\* Combined safety
SafetyInvariant ==
    /\ TypeOK
    /\ RestartBounded
    /\ FailCountBounded
    /\ RetryCountBounded
    /\ DeadRequiresNoBudget

\* ---- Liveness Properties ----

\* L1: If the keeper is Failing, it eventually reaches Running or Dead.
\* The keeper never stays stuck in Failing indefinitely.
FailingResolves ==
    keeper_phase = "failing" ~> keeper_phase \in {"running", "dead"}

\* ---- Bug Model: no SupervisorRestart ----
\*
\* Without the supervisor restart mechanism, a keeper that crashes
\* (all retries exhausted, MaxFailures consecutive failures) has no
\* recovery path. Even when providers come back, the keeper stays
\* in "crashed" forever. FailingResolves is violated because the
\* keeper can go Failing -> Crashed and then get stuck.

NextBuggy ==
    \/ \E p \in P : ProviderFail(p)
    \/ \E p \in P : ProviderRecover(p)
    \/ CascadeSucceeds
    \/ CascadeFails
    \* SupervisorRestart OMITTED (the bug)
    \/ BudgetExhausted

FairnessBuggy ==
    /\ \A p \in P : WF_vars(ProviderRecover(p))
    /\ WF_vars(CascadeSucceeds)
    /\ WF_vars(CascadeFails)
    /\ WF_vars(BudgetExhausted)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

====
