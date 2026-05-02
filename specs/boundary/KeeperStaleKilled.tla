---- MODULE KeeperStaleKilled ----
\* Boundary spec for keeper stale-watchdog kill -> supervisor restart
\* loop and the storm-threshold escalation that breaks it.
\*
\* Production reality (#10765, 2026-04-25 24h evidence): when a
\* persistent underlying issue (cascade dead, fd leak, provider auth
\* expiry) caused stale kills, the supervisor's [`Crashed] branch blindly
\* enqueued the keeper for restart.  The next turn re-stalled, the
\* watchdog re-killed it, and the loop continued -- 116 events in 24h,
\* a single keeper accumulating 13 sequential kills.
\*
\* Phase 2 fix (already in main): [record_stale_termination] returns a
\* window count; on reaching [escalation_threshold] the supervisor
\* persists [meta.paused = true] instead of restarting, breaking the
\* loop and forcing operator triage.
\*
\* Phase 3 fix (this PR): self-healing circuit breaker.
\* [handle_crash_auto_pause] now stores [meta.auto_resume_after_sec]
\* alongside [meta.paused = true].  [sweep_and_recover] Phase 3.5
\* reads the timestamp and clears the pause flag once the back-off
\* delay has elapsed -- no operator action required for transient
\* provider outages.  The delay doubles on each successive auto-pause
\* (exponential back-off, capped at [auto_resume_max_sec = 24h]) and
\* is reset to [None] after a successful turn.
\*
\* PR-6 typed [stale_kill_class] is orthogonal to this spec.

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Keepers,
    EscalationThreshold,
    \* Maximum back-off multiplier steps (bounds the state space).
    MaxBackoffSteps

ASSUME
    /\ Keepers # {}
    /\ EscalationThreshold \in Nat
    /\ EscalationThreshold > 0
    /\ MaxBackoffSteps \in Nat
    /\ MaxBackoffSteps > 0

VARIABLES
    keeperState,
    killCount,
    paused,
    \* autoResumeBackoff[k] = 0: no auto-resume (operator pause or healthy)
    \* autoResumeBackoff[k] = n > 0: n-th back-off step in effect
    autoResumeBackoff,
    successfulTurn

vars == << keeperState, killCount, paused, autoResumeBackoff, successfulTurn >>

KeeperPhaseSet == {"Running", "Killed"}

TypeOK ==
    /\ keeperState \in [Keepers -> KeeperPhaseSet]
    /\ killCount \in [Keepers -> Nat]
    /\ paused \in [Keepers -> BOOLEAN]
    /\ autoResumeBackoff \in [Keepers -> Nat]
    /\ successfulTurn \in [Keepers -> BOOLEAN]

Init ==
    /\ keeperState = [k \in Keepers |-> "Running"]
    /\ killCount = [k \in Keepers |-> 0]
    /\ paused = [k \in Keepers |-> FALSE]
    /\ autoResumeBackoff = [k \in Keepers |-> 0]
    /\ successfulTurn = [k \in Keepers |-> FALSE]

\* Watchdog observes a stale signal and kills the keeper fiber.
WatchdogKill(k) ==
    /\ keeperState[k] = "Running"
    /\ ~paused[k]
    /\ keeperState' = [keeperState EXCEPT ![k] = "Killed"]
    /\ killCount' = [killCount EXCEPT ![k] = @ + 1]
    /\ successfulTurn' = [successfulTurn EXCEPT ![k] = FALSE]
    /\ UNCHANGED <<paused, autoResumeBackoff>>

\* Supervisor restarts under-threshold killed keeper.
SupervisorRestartUnderThreshold(k) ==
    /\ keeperState[k] = "Killed"
    /\ ~paused[k]
    /\ killCount[k] < EscalationThreshold
    /\ keeperState' = [keeperState EXCEPT ![k] = "Running"]
    /\ UNCHANGED <<killCount, paused, autoResumeBackoff, successfulTurn>>

\* Supervisor auto-pauses on storm threshold breach.
\* Advances back-off step: 0->1, n->min(n+1, MaxBackoffSteps).
SupervisorAutoPause(k) ==
    /\ keeperState[k] = "Killed"
    /\ ~paused[k]
    /\ killCount[k] >= EscalationThreshold
    /\ paused' = [paused EXCEPT ![k] = TRUE]
    /\ autoResumeBackoff' =
           [autoResumeBackoff EXCEPT
               ![k] = IF @ = 0 THEN 1
                      ELSE IF @ < MaxBackoffSteps THEN @ + 1
                      ELSE MaxBackoffSteps]
    /\ UNCHANGED <<keeperState, killCount, successfulTurn>>

\* Phase 3 (this PR): sweep_and_recover Phase 3.5 auto-resumes the
\* keeper once the back-off timer has elapsed.
SweepAutoResume(k) ==
    /\ paused[k]
    /\ autoResumeBackoff[k] > 0
    /\ paused' = [paused EXCEPT ![k] = FALSE]
    /\ keeperState' = [keeperState EXCEPT ![k] = "Running"]
    /\ UNCHANGED <<killCount, autoResumeBackoff, successfulTurn>>

\* A successful keeper turn resets the back-off to the initial state.
\* Models [auto_resume_after_sec = None] written by run_keeper_cycle on success.
KeeperTurnSuccess(k) ==
    /\ keeperState[k] = "Running"
    /\ ~paused[k]
    /\ autoResumeBackoff' = [autoResumeBackoff EXCEPT ![k] = 0]
    /\ successfulTurn' = [successfulTurn EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<keeperState, killCount, paused>>

\* THE BUG (pre-#10765): blind restart, no threshold check.
SupervisorBlindRestart(k) ==
    /\ keeperState[k] = "Killed"
    /\ ~paused[k]
    /\ keeperState' = [keeperState EXCEPT ![k] = "Running"]
    /\ UNCHANGED <<killCount, paused, autoResumeBackoff, successfulTurn>>

Next == \E k \in Keepers :
    \/ WatchdogKill(k)
    \/ SupervisorRestartUnderThreshold(k)
    \/ SupervisorAutoPause(k)
    \/ SweepAutoResume(k)
    \/ KeeperTurnSuccess(k)

NextBuggy == \E k \in Keepers :
    \/ WatchdogKill(k)
    \/ SupervisorBlindRestart(k)

Spec == Init /\ [][Next]_vars /\ WF_vars(\E k \in Keepers : SweepAutoResume(k))
SpecBuggy == Init /\ [][NextBuggy]_vars

\* After a storm the keeper is paused OR has a back-off set OR had a
\* successful turn that cleared the back-off (issue resolved).
KillStormImpliesPaused ==
    \A k \in Keepers :
        killCount[k] > EscalationThreshold =>
            (paused[k]
             \/ keeperState[k] = "Killed"
             \/ autoResumeBackoff[k] > 0
             \/ successfulTurn[k])

PausedRequiresEscalation ==
    \A k \in Keepers :
        paused[k] => killCount[k] >= EscalationThreshold

\* Liveness: every auto-paused keeper eventually resumes.
AutoPausedEventuallyResumes ==
    \A k \in Keepers :
        paused[k] ~> ~paused[k]

Safety ==
    /\ TypeOK
    /\ KillStormImpliesPaused
    /\ PausedRequiresEscalation

\* State-space bound for the buggy spec only.
KillCountUnderBound ==
    \A k \in Keepers : killCount[k] <= 2 * EscalationThreshold

====
