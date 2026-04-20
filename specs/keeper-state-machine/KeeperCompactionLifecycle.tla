---- MODULE KeeperCompactionLifecycle ----
\* Keeper-facing compaction lifecycle projection.
\*
\* This spec models the runtime truth that spans:
\*   - parent phase derivation from overflow/compaction conditions,
\*   - per-turn retry posture preserved across overflow recovery,
\*   - registry compaction_stage updates.
\*
\* It is intentionally a projection, not a full copy of post-turn policy.
\* The runtime does not expose a compaction retry counter; only the
\* boolean retry-exhausted latch is modeled here.
\*
\* OCaml ↔ TLA+ mapping (see also #8642 family — KeeperContextLifecycle,
\* KeeperCoreTriad, KeeperGenerationLineage, KeeperReconcileLiveness):
\*
\*   spec phase  | OCaml Keeper_state_machine.phase  | source of truth
\*   ------------+-----------------------------------+----------------
\*   "Running"   | Running                           | lib/keeper/keeper_state_machine.ml:8
\*   "Overflowed"| Overflowed                        | lib/keeper/keeper_state_machine.ml:10
\*   "Compacting"| Compacting                        | lib/keeper/keeper_state_machine.ml:11
\*   "Paused"    | Paused                            | lib/keeper/keeper_state_machine.ml:14
\*
\* Out-of-scope OCaml phases (intentional projection — not modelled here):
\*   Offline, Failing, HandingOff, Draining, Crashed
\*
\* The 4-phase projection captures only the overflow/compaction recovery
\* loop. Other lifecycle transitions (boot/shutdown/handoff/crash) live in
\* sibling specs (e.g. KeeperContextLifecycle for boot/handoff/draining,
\* KeeperCircuitBreaker for crash/failing).
\*
\* Out-of-scope subsidiary variants (issue #8957 — also intentional
\* projection, but flagged so a future runtime change cannot silently
\* bypass TLC by visiting an unmodelled value):
\*
\*   variable           | OCaml runtime variants                                  | spec subset                          | excluded                  | rationale
\*   -------------------+---------------------------------------------------------+--------------------------------------+---------------------------+----------------------------------------
\*   turn_phase         | idle/prompting/executing/compacting/finalizing          | idle/prompting/executing/compacting  | finalizing                | finalizing is the post-decision settle
\*                      |                                                         |                                      |                           | window (mark_turn_finished resets to
\*                      |                                                         |                                      |                           | undecided); not observed during the
\*                      |                                                         |                                      |                           | compaction-recovery loop.
\*   decision_stage     | undecided/guard_ok/gate_rejected/tool_policy_selected   | undecided/guard_ok/tool_policy_selected | gate_rejected         | gate_rejected is owned by the policy lane
\*                      |                                                         |                                      |                           | (KeeperDecisionPipeline) and short-circuits
\*                      |                                                         |                                      |                           | the turn before the compaction-relevant
\*                      |                                                         |                                      |                           | path is reached.
\*   cascade_state      | idle/selecting/trying/done/exhausted                    | idle/trying                          | selecting/done/exhausted  | selecting is a sub-step of cascade
\*                      |                                                         |                                      |                           | attempt (modelled inside trying);
\*                      |                                                         |                                      |                           | done/exhausted are terminal states
\*                      |                                                         |                                      |                           | owned by KeeperCascadeLifecycle.
\*
\* If a future change makes one of the excluded variants reachable inside
\* the compaction lifecycle, this spec MUST be updated (extend the matching
\* *Set, update TypeOK, re-verify the existing invariants). See #8957 for
\* the maintenance contract.
\*
\* compaction_stage variant ↔ OCaml: TLA models {accumulating, compacting,
\* done}; OCaml runtime uses the same labels in
\* lib/keeper/keeper_registry.ml + lib/keeper/keeper_state_machine.ml
\* (search "compaction_stage").
\*
\* retry_exhausted boolean ↔ OCaml: latched by Compact_retry_exhausted
\* event; cleared by Compaction_completed (lib/keeper/keeper_state_machine.ml).

EXTENDS TLC

VARIABLES
    turn_live,
    ksm_phase,
    turn_phase,
    decision_stage,
    cascade_state,
    compaction_stage,
    overflow_latched,
    retry_exhausted

vars ==
    << turn_live, ksm_phase, turn_phase, decision_stage, cascade_state,
       compaction_stage, overflow_latched, retry_exhausted >>

PhaseSet      == {"Running", "Overflowed", "Compacting", "Paused"}
TurnPhaseSet  == {"idle", "prompting", "executing", "compacting"}
DecisionSet   == {"undecided", "guard_ok", "tool_policy_selected"}
CascadeSet    == {"idle", "trying"}
CompactionSet == {"accumulating", "compacting", "done"}
ActionSet     == {
    "StartTurn",
    "BeginCascadeAttempt",
    "DetectOverflow",
    "AutoCompact",
    "CompactionCompleted",
    "CompactionFailed",
    "ExhaustRetryBudget",
    "OperatorCompactRequested",
    "OperatorClearRequested",
    "FinishTurnAfterCompaction"
}
InvariantSet == {
    "CompactingAlignsAll",
    "OverflowPhasesRequireLatchedOverflow",
    "PausedRequiresRetryExhaustedOverflow",
    "DoneExcludesActiveCompaction",
    "DoneIdleTurnResetsProjection"
}

TypeOK ==
    /\ turn_live \in BOOLEAN
    /\ ksm_phase \in PhaseSet
    /\ turn_phase \in TurnPhaseSet
    /\ decision_stage \in DecisionSet
    /\ cascade_state \in CascadeSet
    /\ compaction_stage \in CompactionSet
    /\ overflow_latched \in BOOLEAN
    /\ retry_exhausted \in BOOLEAN

Init ==
    /\ turn_live = FALSE
    /\ ksm_phase = "Running"
    /\ turn_phase = "idle"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ compaction_stage = "accumulating"
    /\ overflow_latched = FALSE
    /\ retry_exhausted = FALSE

StartTurn ==
    /\ ~turn_live
    /\ ksm_phase = "Running"
    /\ turn_live' = TRUE
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ compaction_stage' = "accumulating"
    /\ overflow_latched' = FALSE
    /\ retry_exhausted' = FALSE
    /\ UNCHANGED <<ksm_phase>>

BeginCascadeAttempt ==
    /\ turn_live
    /\ ksm_phase = "Running"
    /\ turn_phase = "prompting"
    /\ cascade_state = "idle"
    /\ decision_stage \in {"undecided", "guard_ok"}
    /\ turn_phase' = "executing"
    /\ decision_stage' = "tool_policy_selected"
    /\ cascade_state' = "trying"
    /\ UNCHANGED <<turn_live, ksm_phase, compaction_stage,
                    overflow_latched, retry_exhausted>>

DetectOverflow ==
    /\ turn_live
    /\ ksm_phase = "Running"
    /\ turn_phase = "executing"
    /\ decision_stage = "tool_policy_selected"
    /\ cascade_state = "trying"
    /\ ksm_phase' = "Overflowed"
    /\ overflow_latched' = TRUE
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage, cascade_state,
                    compaction_stage, retry_exhausted>>

AutoCompact ==
    /\ turn_live
    /\ ksm_phase = "Overflowed"
    /\ overflow_latched
    /\ ksm_phase' = "Compacting"
    /\ turn_phase' = "compacting"
    /\ compaction_stage' = "compacting"
    /\ UNCHANGED <<turn_live, decision_stage, cascade_state,
                    overflow_latched, retry_exhausted>>

CompactionCompleted ==
    /\ turn_live
    /\ ksm_phase = "Compacting"
    /\ compaction_stage = "compacting"
    /\ ksm_phase' = "Running"
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "guard_ok"
    /\ cascade_state' = "idle"
    /\ compaction_stage' = "done"
    /\ overflow_latched' = FALSE
    /\ retry_exhausted' = FALSE
    /\ UNCHANGED <<turn_live>>

CompactionFailed ==
    /\ turn_live
    /\ ksm_phase = "Compacting"
    /\ compaction_stage = "compacting"
    /\ ksm_phase' = "Overflowed"
    /\ turn_phase' = "executing"
    /\ decision_stage' = "tool_policy_selected"
    /\ cascade_state' = "trying"
    /\ compaction_stage' = "accumulating"
    /\ overflow_latched' = TRUE
    /\ UNCHANGED <<turn_live, retry_exhausted>>

ExhaustRetryBudget ==
    /\ turn_live
    /\ ksm_phase = "Overflowed"
    /\ overflow_latched
    /\ ~retry_exhausted
    /\ compaction_stage = "accumulating"
    /\ ksm_phase' = "Paused"
    /\ retry_exhausted' = TRUE
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage, cascade_state,
                    compaction_stage, overflow_latched>>

OperatorCompactRequested ==
    /\ turn_live
    /\ ksm_phase = "Paused"
    /\ overflow_latched
    /\ retry_exhausted
    /\ ksm_phase' = "Compacting"
    /\ turn_phase' = "compacting"
    /\ compaction_stage' = "compacting"
    /\ retry_exhausted' = FALSE
    /\ UNCHANGED <<turn_live, decision_stage, cascade_state,
                    overflow_latched>>

OperatorClearRequested ==
    /\ ksm_phase \in {"Overflowed", "Paused"}
    /\ overflow_latched
    /\ turn_live' = FALSE
    /\ ksm_phase' = "Running"
    /\ turn_phase' = "idle"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ compaction_stage' = "accumulating"
    /\ overflow_latched' = FALSE
    /\ retry_exhausted' = FALSE

FinishTurnAfterCompaction ==
    /\ turn_live
    /\ ksm_phase = "Running"
    /\ compaction_stage = "done"
    /\ turn_live' = FALSE
    /\ turn_phase' = "idle"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ UNCHANGED <<ksm_phase, compaction_stage, overflow_latched,
                   retry_exhausted>>

Next ==
    \/ StartTurn
    \/ BeginCascadeAttempt
    \/ DetectOverflow
    \/ AutoCompact
    \/ CompactionCompleted
    \/ CompactionFailed
    \/ ExhaustRetryBudget
    \/ OperatorCompactRequested
    \/ OperatorClearRequested
    \/ FinishTurnAfterCompaction

Fairness ==
    /\ WF_vars(AutoCompact)
    /\ WF_vars(CompactionCompleted)
    /\ WF_vars(CompactionFailed)
    /\ WF_vars(ExhaustRetryBudget)
    /\ WF_vars(OperatorCompactRequested)
    /\ WF_vars(OperatorClearRequested)
    /\ WF_vars(FinishTurnAfterCompaction)

Spec == Init /\ [][Next]_vars /\ Fairness

CompactingAlignsAll ==
    compaction_stage = "compacting" =>
        /\ turn_live
        /\ ksm_phase = "Compacting"
        /\ turn_phase = "compacting"

OverflowPhasesRequireLatchedOverflow ==
    ksm_phase \in {"Overflowed", "Compacting", "Paused"} =>
        overflow_latched

PausedRequiresRetryExhaustedOverflow ==
    ksm_phase = "Paused" =>
        /\ turn_live
        /\ overflow_latched
        /\ retry_exhausted
        /\ compaction_stage = "accumulating"

DoneExcludesActiveCompaction ==
    compaction_stage = "done" =>
        /\ ksm_phase # "Compacting"
        /\ turn_phase # "compacting"

DoneIdleTurnResetsProjection ==
    compaction_stage = "done" /\ ~turn_live =>
        /\ turn_phase = "idle"
        /\ decision_stage = "undecided"
        /\ cascade_state = "idle"

Safety ==
    /\ TypeOK
    /\ CompactingAlignsAll
    /\ OverflowPhasesRequireLatchedOverflow
    /\ PausedRequiresRetryExhaustedOverflow
    /\ DoneExcludesActiveCompaction
    /\ DoneIdleTurnResetsProjection

OverflowEventuallyLeavesOverflow ==
    (ksm_phase = "Overflowed") ~> (ksm_phase /= "Overflowed")

CompactingEventuallyStops ==
    (ksm_phase = "Compacting") ~> (ksm_phase /= "Compacting")

BugCompactionDesync ==
    /\ turn_live
    /\ ksm_phase = "Running"
    /\ compaction_stage = "accumulating"
    /\ compaction_stage' = "compacting"
    /\ UNCHANGED <<turn_live, ksm_phase, turn_phase, decision_stage,
                   cascade_state, overflow_latched, retry_exhausted>>

SpecBuggy == Init /\ [][Next \/ BugCompactionDesync]_vars /\ Fairness

====
