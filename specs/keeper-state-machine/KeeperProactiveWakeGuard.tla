---- MODULE KeeperProactiveWakeGuard ----
EXTENDS Naturals
(***************************************************************************)
(* KeeperProactiveWakeGuard — RFC-0294 actionability invariant.            *)
(*                                                                         *)
(* Models the keeper proactive-wake decision for a level-triggered task    *)
(* signal (failed_task / orphan).  The bug: a signal whose only affordance *)
(* cannot mutate the state that produced it (Task_audit is read-only) still*)
(* drives a proactive turn, so the turn is a no-op, the signal persists,   *)
(* and the keeper re-fires every cadence — an unbounded zero-progress      *)
(* streak (the executor incident, 2026-06-21..24, 619 turns).             *)
(*                                                                         *)
(* OCaml <-> TLA+ mapping:                                                  *)
(*   spec variable               | OCaml site                              *)
(*   ----------------------------+-----------------------------------------*)
(*   failed_present              | observation.failed_task_count > 0       *)
(*   claimable_present           | observation.claimable_task_count > 0    *)
(*   FailedAffordanceCanMutate   | Keeper_agent_tool_surface               *)
(*                               |   .affordance_can_mutate Task_audit      *)
(*                               |   (= FALSE; read-only tool set)          *)
(*   proactive_fired_for_failed  | a should_run turn driven by failed_task  *)
(*   zero_progress_streak        | consecutive no-op autonomous turns       *)
(*                                                                         *)
(* The clean Next never sets proactive_fired_for_failed: R1g routes the     *)
(* failed_task signal through affordance_can_mutate (FALSE) so it does not  *)
(* contribute to has_actionable_tasks / proactive_work_signal.  The        *)
(* BugWakeOnUnactionableFailed action models the pre-R1g code path.        *)
(***************************************************************************)

VARIABLES
    failed_present,             \* an orphan task exists (GC has not reaped it)
    claimable_present,          \* a claimable task exists (Task_claim, mutating)
    proactive_fired_for_failed, \* a proactive turn was driven by failed_task
    zero_progress_streak        \* consecutive no-op autonomous turns

vars ==
    <<failed_present, claimable_present, proactive_fired_for_failed,
      zero_progress_streak>>

MaxStreak == 3

\* Task_audit is the only affordance failed_task grants, and it is read-only.
FailedAffordanceCanMutate == FALSE

TypeOK ==
    /\ failed_present \in BOOLEAN
    /\ claimable_present \in BOOLEAN
    /\ proactive_fired_for_failed \in BOOLEAN
    /\ zero_progress_streak \in 0..(MaxStreak + 1)

Init ==
    /\ failed_present = FALSE
    /\ claimable_present = FALSE
    /\ proactive_fired_for_failed = FALSE
    /\ zero_progress_streak = 0

\* World transitions (non-keeper): an orphan appears, GC reaps it, a claimable
\* task appears, a claimable task is claimed.
FailedAppears ==
    /\ failed_present' = TRUE
    /\ UNCHANGED <<claimable_present, proactive_fired_for_failed,
                   zero_progress_streak>>

GCClears ==
    /\ failed_present' = FALSE
    /\ UNCHANGED <<claimable_present, proactive_fired_for_failed,
                   zero_progress_streak>>

ClaimableAppears ==
    /\ claimable_present' = TRUE
    /\ UNCHANGED <<failed_present, proactive_fired_for_failed,
                   zero_progress_streak>>

ClaimableClaimed ==
    /\ claimable_present' = FALSE
    /\ UNCHANGED <<failed_present, proactive_fired_for_failed,
                   zero_progress_streak>>

\* A claimable task grants the mutating Task_claim affordance: the proactive
\* turn it drives makes progress and resets the no-op streak.  It never sets
\* proactive_fired_for_failed.
ClaimableDrivesTurn ==
    /\ claimable_present
    /\ zero_progress_streak' = 0
    /\ UNCHANGED <<failed_present, claimable_present, proactive_fired_for_failed>>

Next ==
    \/ FailedAppears
    \/ GCClears
    \/ ClaimableAppears
    \/ ClaimableClaimed
    \/ ClaimableDrivesTurn

Spec == Init /\ [][Next]_vars

\* R1g invariant: a keeper is never driven into a proactive turn by a signal
\* whose affordance cannot mutate (and thus clear) it.
NeverWakeWithoutMutatingAffordance ==
    proactive_fired_for_failed => FailedAffordanceCanMutate

\* R2 invariant: the no-op streak from such turns is bounded (the tombstone /
\* actionability gate keeps it from growing without limit).
NoUnboundedZeroProgressStreak ==
    zero_progress_streak <= MaxStreak

Safety ==
    /\ TypeOK
    /\ NeverWakeWithoutMutatingAffordance
    /\ NoUnboundedZeroProgressStreak

\* The pre-R1g bug: failed_task (advisory-only Task_audit) drives a proactive
\* turn that cannot clear the signal, accruing an unbounded no-op streak.
BugWakeOnUnactionableFailed ==
    /\ failed_present
    /\ ~FailedAffordanceCanMutate
    /\ proactive_fired_for_failed' = TRUE
    /\ zero_progress_streak' =
         IF zero_progress_streak < MaxStreak + 1
         THEN zero_progress_streak + 1
         ELSE zero_progress_streak
    /\ UNCHANGED <<failed_present, claimable_present>>

SpecBuggy == Init /\ [][Next \/ BugWakeOnUnactionableFailed]_vars

====
