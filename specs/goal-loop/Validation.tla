------------------------------- MODULE Validation -------------------------------
(***************************************************************************)
(* Prompt-level Verify completion validation.                               *)
(*                                                                         *)
(* The GOAL LOOP completion audit may report PASS only after the required   *)
(* Verify gate set has been observed and every required gate has passed.    *)
(***************************************************************************)

VARIABLES observed, passed, status

vars == << observed, passed, status >>

Required == {
    "unit_tests",
    "tla_prompt_spec_tierrouting",
    "post_act_log_contract"
}
StatusSet == {"BLOCKED", "FAIL", "SKIPPED", "PASS"}

TypeOK ==
    /\ observed \subseteq Required
    /\ passed \subseteq observed
    /\ status \in StatusSet

Init ==
    /\ observed = {}
    /\ passed = {}
    /\ status = "SKIPPED"

ObserveGate ==
    \E gate \in (Required \ observed):
        /\ observed' = observed \cup {gate}
        /\ passed' = passed
        /\ status' = "SKIPPED"

PassGate ==
    \E gate \in (observed \ passed):
        /\ observed' = observed
        /\ passed' = passed \cup {gate}
        /\ status' = "SKIPPED"

BlockIncomplete ==
    /\ \/ observed # Required
       \/ passed # Required
    /\ status' = "BLOCKED"
    /\ UNCHANGED << observed, passed >>

MarkPass ==
    /\ observed = Required
    /\ passed = Required
    /\ status' = "PASS"
    /\ UNCHANGED << observed, passed >>

Terminal ==
    /\ status = "PASS"
    /\ UNCHANGED vars

NextClean ==
    \/ ObserveGate
    \/ PassGate
    \/ BlockIncomplete
    \/ MarkPass
    \/ Terminal

Spec == Init /\ [][NextClean]_vars

PassRequiresComplete ==
    status = "PASS" => observed = Required

PassRequiresAllPassed ==
    status = "PASS" => passed = Required

PassedSubsetObserved ==
    passed \subseteq observed

Safety ==
    /\ TypeOK
    /\ PassRequiresComplete
    /\ PassRequiresAllPassed
    /\ PassedSubsetObserved

\* Bug model: the completion audit marks PASS while required gates are still
\* missing or not passing.
PartialMarkedPass ==
    /\ \/ observed # Required
       \/ passed # Required
    /\ status' = "PASS"
    /\ UNCHANGED << observed, passed >>

NextBuggy ==
    \/ NextClean
    \/ PartialMarkedPass

SpecBuggy == Init /\ [][NextBuggy]_vars

===============================================================================
