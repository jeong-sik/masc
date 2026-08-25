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
\*
\* An assignee may submit again while awaiting a verdict. The submission that
\* replaces a pending one carries a new identity, which is what keeps the
\* boundary intact: a judge reads its request once and can return long after
\* the evidence was replaced, so a verdict lands only when the identity it was
\* computed against is still the one the Task carries. [submission] models that
\* identity as a counter; [verdict_for] records which submission a returned
\* verdict read.

EXTENDS Integers

\* Bounds the model. The property under check does not depend on how many
\* resubmissions are allowed, only on at least two existing.
CONSTANT MaxSubmissions

VARIABLES state, configured_llm_verdict, verdict_for, submission, ever_claimed

vars ==
    <<state, configured_llm_verdict, verdict_for, submission, ever_claimed>>

States ==
    {"Todo", "Claimed", "InProgress", "AwaitingVerification", "Done", "Cancelled"}
Verdicts == {"none", "pass", "fail"}

TypeOK ==
    /\ state \in States
    /\ configured_llm_verdict \in Verdicts
    /\ verdict_for \in 0..MaxSubmissions
    /\ submission \in 0..MaxSubmissions
    /\ ever_claimed \in BOOLEAN

Init ==
    /\ state = "Todo"
    /\ configured_llm_verdict = "none"
    /\ verdict_for = 0
    /\ submission = 0
    /\ ever_claimed = FALSE

Claim ==
    /\ state = "Todo"
    /\ state' = "Claimed"
    /\ ever_claimed' = TRUE
    /\ UNCHANGED <<configured_llm_verdict, verdict_for, submission>>

Start ==
    /\ state = "Claimed"
    /\ state' = "InProgress"
    /\ UNCHANGED <<configured_llm_verdict, verdict_for, submission, ever_claimed>>

SubmitForConfiguredLlmVerification ==
    /\ state = "InProgress"
    /\ submission < MaxSubmissions
    /\ state' = "AwaitingVerification"
    /\ submission' = submission + 1
    /\ configured_llm_verdict' = "none"
    /\ verdict_for' = 0
    /\ UNCHANGED ever_claimed

\* Supersedes the pending obligation rather than abandoning the Task. Without
\* it, Cancel is the assignee's only exit from AwaitingVerification, which
\* discards the evidence along with the Task.
ResubmitForConfiguredLlmVerification ==
    /\ state = "AwaitingVerification"
    /\ submission < MaxSubmissions
    /\ state' = "AwaitingVerification"
    /\ submission' = submission + 1
    /\ configured_llm_verdict' = "none"
    /\ verdict_for' = 0
    /\ UNCHANGED ever_claimed

\* A judge woken for any submission may return, including one whose evidence
\* has since been superseded. Returning is not landing: see Apply* below.
ConfiguredLlmReturnsVerdict ==
    /\ state = "AwaitingVerification"
    /\ configured_llm_verdict = "none"
    /\ \E s \in 1..submission, v \in {"pass", "fail"} :
         /\ configured_llm_verdict' = v
         /\ verdict_for' = s
    /\ UNCHANGED <<state, submission, ever_claimed>>

\* The identity gate. A verdict computed against a superseded submission is
\* refused here, mirroring [Verification_id_mismatch].
DiscardSupersededVerdict ==
    /\ state = "AwaitingVerification"
    /\ configured_llm_verdict # "none"
    /\ verdict_for # submission
    /\ configured_llm_verdict' = "none"
    /\ verdict_for' = 0
    /\ UNCHANGED <<state, submission, ever_claimed>>

ApplyConfiguredLlmFail ==
    /\ state = "AwaitingVerification"
    /\ configured_llm_verdict = "fail"
    /\ verdict_for = submission
    /\ state' = "InProgress"
    /\ UNCHANGED <<configured_llm_verdict, verdict_for, submission, ever_claimed>>

Complete ==
    /\ state = "AwaitingVerification"
    /\ configured_llm_verdict = "pass"
    /\ verdict_for = submission
    /\ state' = "Done"
    /\ UNCHANGED <<configured_llm_verdict, verdict_for, submission, ever_claimed>>

Cancel ==
    /\ state \in {"Todo", "Claimed", "InProgress", "AwaitingVerification"}
    /\ state' = "Cancelled"
    /\ UNCHANGED <<configured_llm_verdict, verdict_for, submission, ever_claimed>>

Terminal ==
    /\ state \in {"Done", "Cancelled"}
    /\ UNCHANGED vars

NextClean ==
    \/ Claim
    \/ Start
    \/ SubmitForConfiguredLlmVerification
    \/ ResubmitForConfiguredLlmVerification
    \/ ConfiguredLlmReturnsVerdict
    \/ DiscardSupersededVerdict
    \/ ApplyConfiguredLlmFail
    \/ Complete
    \/ Cancel
    \/ Terminal

BugSkipConfiguredLlmVerification ==
    /\ state = "InProgress"
    /\ state' = "Done"
    /\ UNCHANGED <<configured_llm_verdict, verdict_for, submission, ever_claimed>>

BugSkipClaim ==
    /\ state = "Todo"
    /\ state' = "InProgress"
    /\ UNCHANGED <<configured_llm_verdict, verdict_for, submission, ever_claimed>>

\* The failure resubmission would introduce if the new submission reused the
\* pending identity: a verdict read against replaced evidence completes the Task.
BugSupersededVerdictCompletes ==
    /\ state = "AwaitingVerification"
    /\ configured_llm_verdict = "pass"
    /\ verdict_for # submission
    /\ state' = "Done"
    /\ UNCHANGED <<configured_llm_verdict, verdict_for, submission, ever_claimed>>

NextBuggy ==
    \/ NextClean
    \/ BugSkipConfiguredLlmVerification
    \/ BugSkipClaim
    \/ BugSupersededVerdictCompletes

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* Isolates the resubmission bug. Bundled with the other two, TLC reports
\* whichever counterexample is shortest -- [BugSkipClaim] at depth 2 -- and the
\* identity clause of [DoneRequiresConfiguredLlmVerification] would go
\* unexercised. Checked separately so it has to do the work on its own.
SpecBuggySuperseded == Init /\ [][NextClean \/ BugSupersededVerdictCompletes]_vars

DoneRequiresConfiguredLlmVerification ==
    state = "Done" =>
        /\ configured_llm_verdict = "pass"
        /\ verdict_for = submission

InProgressRequiresClaim ==
    state \in {"InProgress", "AwaitingVerification", "Done"} => ever_claimed

Safety ==
    /\ TypeOK
    /\ DoneRequiresConfiguredLlmVerification
    /\ InProgressRequiresClaim

================================================================================
