------------------------------ MODULE TierRouting ------------------------------
(***************************************************************************)
(* Prompt-level Verify gate routing for TLA evidence.                       *)
(*                                                                         *)
(* The production Verify pipeline maps each exact prompt TLA filename into *)
(* one gate status. A missing spec, failed TLC result, or unrun TLC result  *)
(* must never be routed as PASS.                                            *)
(***************************************************************************)

VARIABLES evidence, routed_status

vars == << evidence, routed_status >>

EvidenceSet == {"none", "missing", "failed", "unrun", "ready"}
StatusSet == {"BLOCKED", "FAIL", "SKIPPED", "PASS"}

TypeOK ==
    /\ evidence \in EvidenceSet
    /\ routed_status \in StatusSet

Init ==
    /\ evidence = "none"
    /\ routed_status = "SKIPPED"

ObserveMissing ==
    /\ evidence = "none"
    /\ evidence' = "missing"
    /\ routed_status' = "BLOCKED"

ObserveFailed ==
    /\ evidence = "none"
    /\ evidence' = "failed"
    /\ routed_status' = "FAIL"

ObserveUnrun ==
    /\ evidence = "none"
    /\ evidence' = "unrun"
    /\ routed_status' = "SKIPPED"

ObserveReady ==
    /\ evidence = "none"
    /\ evidence' = "ready"
    /\ routed_status' = "PASS"

Terminal ==
    /\ evidence # "none"
    /\ UNCHANGED vars

NextClean ==
    \/ ObserveMissing
    \/ ObserveFailed
    \/ ObserveUnrun
    \/ ObserveReady
    \/ Terminal

Spec == Init /\ [][NextClean]_vars

MissingNeverPass ==
    evidence = "missing" => routed_status # "PASS"

FailedNeverPass ==
    evidence = "failed" => routed_status # "PASS"

UnrunNeverPass ==
    evidence = "unrun" => routed_status # "PASS"

ReadyPasses ==
    evidence = "ready" => routed_status = "PASS"

Safety ==
    /\ TypeOK
    /\ MissingNeverPass
    /\ FailedNeverPass
    /\ UnrunNeverPass
    /\ ReadyPasses

\* Bug model: a missing prompt spec is incorrectly treated as passing.
MissingMarkedPass ==
    /\ evidence = "none"
    /\ evidence' = "missing"
    /\ routed_status' = "PASS"

NextBuggy ==
    \/ NextClean
    \/ MissingMarkedPass

SpecBuggy == Init /\ [][NextBuggy]_vars

===============================================================================
