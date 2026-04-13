---- MODULE KeeperTurnScheduler ----
\* Cross-domain boundary spec: Turn completion (side-effect) x Scheduler (timer).
\*
\* Models the proactive scheduling decision in
\* keeper_world_observation.ml:unified_turn_decision and the post-turn
\* timer update in keeper_unified_turn.ml:update_metrics_from_result.
\*
\* Bug #3: scope_only_reactive turns skipped update_proactive_rt, freezing
\* the proactive cooldown timer. The keeper could never schedule a second
\* autonomous turn because proactive_last_ts was never refreshed.
\*
\* Fix: 355c13fa6 removed scope_only_reactive entirely and always updates
\* proactive_last_ts on turn completion.
\*
\* Domain boundary: keeper_unified_turn.ml (turn result side-effect) x
\*                  keeper_world_observation.ml (scheduling decision input)

EXTENDS Naturals

CONSTANTS
    MaxTime,            \* upper bound on discretized time (e.g. 8)
    CooldownSec,        \* proactive cooldown in time units (e.g. 3)
    IdleGateSec         \* idle gate in time units (e.g. 2)

ASSUME MaxTime > 0 /\ CooldownSec > 0 /\ IdleGateSec > 0

VARIABLES
    now,                    \* current time (0..MaxTime), monotonically increasing
    proactive_last_ts,      \* timestamp of last proactive timer update (0..MaxTime)
    idle_since,             \* timestamp when keeper became idle (0..MaxTime)
    turn_active,            \* TRUE if a turn is currently executing
    scope_only_reactive     \* TRUE if current/last turn had scope-only reactive trigger

vars == <<now, proactive_last_ts, idle_since, turn_active, scope_only_reactive>>

TypeOK ==
    /\ now \in 0..MaxTime
    /\ proactive_last_ts \in 0..MaxTime
    /\ idle_since \in 0..MaxTime
    /\ turn_active \in BOOLEAN
    /\ scope_only_reactive \in BOOLEAN

\* Derived predicates (match unified_turn_decision logic).
CooldownElapsed == now - proactive_last_ts >= CooldownSec
IdleGateElapsed == now - idle_since >= IdleGateSec

\* ---- Init ----

Init ==
    /\ now = 0
    /\ proactive_last_ts = 0
    /\ idle_since = 0
    /\ turn_active = FALSE
    /\ scope_only_reactive = FALSE

\* ---- Actions ----

\* Time advances (environment action). Only when no turn is active
\* (simplification: turns are instantaneous in this model, time
\* advances between turns).
TimeTick ==
    /\ now < MaxTime
    /\ ~turn_active
    /\ now' = now + 1
    /\ UNCHANGED <<proactive_last_ts, idle_since, turn_active, scope_only_reactive>>

\* Scheduled autonomous turn: keeper decides to start a proactive turn.
\* Guards: cooldown elapsed AND idle gate elapsed AND not currently in turn.
ScheduledAutonomousTurn ==
    /\ ~turn_active
    /\ CooldownElapsed
    /\ IdleGateElapsed
    /\ turn_active' = TRUE
    /\ scope_only_reactive' = FALSE
    /\ UNCHANGED <<now, proactive_last_ts, idle_since>>

\* Reactive turn triggered by external event (mentions, board events).
\* No cooldown gate required.
ReactiveTurn ==
    /\ ~turn_active
    /\ turn_active' = TRUE
    /\ scope_only_reactive' = FALSE
    /\ UNCHANGED <<now, proactive_last_ts, idle_since>>

\* Scope-only reactive turn: pending_scope_messages present but no
\* mentions or board events. This is the channel that caused Bug #3.
ScopeOnlyReactiveTurn ==
    /\ ~turn_active
    /\ turn_active' = TRUE
    /\ scope_only_reactive' = TRUE
    /\ UNCHANGED <<now, proactive_last_ts, idle_since>>

\* Turn completes and updates the proactive timer.
\* Clean model: ALWAYS updates proactive_last_ts regardless of channel.
\* This matches the fix (355c13fa6).
TurnCompleteClean ==
    /\ turn_active
    /\ turn_active' = FALSE
    \* Always update the proactive timer (the fix).
    /\ proactive_last_ts' = now
    /\ idle_since' = now
    /\ UNCHANGED <<now, scope_only_reactive>>

\* ---- Clean Next ----

Next ==
    \/ TimeTick
    \/ ScheduledAutonomousTurn
    \/ ReactiveTurn
    \/ ScopeOnlyReactiveTurn
    \/ TurnCompleteClean

\* Fairness: time must eventually advance and turns must eventually complete.
Fairness ==
    /\ WF_vars(TimeTick)
    /\ WF_vars(TurnCompleteClean)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ---- Safety Invariants ----

\* S1: proactive_last_ts never exceeds current time.
TimerNotFuture ==
    proactive_last_ts <= now

\* S2: idle_since never exceeds current time.
IdleSinceNotFuture ==
    idle_since <= now

\* Combined safety
SafetyInvariant ==
    /\ TypeOK
    /\ TimerNotFuture
    /\ IdleSinceNotFuture

\* ---- Liveness Properties ----

\* L1: The proactive timer is never permanently frozen while turns happen.
\* If a turn completes, the timer is refreshed to the current time.
\* Formulated as: if a turn is active, it eventually completes and the
\* timer catches up.
TimerNeverFrozen ==
    turn_active ~> (proactive_last_ts >= idle_since)

\* ---- Bug Model: scope_only_reactive skips timer update ----
\*
\* Models the exact bug from Bug #3: when scope_only_reactive is true,
\* update_proactive_rt was set to FALSE, so proactive_last_ts was not
\* refreshed. After a scope-only turn, the timer is frozen.

TurnCompleteBuggy ==
    /\ turn_active
    /\ turn_active' = FALSE
    \* BUG: only update proactive_last_ts if NOT scope_only_reactive.
    /\ proactive_last_ts' = IF scope_only_reactive
                            THEN proactive_last_ts     \* FROZEN
                            ELSE now
    /\ idle_since' = now
    /\ UNCHANGED <<now, scope_only_reactive>>

NextBuggy ==
    \/ TimeTick
    \/ ScheduledAutonomousTurn
    \/ ReactiveTurn
    \/ ScopeOnlyReactiveTurn
    \/ TurnCompleteBuggy

FairnessBuggy ==
    /\ WF_vars(TimeTick)
    /\ WF_vars(TurnCompleteBuggy)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

====
