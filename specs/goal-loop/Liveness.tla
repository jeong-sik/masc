------------------------------- MODULE Liveness --------------------------------
(***************************************************************************)
(* Prompt-level Verify liveness for supplied TLA evidence.                  *)
(*                                                                         *)
(* Once TLC evidence for a prompt spec is supplied, the gate cannot remain  *)
(* indefinitely unresolved. A PASS result also requires supplied evidence.  *)
(***************************************************************************)

VARIABLES phase, evidence_available, result_status

vars == << phase, evidence_available, result_status >>

PhaseSet == {"unobserved", "available", "resolved"}
StatusSet == {"SKIPPED", "PASS"}

TypeOK ==
    /\ phase \in PhaseSet
    /\ evidence_available \in BOOLEAN
    /\ result_status \in StatusSet

Init ==
    /\ phase = "unobserved"
    /\ evidence_available = FALSE
    /\ result_status = "SKIPPED"

WaitForEvidence ==
    /\ phase = "unobserved"
    /\ UNCHANGED vars

SupplyEvidence ==
    /\ phase = "unobserved"
    /\ phase' = "available"
    /\ evidence_available' = TRUE
    /\ result_status' = "SKIPPED"

MarkPass ==
    /\ phase = "available"
    /\ evidence_available
    /\ phase' = "resolved"
    /\ result_status' = "PASS"
    /\ UNCHANGED evidence_available

Resolved ==
    /\ phase = "resolved"
    /\ UNCHANGED vars

NextClean ==
    \/ WaitForEvidence
    \/ SupplyEvidence
    \/ MarkPass
    \/ Resolved

Spec == Init /\ [][NextClean]_vars /\ WF_vars(MarkPass)

PassRequiresEvidence ==
    result_status = "PASS" =>
        /\ evidence_available
        /\ phase = "resolved"

EvidenceEventuallyPasses ==
    [](evidence_available => <> (result_status = "PASS"))

Safety ==
    /\ TypeOK
    /\ PassRequiresEvidence

\* Bug model: PASS is emitted even though no TLC evidence was supplied.
PassWithoutEvidence ==
    /\ phase = "unobserved"
    /\ phase' = "resolved"
    /\ evidence_available' = FALSE
    /\ result_status' = "PASS"

NextBuggy ==
    \/ NextClean
    \/ PassWithoutEvidence

SpecBuggy == Init /\ [][NextBuggy]_vars

===============================================================================
