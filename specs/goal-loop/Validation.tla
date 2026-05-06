---- MODULE Validation ----
\* Prompt-level GOAL LOOP validation aggregation contract.
\*
\* The completion audit must not report PASS unless each required evidence
\* family has passed. Missing evidence keeps the aggregate blocked, and any
\* failed evidence dominates the aggregate outcome.

EXTENDS TLC

VARIABLES unit, metrics, tla, logs, orient, final

vars == <<unit, metrics, tla, logs, orient, final>>

EvidenceSet == {"unknown", "pass", "fail"}
FinalSet == {"none", "pass", "blocked", "fail"}

AllEvidence == <<unit, metrics, tla, logs, orient>>

AllPassed == unit = "pass" /\ metrics = "pass" /\ tla = "pass" /\
             logs = "pass" /\ orient = "pass"

AnyFailed == unit = "fail" \/ metrics = "fail" \/ tla = "fail" \/
             logs = "fail" \/ orient = "fail"

AnyUnknown == unit = "unknown" \/ metrics = "unknown" \/
              tla = "unknown" \/ logs = "unknown" \/ orient = "unknown"

TypeOK ==
    /\ unit \in EvidenceSet
    /\ metrics \in EvidenceSet
    /\ tla \in EvidenceSet
    /\ logs \in EvidenceSet
    /\ orient \in EvidenceSet
    /\ final \in FinalSet

Init ==
    /\ unit = "unknown"
    /\ metrics = "unknown"
    /\ tla = "unknown"
    /\ logs = "unknown"
    /\ orient = "unknown"
    /\ final = "none"

SetUnitPass == final = "none" /\ unit = "unknown" /\ unit' = "pass" /\
    UNCHANGED <<metrics, tla, logs, orient, final>>
SetUnitFail == final = "none" /\ unit = "unknown" /\ unit' = "fail" /\
    UNCHANGED <<metrics, tla, logs, orient, final>>

SetMetricsPass == final = "none" /\ metrics = "unknown" /\ metrics' = "pass" /\
    UNCHANGED <<unit, tla, logs, orient, final>>
SetMetricsFail == final = "none" /\ metrics = "unknown" /\ metrics' = "fail" /\
    UNCHANGED <<unit, tla, logs, orient, final>>

SetTlaPass == final = "none" /\ tla = "unknown" /\ tla' = "pass" /\
    UNCHANGED <<unit, metrics, logs, orient, final>>
SetTlaFail == final = "none" /\ tla = "unknown" /\ tla' = "fail" /\
    UNCHANGED <<unit, metrics, logs, orient, final>>

SetLogsPass == final = "none" /\ logs = "unknown" /\ logs' = "pass" /\
    UNCHANGED <<unit, metrics, tla, orient, final>>
SetLogsFail == final = "none" /\ logs = "unknown" /\ logs' = "fail" /\
    UNCHANGED <<unit, metrics, tla, orient, final>>

SetOrientPass == final = "none" /\ orient = "unknown" /\ orient' = "pass" /\
    UNCHANGED <<unit, metrics, tla, logs, final>>
SetOrientFail == final = "none" /\ orient = "unknown" /\ orient' = "fail" /\
    UNCHANGED <<unit, metrics, tla, logs, final>>

FinalizePass ==
    /\ final = "none"
    /\ AllPassed
    /\ final' = "pass"
    /\ UNCHANGED <<unit, metrics, tla, logs, orient>>

FinalizeFail ==
    /\ final = "none"
    /\ AnyFailed
    /\ final' = "fail"
    /\ UNCHANGED <<unit, metrics, tla, logs, orient>>

FinalizeBlocked ==
    /\ final = "none"
    /\ ~AnyFailed
    /\ AnyUnknown
    /\ final' = "blocked"
    /\ UNCHANGED <<unit, metrics, tla, logs, orient>>

Next ==
    \/ SetUnitPass
    \/ SetUnitFail
    \/ SetMetricsPass
    \/ SetMetricsFail
    \/ SetTlaPass
    \/ SetTlaFail
    \/ SetLogsPass
    \/ SetLogsFail
    \/ SetOrientPass
    \/ SetOrientFail
    \/ FinalizePass
    \/ FinalizeFail
    \/ FinalizeBlocked

Spec == Init /\ [][Next]_vars

PassRequiresAllEvidence ==
    final = "pass" => AllPassed

FailDominates ==
    AnyFailed => final # "pass"

BlockedRequiresMissingEvidence ==
    final = "blocked" => AnyUnknown

Safety ==
    /\ TypeOK
    /\ PassRequiresAllEvidence
    /\ FailDominates
    /\ BlockedRequiresMissingEvidence
====
