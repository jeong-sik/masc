---------------------------- MODULE KeeperHitlDeferred ----------------------------
\* Request-local, nonblocking HITL delivery for one Keeper lane.
\*
\* Authorization is request-local and non-hierarchical. Submit returns Deferred
\* immediately. A later resolution wakes only the originating lane, unrelated
\* lanes remain able to progress, and the resolution can be consumed once.

EXTENDS Naturals

CONSTANT MaxProgress

ASSUME MaxProgressBound == MaxProgress \in Nat /\ MaxProgress >= 1

VARIABLES
    request_phase,
    submit_result,
    submitter_blocked,
    wake_target,
    consume_count,
    origin_progress,
    other_progress

vars ==
    << request_phase,
       submit_result,
       submitter_blocked,
       wake_target,
       consume_count,
       origin_progress,
       other_progress >>

PhaseSet == {"absent", "pending", "resolved", "consumed"}
SubmitResultSet == {"none", "deferred"}
WakeTargetSet == {"none", "origin-lane", "other-lane"}

TypeOK ==
    /\ request_phase \in PhaseSet
    /\ submit_result \in SubmitResultSet
    /\ submitter_blocked \in BOOLEAN
    /\ wake_target \in WakeTargetSet
    /\ consume_count \in 0..2
    /\ origin_progress \in 0..MaxProgress
    /\ other_progress \in 0..MaxProgress

Init ==
    /\ request_phase = "absent"
    /\ submit_result = "none"
    /\ submitter_blocked = FALSE
    /\ wake_target = "none"
    /\ consume_count = 0
    /\ origin_progress = 0
    /\ other_progress = 0

SubmitDeferred ==
    /\ request_phase = "absent"
    /\ request_phase' = "pending"
    /\ submit_result' = "deferred"
    /\ submitter_blocked' = FALSE
    /\ UNCHANGED
          << wake_target,
             consume_count,
             origin_progress,
             other_progress >>

ResolveForOrigin ==
    /\ request_phase = "pending"
    /\ request_phase' = "resolved"
    /\ wake_target' = "origin-lane"
    /\ UNCHANGED
          << submit_result,
             submitter_blocked,
             consume_count,
             origin_progress,
             other_progress >>

ConsumeOnce ==
    /\ request_phase = "resolved"
    /\ consume_count = 0
    /\ request_phase' = "consumed"
    /\ wake_target' = "none"
    /\ consume_count' = 1
    /\ UNCHANGED
          << submit_result,
             submitter_blocked,
             origin_progress,
             other_progress >>

ProgressOrigin ==
    /\ origin_progress < MaxProgress
    /\ origin_progress' = origin_progress + 1
    /\ UNCHANGED
          << request_phase,
             submit_result,
             submitter_blocked,
             wake_target,
             consume_count,
             other_progress >>

ProgressOther ==
    /\ other_progress < MaxProgress
    /\ other_progress' = other_progress + 1
    /\ UNCHANGED
          << request_phase,
             submit_result,
             submitter_blocked,
             wake_target,
             consume_count,
             origin_progress >>

Done ==
    /\ request_phase = "consumed"
    /\ origin_progress = MaxProgress
    /\ other_progress = MaxProgress
    /\ UNCHANGED vars

Next ==
    \/ SubmitDeferred
    \/ ResolveForOrigin
    \/ ConsumeOnce
    \/ ProgressOrigin
    \/ ProgressOther
    \/ Done

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(ProgressOther)
    /\ WF_vars(ConsumeOnce)

DeferredImmediately ==
    request_phase # "absent" =>
        /\ submit_result = "deferred"
        /\ submitter_blocked = FALSE

ResolutionWakesOriginOnly ==
    wake_target \in {"none", "origin-lane"}

ResolutionConsumedAtMostOnce ==
    consume_count <= 1

UnrelatedLaneKeepsProgressing ==
    (request_phase = "pending") ~> (other_progress = MaxProgress)

ResolutionEventuallyConsumed ==
    (request_phase = "resolved") ~> (request_phase = "consumed")

Safety ==
    /\ TypeOK
    /\ DeferredImmediately
    /\ ResolutionWakesOriginOnly
    /\ ResolutionConsumedAtMostOnce

SubmitBlocking ==
    /\ request_phase = "absent"
    /\ request_phase' = "pending"
    /\ submit_result' = "none"
    /\ submitter_blocked' = TRUE
    /\ UNCHANGED
          << wake_target,
             consume_count,
             origin_progress,
             other_progress >>

NextBlockingBuggy == Next \/ SubmitBlocking
SpecBlockingBuggy == Init /\ [][NextBlockingBuggy]_vars

ResolveForOtherLane ==
    /\ request_phase = "pending"
    /\ request_phase' = "resolved"
    /\ wake_target' = "other-lane"
    /\ UNCHANGED
          << submit_result,
             submitter_blocked,
             consume_count,
             origin_progress,
             other_progress >>

NextWakeBuggy == Next \/ ResolveForOtherLane
SpecWakeBuggy == Init /\ [][NextWakeBuggy]_vars

ConsumeAgain ==
    /\ request_phase = "consumed"
    /\ consume_count = 1
    /\ consume_count' = 2
    /\ UNCHANGED
          << request_phase,
             submit_result,
             submitter_blocked,
             wake_target,
             origin_progress,
             other_progress >>

NextConsumeBuggy == Next \/ ConsumeAgain
SpecConsumeBuggy == Init /\ [][NextConsumeBuggy]_vars

=============================================================================
