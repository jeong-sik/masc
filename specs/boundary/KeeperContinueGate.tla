---- MODULE KeeperContinueGate ----
\* Boundary spec for ambiguous partial commit continue-gate handling.
\*
\* Runtime truth:
\*   - ambiguous partial commit pauses the keeper,
\*   - records an ambiguous failure reason,
\*   - opens a pending approval-queue entry for that keeper,
\*   - approve/edit auto-resume and clear the failure,
\*   - reject/expiry clears the queue entry but leaves the keeper paused.
\*
\* This is not a parent lifecycle phase. The queue membership is external
\* to keeper registry/meta, so the spec models a boundary predicate
\* [continue_gate_pending] rather than pretending it is a durable keeper
\* field.

EXTENDS TLC

VARIABLES
    keeper_paused,
    failure_kind,
    continue_gate_pending,
    last_resolution

vars == << keeper_paused, failure_kind, continue_gate_pending, last_resolution >>

FailureSet == {"none", "post_commit_timeout", "post_commit_failure", "ordinary"}
ResolutionSet == {"none", "approve", "edit", "reject", "expired"}
ActionSet == {
    "OpenContinueGateTimeout",
    "OpenContinueGateFailure",
    "OrdinaryFailure",
    "ClearOrdinaryFailure",
    "ApproveGate",
    "EditGate",
    "RejectGate",
    "ExpireGate"
}
InvariantSet == {
    "PendingGateRequiresAmbiguousFailure",
    "ApprovedResolutionClearsFailure",
    "RejectedResolutionKeepsKeeperPaused",
    "OrdinaryFailureNeverOpensGate"
}

TypeOK ==
    /\ keeper_paused \in BOOLEAN
    /\ failure_kind \in FailureSet
    /\ continue_gate_pending \in BOOLEAN
    /\ last_resolution \in ResolutionSet

Init ==
    /\ keeper_paused = FALSE
    /\ failure_kind = "none"
    /\ continue_gate_pending = FALSE
    /\ last_resolution = "none"

OpenContinueGateTimeout ==
    /\ failure_kind = "none"
    /\ ~continue_gate_pending
    /\ keeper_paused' = TRUE
    /\ failure_kind' = "post_commit_timeout"
    /\ continue_gate_pending' = TRUE
    /\ last_resolution' = "none"

OpenContinueGateFailure ==
    /\ failure_kind = "none"
    /\ ~continue_gate_pending
    /\ keeper_paused' = TRUE
    /\ failure_kind' = "post_commit_failure"
    /\ continue_gate_pending' = TRUE
    /\ last_resolution' = "none"

OrdinaryFailure ==
    /\ failure_kind = "none"
    /\ ~continue_gate_pending
    /\ keeper_paused' = FALSE
    /\ failure_kind' = "ordinary"
    /\ continue_gate_pending' = FALSE
    /\ last_resolution' = "none"

ClearOrdinaryFailure ==
    /\ failure_kind = "ordinary"
    /\ ~continue_gate_pending
    /\ keeper_paused' = FALSE
    /\ failure_kind' = "none"
    /\ continue_gate_pending' = FALSE
    /\ last_resolution' = "none"

ApproveGate ==
    /\ continue_gate_pending
    /\ failure_kind \in {"post_commit_timeout", "post_commit_failure"}
    /\ keeper_paused' = FALSE
    /\ failure_kind' = "none"
    /\ continue_gate_pending' = FALSE
    /\ last_resolution' = "approve"

EditGate ==
    /\ continue_gate_pending
    /\ failure_kind \in {"post_commit_timeout", "post_commit_failure"}
    /\ keeper_paused' = FALSE
    /\ failure_kind' = "none"
    /\ continue_gate_pending' = FALSE
    /\ last_resolution' = "edit"

RejectGate ==
    /\ continue_gate_pending
    /\ failure_kind \in {"post_commit_timeout", "post_commit_failure"}
    /\ keeper_paused' = TRUE
    /\ UNCHANGED failure_kind
    /\ continue_gate_pending' = FALSE
    /\ last_resolution' = "reject"

ExpireGate ==
    /\ continue_gate_pending
    /\ failure_kind \in {"post_commit_timeout", "post_commit_failure"}
    /\ keeper_paused' = TRUE
    /\ UNCHANGED failure_kind
    /\ continue_gate_pending' = FALSE
    /\ last_resolution' = "expired"

Next ==
    \/ OpenContinueGateTimeout
    \/ OpenContinueGateFailure
    \/ OrdinaryFailure
    \/ ClearOrdinaryFailure
    \/ ApproveGate
    \/ EditGate
    \/ RejectGate
    \/ ExpireGate

Fairness ==
    /\ WF_vars(ClearOrdinaryFailure)
    /\ WF_vars(ApproveGate)
    /\ WF_vars(EditGate)
    /\ WF_vars(RejectGate)
    /\ WF_vars(ExpireGate)

Spec == Init /\ [][Next]_vars /\ Fairness

PendingGateRequiresAmbiguousFailure ==
    continue_gate_pending =>
        /\ keeper_paused
        /\ failure_kind \in {"post_commit_timeout", "post_commit_failure"}

ApprovedResolutionClearsFailure ==
    last_resolution \in {"approve", "edit"} =>
        /\ ~keeper_paused
        /\ failure_kind = "none"
        /\ ~continue_gate_pending

RejectedResolutionKeepsKeeperPaused ==
    last_resolution \in {"reject", "expired"} =>
        /\ keeper_paused
        /\ failure_kind \in {"post_commit_timeout", "post_commit_failure"}
        /\ ~continue_gate_pending

OrdinaryFailureNeverOpensGate ==
    failure_kind = "ordinary" => ~continue_gate_pending

Safety ==
    /\ TypeOK
    /\ PendingGateRequiresAmbiguousFailure
    /\ ApprovedResolutionClearsFailure
    /\ RejectedResolutionKeepsKeeperPaused
    /\ OrdinaryFailureNeverOpensGate

PendingEventuallyResolves ==
    continue_gate_pending ~> ~continue_gate_pending

ApproveGateBuggy ==
    /\ continue_gate_pending
    /\ failure_kind \in {"post_commit_timeout", "post_commit_failure"}
    /\ keeper_paused' = FALSE
    /\ UNCHANGED failure_kind
    /\ continue_gate_pending' = FALSE
    /\ last_resolution' = "approve"

EditGateBuggy ==
    /\ continue_gate_pending
    /\ failure_kind \in {"post_commit_timeout", "post_commit_failure"}
    /\ keeper_paused' = FALSE
    /\ UNCHANGED failure_kind
    /\ continue_gate_pending' = FALSE
    /\ last_resolution' = "edit"

NextBuggy ==
    \/ OpenContinueGateTimeout
    \/ OpenContinueGateFailure
    \/ OrdinaryFailure
    \/ ClearOrdinaryFailure
    \/ ApproveGateBuggy
    \/ EditGateBuggy
    \/ RejectGate
    \/ ExpireGate

FairnessBuggy ==
    /\ WF_vars(ClearOrdinaryFailure)
    /\ WF_vars(ApproveGateBuggy)
    /\ WF_vars(EditGateBuggy)
    /\ WF_vars(RejectGate)
    /\ WF_vars(ExpireGate)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

====
