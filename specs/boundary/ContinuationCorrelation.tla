--------------------------- MODULE ContinuationCorrelation ---------------------------
\* A continuation restores the exact Keeper lane and Channel correlation needed
\* to continue dialogue. That provenance is data; it is never a decision for a
\* later external operation.
\*
\* Clean model:
\*   - the resumed turn preserves its originating lane and Channel
\*   - an operation executes only after a Gate decision bound to that exact input
\*
\* Bug models:
\*   - ResumeWrongCorrelation changes lane/Channel while resuming
\*   - ExecuteFromContinuationProvenance treats resume provenance as a Gate decision

EXTENDS TLC

VARIABLES
    phase,
    origin_lane,
    active_lane,
    origin_channel,
    active_channel,
    presented_operation,
    decided_request,
    executed_request

vars ==
    << phase,
       origin_lane,
       active_lane,
       origin_channel,
       active_channel,
       presented_operation,
       decided_request,
       executed_request >>

PhaseSet == {"idle", "resumed", "requested", "decided", "executed", "done"}
LaneSet == {"lane-a", "lane-b"}
ChannelSet == {"channel-a", "channel-b"}
OperationSet == {"none", "operation-a"}

TypeOK ==
    /\ phase \in PhaseSet
    /\ origin_lane \in LaneSet
    /\ active_lane \in LaneSet
    /\ origin_channel \in ChannelSet
    /\ active_channel \in ChannelSet
    /\ presented_operation \in OperationSet
    /\ decided_request \in OperationSet
    /\ executed_request \in OperationSet

Init ==
    /\ phase = "idle"
    /\ origin_lane = "lane-a"
    /\ active_lane = origin_lane
    /\ origin_channel = "channel-a"
    /\ active_channel = origin_channel
    /\ presented_operation = "none"
    /\ decided_request = "none"
    /\ executed_request = "none"

Resume ==
    /\ phase = "idle"
    /\ phase' = "resumed"
    /\ active_lane' = origin_lane
    /\ active_channel' = origin_channel
    /\ presented_operation' = "none"
    /\ decided_request' = "none"
    /\ executed_request' = "none"
    /\ UNCHANGED <<origin_lane, origin_channel>>

PresentOperation ==
    /\ phase = "resumed"
    /\ phase' = "requested"
    /\ presented_operation' = "operation-a"
    /\ UNCHANGED
          << origin_lane,
             active_lane,
             origin_channel,
             active_channel,
             decided_request,
             executed_request >>

DecideOperation ==
    /\ phase = "requested"
    /\ presented_operation # "none"
    /\ phase' = "decided"
    /\ decided_request' = presented_operation
    /\ UNCHANGED
          << origin_lane,
             active_lane,
             origin_channel,
             active_channel,
             presented_operation,
             executed_request >>

ExecuteOperation ==
    /\ phase = "decided"
    /\ presented_operation # "none"
    /\ decided_request = presented_operation
    /\ phase' = "executed"
    /\ executed_request' = presented_operation
    /\ UNCHANGED
          << origin_lane,
             active_lane,
             origin_channel,
             active_channel,
             presented_operation,
             decided_request >>

Finish ==
    /\ phase \in {"resumed", "requested", "decided", "executed"}
    /\ phase' = "done"
    /\ UNCHANGED
          << origin_lane,
             active_lane,
             origin_channel,
             active_channel,
             presented_operation,
             decided_request,
             executed_request >>

Reset ==
    /\ phase = "done"
    /\ phase' = "idle"
    /\ active_lane' = origin_lane
    /\ active_channel' = origin_channel
    /\ presented_operation' = "none"
    /\ decided_request' = "none"
    /\ executed_request' = "none"
    /\ UNCHANGED <<origin_lane, origin_channel>>

Next ==
    \/ Resume
    \/ PresentOperation
    \/ DecideOperation
    \/ ExecuteOperation
    \/ Finish
    \/ Reset

Spec == Init /\ [][Next]_vars

ContinuationPreservesCorrelation ==
    /\ active_lane = origin_lane
    /\ active_channel = origin_channel

ContinuationNeverAuthorizesOperation ==
    \/ executed_request = "none"
    \/ /\ executed_request = presented_operation
       /\ decided_request = presented_operation

Safety ==
    /\ TypeOK
    /\ ContinuationPreservesCorrelation
    /\ ContinuationNeverAuthorizesOperation

ResumeWrongCorrelation ==
    /\ phase = "idle"
    /\ phase' = "resumed"
    /\ active_lane' = "lane-b"
    /\ active_channel' = "channel-b"
    /\ presented_operation' = "none"
    /\ decided_request' = "none"
    /\ executed_request' = "none"
    /\ UNCHANGED <<origin_lane, origin_channel>>

NextCorrelationBuggy ==
    \/ ResumeWrongCorrelation
    \/ PresentOperation
    \/ DecideOperation
    \/ ExecuteOperation
    \/ Finish
    \/ Reset

SpecCorrelationBuggy == Init /\ [][NextCorrelationBuggy]_vars

ExecuteFromContinuationProvenance ==
    /\ phase = "resumed"
    /\ phase' = "executed"
    /\ presented_operation' = "operation-a"
    /\ decided_request' = "none"
    /\ executed_request' = "effect-a"
    /\ UNCHANGED
          << origin_lane,
             active_lane,
             origin_channel,
             active_channel >>

NextDecisionBuggy ==
    \/ Resume
    \/ ExecuteFromContinuationProvenance
    \/ Finish
    \/ Reset

SpecDecisionBuggy == Init /\ [][NextDecisionBuggy]_vars

=============================================================================
