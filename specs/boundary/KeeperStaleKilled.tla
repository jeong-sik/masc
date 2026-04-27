---- MODULE KeeperStaleKilled ----
\* Boundary spec for keeper stale-watchdog kill -> supervisor restart
\* loop and the storm-threshold escalation that breaks it.
\*
\* Production reality (#10765, 2026-04-25 24h evidence): when a
\* persistent underlying issue (cascade dead, fd leak, provider auth
\* expiry) caused stale kills, the supervisor's [`Crashed] branch blindly
\* enqueued the keeper for restart.  The next turn re-stalled, the
\* watchdog re-killed it, and the loop continued — 116 events in 24h,
\* a single keeper accumulating 13 sequential kills.
\*
\* Phase 2 fix (already in main): [record_stale_termination] returns a
\* window count; on reaching [escalation_threshold] the supervisor
\* persists [meta.paused = true] instead of restarting, breaking the
\* loop and forcing operator triage.
\*
\* Phase B PR-8 plan section 8 footer:
\*   "이 패턴을 EmptyToolUniverse, ContractViolated, StaleKilled 에도
\*    동일하게 적용 (Phase B PR-8)."
\*
\* This spec lands the StaleKilled part — proves the storm threshold
\* is the necessary condition for terminating the restart loop.  The
\* clean Spec includes the threshold check and converges to a stopped
\* state; the buggy SpecBuggy omits the check and produces an unbounded
\* restart trace.
\*
\* PR-6 typed [stale_kill_class] (Idle_turn / In_turn_hung /
\* Noop_failure_loop) is orthogonal to this spec — it labels *which*
\* kill cause fired, while this spec models *what to do* after N kills.
\*
\* Pattern (clean Spec + buggy SpecBuggy gated by a separate Bug action)
\* matches KeeperTurnTerminal, KeeperEmptyToolUniverse,
\* KeeperContractViolated, and KeeperContinueGate.

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Keepers,
    EscalationThreshold

ASSUME
    /\ Keepers # {}
    /\ EscalationThreshold \in Nat
    /\ EscalationThreshold > 0

VARIABLES
    keeperState,
    killCount,
    paused

vars == << keeperState, killCount, paused >>

KeeperPhaseSet == {"Running", "Killed"}

TypeOK ==
    /\ keeperState \in [Keepers -> KeeperPhaseSet]
    /\ killCount \in [Keepers -> Nat]
    /\ paused \in [Keepers -> BOOLEAN]

Init ==
    /\ keeperState = [k \in Keepers |-> "Running"]
    /\ killCount = [k \in Keepers |-> 0]
    /\ paused = [k \in Keepers |-> FALSE]

\* Watchdog observes a stale signal and kills the keeper fiber.
\* killCount increments; supervisor will decide what to do next.
WatchdogKill(k) ==
    /\ keeperState[k] = "Running"
    /\ ~paused[k]
    /\ keeperState' = [keeperState EXCEPT ![k] = "Killed"]
    /\ killCount' = [killCount EXCEPT ![k] = @ + 1]
    /\ UNCHANGED paused

\* Supervisor sees a Killed keeper and the storm threshold is NOT
\* breached -> restart.  This is the production-correct path when
\* the underlying issue is transient.
SupervisorRestartUnderThreshold(k) ==
    /\ keeperState[k] = "Killed"
    /\ ~paused[k]
    /\ killCount[k] < EscalationThreshold
    /\ keeperState' = [keeperState EXCEPT ![k] = "Running"]
    /\ UNCHANGED <<killCount, paused>>

\* Supervisor sees a Killed keeper AND the storm threshold has been
\* breached -> auto-pause instead of restarting.  This is the Phase 2
\* (#10765) escalation that breaks the restart loop.
SupervisorAutoPause(k) ==
    /\ keeperState[k] = "Killed"
    /\ ~paused[k]
    /\ killCount[k] >= EscalationThreshold
    /\ paused' = [paused EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<keeperState, killCount>>

\* THE BUG (pre-#10765 supervisor): blindly restart any Killed keeper
\* regardless of kill count.  Combined with [WatchdogKill] this produces
\* an unbounded restart loop because the underlying root cause persists
\* across restarts.
SupervisorBlindRestart(k) ==
    /\ keeperState[k] = "Killed"
    /\ ~paused[k]
    /\ keeperState' = [keeperState EXCEPT ![k] = "Running"]
    /\ UNCHANGED <<killCount, paused>>

\* Clean Next: post-#10765 supervisor.  After threshold, the keeper
\* lands in [paused = TRUE] and stays there until an operator resumes.
Next == \E k \in Keepers :
    \/ WatchdogKill(k)
    \/ SupervisorRestartUnderThreshold(k)
    \/ SupervisorAutoPause(k)

\* Buggy Next: pre-#10765 supervisor.  No threshold check.  Restart
\* loop is reachable.
NextBuggy == \E k \in Keepers :
    \/ WatchdogKill(k)
    \/ SupervisorBlindRestart(k)

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* Safety: if a keeper has been killed more than [EscalationThreshold]
\* times, it must be paused (not actively running).  Clean Spec respects
\* this because the only path past threshold is [SupervisorAutoPause].
\* Buggy Spec violates it because [SupervisorBlindRestart] returns the
\* keeper to Running with no upper bound on killCount.
KillStormImpliesPaused ==
    \A k \in Keepers :
        killCount[k] > EscalationThreshold =>
            (paused[k] \/ keeperState[k] = "Killed")

\* Auxiliary: a paused keeper has had at least [EscalationThreshold]
\* kills.  Holds in Clean Spec.
PausedRequiresEscalation ==
    \A k \in Keepers :
        paused[k] => killCount[k] >= EscalationThreshold

Safety ==
    /\ TypeOK
    /\ KillStormImpliesPaused
    /\ PausedRequiresEscalation

\* State-space bound for the buggy spec only — the blind restart loop
\* is otherwise infinite.  Used as CONSTRAINT in the buggy cfg; the
\* clean cfg does not need it because SupervisorAutoPause halts every
\* trace in finitely many steps.  The bug is detected well below this
\* bound (typically at killCount = EscalationThreshold + 1).
KillCountUnderBound ==
    \A k \in Keepers : killCount[k] <= 2 * EscalationThreshold

====
