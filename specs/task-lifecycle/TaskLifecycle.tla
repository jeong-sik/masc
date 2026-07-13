------------------------------ MODULE TaskLifecycle ------------------------------
\* Typed Task lifecycle with one semantic completion boundary.
\*
\* Task completion is not an actor-role hierarchy and does not require a
\* different Keeper to approve the assignee. A configured LLM judges
\* the concrete Task, context, and evidence. Done is reachable only after that
\* request-local verdict is Pass.
\*
\* The Claimed step remains an objective state invariant: work cannot enter
\* InProgress without first acquiring the Task.

EXTENDS Integers

VARIABLES state, configured_llm_verdict, ever_claimed

vars == <<state, configured_llm_verdict, ever_claimed>>

States ==
    {"Todo", "Claimed", "InProgress", "AwaitingVerification", "Done", "Cancelled"}
Verdicts == {"none", "pass", "fail"}

TypeOK ==
    /\ state \in States
    /\ configured_llm_verdict \in Verdicts
    /\ ever_claimed \in BOOLEAN

Init ==
    /\ state = "Todo"
    /\ configured_llm_verdict = "none"
    /\ ever_claimed = FALSE

Claim ==
    /\ state = "Todo"
    /\ state' = "Claimed"
    /\ ever_claimed' = TRUE
    /\ UNCHANGED configured_llm_verdict

Start ==
    /\ state = "Claimed"
    /\ state' = "InProgress"
    /\ UNCHANGED <<configured_llm_verdict, ever_claimed>>

SubmitForConfiguredLlmVerification ==
    /\ state = "InProgress"
    /\ state' = "AwaitingVerification"
    /\ configured_llm_verdict' = "none"
    /\ UNCHANGED ever_claimed

RecordConfiguredLlmPass ==
    /\ state = "AwaitingVerification"
    /\ configured_llm_verdict = "none"
    /\ configured_llm_verdict' = "pass"
    /\ UNCHANGED <<state, ever_claimed>>

RecordConfiguredLlmFail ==
    /\ state = "AwaitingVerification"
    /\ configured_llm_verdict = "none"
    /\ state' = "InProgress"
    /\ configured_llm_verdict' = "fail"
    /\ UNCHANGED ever_claimed

Complete ==
    /\ state = "AwaitingVerification"
    /\ configured_llm_verdict = "pass"
    /\ state' = "Done"
    /\ UNCHANGED <<configured_llm_verdict, ever_claimed>>

Cancel ==
    /\ state \in {"Todo", "Claimed", "InProgress", "AwaitingVerification"}
    /\ state' = "Cancelled"
    /\ UNCHANGED <<configured_llm_verdict, ever_claimed>>

Terminal ==
    /\ state \in {"Done", "Cancelled"}
    /\ UNCHANGED vars

NextClean ==
    \/ Claim
    \/ Start
    \/ SubmitForConfiguredLlmVerification
    \/ RecordConfiguredLlmPass
    \/ RecordConfiguredLlmFail
    \/ Complete
    \/ Cancel
    \/ Terminal

BugSkipConfiguredLlmVerification ==
    /\ state = "InProgress"
    /\ state' = "Done"
    /\ UNCHANGED <<configured_llm_verdict, ever_claimed>>

BugSkipClaim ==
    /\ state = "Todo"
    /\ state' = "InProgress"
    /\ UNCHANGED <<configured_llm_verdict, ever_claimed>>

NextBuggy ==
    \/ NextClean
    \/ BugSkipConfiguredLlmVerification
    \/ BugSkipClaim

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

DoneRequiresConfiguredLlmVerification ==
    state = "Done" => configured_llm_verdict = "pass"

InProgressRequiresClaim ==
    state \in {"InProgress", "AwaitingVerification", "Done"} => ever_claimed

Safety ==
    /\ TypeOK
    /\ DoneRequiresConfiguredLlmVerification
    /\ InProgressRequiresClaim

================================================================================
