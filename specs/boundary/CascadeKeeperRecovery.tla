---- MODULE CascadeKeeperRecovery ----
\* Cross-domain boundary spec: cascade availability x keeper recovery path.
\*
\* This is a boundary model, not a full copy of the runtime. It captures the
\* keeper-facing contract that matters after cascade exhaustion:
\*   1. A live turn starts while the keeper is Running or Failing.
\*   2. If any provider is healthy, the turn succeeds and the keeper returns
\*      to Running with failure counters reset.
\*   3. If all providers are unavailable long enough, the turn exhausts,
\*      pushes the keeper into Failing, and eventually crashes after the
\*      persistent-failure threshold.
\*   4. A crashed keeper uses the supervisor path Crashed -> Restarting ->
\*      Running while budget remains; otherwise it becomes Dead.
\*
\* Domain boundary:
\*   - OAS/provider health availability
\*   - keeper_unified_turn retry loop
\*   - KeeperStateMachine / keepalive crash escalation
\*   - supervisor restart path

EXTENDS Naturals, FiniteSets

CONSTANTS
    NumProviders,
    MaxRetries,
    MaxFailures,
    MaxRestarts

ASSUME NumProviders > 0 /\ MaxRetries >= 0 /\ MaxFailures > 0 /\ MaxRestarts >= 0

P == 1..NumProviders

VARIABLES
    provider_health,   \* [P -> {"healthy", "unhealthy"}]
    keeper_phase,      \* "running" | "failing" | "crashed" | "restarting" | "dead"
    turn_state,        \* "idle" | "trying"
    retry_count,       \* attempts already consumed in the current live turn
    fail_count,        \* persistent turn failures toward crash threshold
    restart_count      \* restart attempts already consumed

vars == <<provider_health, keeper_phase, turn_state, retry_count,
          fail_count, restart_count>>

KeeperPhases == {"running", "failing", "crashed", "restarting", "dead"}
TurnStates == {"idle", "trying"}

TypeOK ==
    /\ provider_health \in [P -> {"healthy", "unhealthy"}]
    /\ keeper_phase \in KeeperPhases
    /\ turn_state \in TurnStates
    /\ retry_count \in 0..MaxRetries
    /\ fail_count \in 0..MaxFailures
    /\ restart_count \in 0..MaxRestarts

SomeProviderHealthy == \E p \in P : provider_health[p] = "healthy"

Init ==
    /\ provider_health = [p \in P |-> "healthy"]
    /\ keeper_phase = "running"
    /\ turn_state = "idle"
    /\ retry_count = 0
    /\ fail_count = 0
    /\ restart_count = 0

\* ---- Environment --------------------------------------------------------

ProviderFail(p) ==
    /\ provider_health[p] = "healthy"
    /\ provider_health' = [provider_health EXCEPT ![p] = "unhealthy"]
    /\ UNCHANGED <<keeper_phase, turn_state, retry_count, fail_count, restart_count>>

ProviderRecover(p) ==
    /\ provider_health[p] = "unhealthy"
    /\ provider_health' = [provider_health EXCEPT ![p] = "healthy"]
    /\ UNCHANGED <<keeper_phase, turn_state, retry_count, fail_count, restart_count>>

\* ---- Keeper-facing cascade contract ------------------------------------

StartTurn ==
    /\ keeper_phase \in {"running", "failing"}
    /\ turn_state = "idle"
    /\ turn_state' = "trying"
    /\ retry_count' = 0
    /\ UNCHANGED <<provider_health, keeper_phase, fail_count, restart_count>>

CascadeSucceeds ==
    /\ keeper_phase \in {"running", "failing"}
    /\ turn_state = "trying"
    /\ SomeProviderHealthy
    /\ keeper_phase' = "running"
    /\ turn_state' = "idle"
    /\ retry_count' = 0
    /\ fail_count' = 0
    /\ UNCHANGED <<provider_health, restart_count>>

CascadeRetry ==
    /\ keeper_phase \in {"running", "failing"}
    /\ turn_state = "trying"
    /\ ~SomeProviderHealthy
    /\ retry_count < MaxRetries
    /\ retry_count' = retry_count + 1
    /\ UNCHANGED <<provider_health, keeper_phase, turn_state, fail_count, restart_count>>

CascadeExhaustedToFailing ==
    /\ keeper_phase \in {"running", "failing"}
    /\ turn_state = "trying"
    /\ ~SomeProviderHealthy
    /\ retry_count = MaxRetries
    /\ fail_count + 1 < MaxFailures
    /\ keeper_phase' = "failing"
    /\ turn_state' = "idle"
    /\ retry_count' = 0
    /\ fail_count' = fail_count + 1
    /\ UNCHANGED <<provider_health, restart_count>>

CascadeExhaustedToCrash ==
    /\ keeper_phase \in {"running", "failing"}
    /\ turn_state = "trying"
    /\ ~SomeProviderHealthy
    /\ retry_count = MaxRetries
    /\ fail_count + 1 >= MaxFailures
    /\ keeper_phase' = "crashed"
    /\ turn_state' = "idle"
    /\ retry_count' = 0
    /\ fail_count' = MaxFailures
    /\ UNCHANGED <<provider_health, restart_count>>

\* ---- Supervisor path ----------------------------------------------------

SupervisorRestartAttempt ==
    /\ keeper_phase = "crashed"
    /\ restart_count < MaxRestarts
    /\ keeper_phase' = "restarting"
    /\ restart_count' = restart_count + 1
    /\ UNCHANGED <<provider_health, turn_state, retry_count, fail_count>>

FiberStarted ==
    /\ keeper_phase = "restarting"
    /\ keeper_phase' = "running"
    /\ turn_state' = "idle"
    /\ retry_count' = 0
    /\ fail_count' = 0
    /\ UNCHANGED <<provider_health, restart_count>>

BudgetExhausted ==
    /\ keeper_phase = "crashed"
    /\ restart_count >= MaxRestarts
    /\ keeper_phase' = "dead"
    /\ UNCHANGED <<provider_health, turn_state, retry_count, fail_count, restart_count>>

Next ==
    \/ \E p \in P : ProviderFail(p)
    \/ \E p \in P : ProviderRecover(p)
    \/ StartTurn
    \/ CascadeSucceeds
    \/ CascadeRetry
    \/ CascadeExhaustedToFailing
    \/ CascadeExhaustedToCrash
    \/ SupervisorRestartAttempt
    \/ FiberStarted
    \/ BudgetExhausted

Fairness ==
    /\ \A p \in P : WF_vars(ProviderRecover(p))
    /\ WF_vars(StartTurn)
    /\ SF_vars(CascadeSucceeds)
    /\ WF_vars(CascadeRetry)
    /\ WF_vars(CascadeExhaustedToFailing)
    /\ WF_vars(CascadeExhaustedToCrash)
    /\ WF_vars(SupervisorRestartAttempt)
    /\ WF_vars(FiberStarted)
    /\ WF_vars(BudgetExhausted)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ---- Safety -------------------------------------------------------------

RestartBounded == restart_count <= MaxRestarts

FailCountBounded == fail_count <= MaxFailures

RetryCountBounded == retry_count <= MaxRetries

DeadRequiresNoBudget ==
    keeper_phase = "dead" => restart_count >= MaxRestarts

TurnOnlyRunsWhenActive ==
    turn_state = "trying" => keeper_phase \in {"running", "failing"}

NonActivePhasesAreIdle ==
    keeper_phase \in {"crashed", "restarting", "dead"} => turn_state = "idle"

SafetyInvariant ==
    /\ TypeOK
    /\ RestartBounded
    /\ FailCountBounded
    /\ RetryCountBounded
    /\ DeadRequiresNoBudget
    /\ TurnOnlyRunsWhenActive
    /\ NonActivePhasesAreIdle

\* ---- Liveness -----------------------------------------------------------

FailingResolves ==
    keeper_phase = "failing" ~> keeper_phase \in {"running", "dead"}

CrashedResolves ==
    keeper_phase = "crashed" ~> keeper_phase \in {"running", "dead"}

\* ---- Bug model ----------------------------------------------------------
\*
\* Without the supervisor restart path, a keeper can reach Crashed after
\* repeated cascade exhaustion and stay there forever even if providers recover.

NextBuggy ==
    \/ \E p \in P : ProviderFail(p)
    \/ \E p \in P : ProviderRecover(p)
    \/ StartTurn
    \/ CascadeSucceeds
    \/ CascadeRetry
    \/ CascadeExhaustedToFailing
    \/ CascadeExhaustedToCrash
    \/ BudgetExhausted

FairnessBuggy ==
    /\ \A p \in P : WF_vars(ProviderRecover(p))
    /\ WF_vars(StartTurn)
    /\ SF_vars(CascadeSucceeds)
    /\ WF_vars(CascadeRetry)
    /\ WF_vars(CascadeExhaustedToFailing)
    /\ WF_vars(CascadeExhaustedToCrash)
    /\ WF_vars(BudgetExhausted)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

====
