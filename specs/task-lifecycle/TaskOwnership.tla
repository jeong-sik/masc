---------------------------- MODULE TaskOwnership ----------------------------
\* Task lifecycle over several Tasks and several agents.
\* Target model of docs/rfc/RFC-task-lifecycle-request-hold-submission.md.
\*
\* TaskLifecycle.tla models one Task and no agent, so it cannot state what this
\* module is about: who holds what, and what a verdict is allowed to change.
\* Three facts are kept apart and each has its own writers.
\*
\*   req[t]      is the request still open?
\*               writers: a verdict (Accepted), the requester or operator
\*               (Withdrawn)
\*   own[t]      who holds the Task right now?
\*               writers: the agent itself (Claim, Release, Submit)
\*   pending[t]  is a submission before the authority?
\*               writers: the submitter (Submit, Resubmit), a verdict
\*
\* Closing a request ends its hold and its submission with it, so whoever may
\* close the request also clears own[t] and pending[t]. Nothing else writes
\* across these lines. In particular a verdict answers a submission and never
\* chooses who works next. The bug models below are what the code did when
\* this was written, or slips the design has to exclude.
\*
\* How the three facts read as [task_status] (lib/types/types_core.mli):
\*   Open, nobody holds, nothing pending   Todo
\*   Open, own[t] is an agent              Claimed or InProgress (Start does not
\*                                         change who holds, so it is not modelled)
\*   Open, pending[t]                      AwaitingVerification
\*   Accepted                              Done
\*   Withdrawn                             Cancelled

EXTENDS Integers, FiniteSets

CONSTANTS Tasks, Agents, MaxSubmissions, NoOne, Operator

VARIABLES
    author,        \* who asked for the Task; fixed at creation
    req,           \* "Open" | "Accepted" | "Withdrawn"
    own,           \* holder, or NoOne
    pending,       \* a submission awaits review
    judgeable,     \* the pending submission is of a kind the system judge may answer
    submitter,     \* who placed the pending submission
    sub,           \* identity of the latest submission
    verdict,       \* "none" | "confirmed" | "not_confirmed"
    verdict_for,   \* which submission the returned verdict read
    withdrawn_by,  \* who withdrew the request
    stalled,       \* the judge cannot answer the pending submission right now
    claimed_by     \* every agent that has held the Task

vars ==
    <<author, req, own, pending, judgeable, submitter, sub, verdict,
      verdict_for, withdrawn_by, stalled, claimed_by>>

Requesters == Agents \cup {Operator}

TypeOK ==
    /\ author \in [Tasks -> Requesters]
    /\ req \in [Tasks -> {"Open", "Accepted", "Withdrawn"}]
    /\ own \in [Tasks -> Agents \cup {NoOne}]
    /\ pending \in [Tasks -> BOOLEAN]
    /\ judgeable \in [Tasks -> BOOLEAN]
    /\ submitter \in [Tasks -> Agents \cup {NoOne}]
    /\ sub \in [Tasks -> 0..MaxSubmissions]
    /\ verdict \in [Tasks -> {"none", "confirmed", "not_confirmed"}]
    /\ verdict_for \in [Tasks -> 0..MaxSubmissions]
    /\ withdrawn_by \in [Tasks -> Requesters \cup {NoOne}]
    /\ stalled \in [Tasks -> BOOLEAN]
    /\ claimed_by \in [Tasks -> SUBSET Agents]

Init ==
    /\ author \in [Tasks -> Requesters]
    /\ req = [t \in Tasks |-> "Open"]
    /\ own = [t \in Tasks |-> NoOne]
    /\ pending = [t \in Tasks |-> FALSE]
    /\ judgeable = [t \in Tasks |-> TRUE]
    /\ submitter = [t \in Tasks |-> NoOne]
    /\ sub = [t \in Tasks |-> 0]
    /\ verdict = [t \in Tasks |-> "none"]
    /\ verdict_for = [t \in Tasks |-> 0]
    /\ withdrawn_by = [t \in Tasks |-> NoOne]
    /\ stalled = [t \in Tasks |-> FALSE]
    /\ claimed_by = [t \in Tasks |-> {}]

Held(a) == {t \in Tasks : own[t] = a}

\* ---------------------------------------------------------------- ownership

\* One Task at a time, and only a Task nobody holds and nobody is judging.
Claim(t, a) ==
    /\ req[t] = "Open"
    /\ own[t] = NoOne
    /\ ~pending[t]
    /\ Held(a) = {}
    /\ own' = [own EXCEPT ![t] = a]
    /\ claimed_by' = [claimed_by EXCEPT ![t] = @ \cup {a}]
    /\ UNCHANGED <<author, req, pending, judgeable, submitter, sub, verdict,
                   verdict_for, withdrawn_by, stalled>>

\* The holder gives the Task back. An operator releasing a Task for an agent
\* that no longer exists has the same effect and is not modelled apart.
Release(t, a) ==
    /\ own[t] = a
    /\ own' = [own EXCEPT ![t] = NoOne]
    /\ UNCHANGED <<author, req, pending, judgeable, submitter, sub, verdict,
                   verdict_for, withdrawn_by, stalled, claimed_by>>

\* --------------------------------------------------------------- submission

\* Submitting hands the Task over to the authority and lets go of it.
Submit(t, a) ==
    /\ own[t] = a
    /\ sub[t] < MaxSubmissions
    /\ own' = [own EXCEPT ![t] = NoOne]
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ judgeable' = [judgeable EXCEPT ![t] = TRUE]
    /\ submitter' = [submitter EXCEPT ![t] = a]
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<author, req, withdrawn_by, claimed_by>>

\* The submitter may replace its own submission while nobody has answered it.
\* This is a right over the submission, not over the Task: own[t] stays NoOne.
\* A new submission is looked at afresh, so it also clears a stall.
Resubmit(t, a) ==
    /\ pending[t]
    /\ submitter[t] = a
    /\ sub[t] < MaxSubmissions
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<author, req, own, pending, judgeable, submitter,
                   withdrawn_by, claimed_by>>

\* ------------------------------------------------------------------ verdict

JudgeReturns(t) ==
    /\ pending[t]
    /\ judgeable[t]
    /\ ~stalled[t]
    /\ verdict[t] = "none"
    /\ \E s \in 1..sub[t], v \in {"confirmed", "not_confirmed"} :
         /\ verdict' = [verdict EXCEPT ![t] = v]
         /\ verdict_for' = [verdict_for EXCEPT ![t] = s]
    /\ UNCHANGED <<author, req, own, pending, judgeable, submitter, sub,
                   withdrawn_by, stalled, claimed_by>>

\* The review could not be carried out: the evaluator is misconfigured, its
\* lookup surface failed, and nothing will retry. The submission stays where
\* it is. This is a failure, not a kind of submission: [judgeable] stays TRUE.
JudgeCannotAnswer(t) ==
    /\ pending[t]
    /\ judgeable[t]
    /\ ~stalled[t]
    /\ verdict[t] = "none"
    /\ stalled' = [stalled EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<author, req, own, pending, judgeable, submitter, sub,
                   verdict, verdict_for, withdrawn_by, claimed_by>>

\* The operator may answer any pending submission, stalled or not. The answer
\* names the submission the operator read, so a click that raced a
\* resubmission is discarded like any other superseded verdict.
OperatorReturns(t) ==
    /\ pending[t]
    /\ verdict[t] = "none"
    /\ \E s \in 1..sub[t], v \in {"confirmed", "not_confirmed"} :
         /\ verdict' = [verdict EXCEPT ![t] = v]
         /\ verdict_for' = [verdict_for EXCEPT ![t] = s]
    /\ UNCHANGED <<author, req, own, pending, judgeable, submitter, sub,
                   withdrawn_by, stalled, claimed_by>>

DiscardSuperseded(t) ==
    /\ pending[t]
    /\ verdict[t] # "none"
    /\ verdict_for[t] # sub[t]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ UNCHANGED <<author, req, own, pending, judgeable, submitter, sub,
                   withdrawn_by, stalled, claimed_by>>

ApplyConfirmed(t) ==
    /\ pending[t]
    /\ verdict[t] = "confirmed"
    /\ verdict_for[t] = sub[t]
    /\ req' = [req EXCEPT ![t] = "Accepted"]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<author, own, judgeable, submitter, sub, verdict,
                   verdict_for, withdrawn_by, claimed_by>>

\* The submission was not confirmed. The Task is simply open and unheld again;
\* the reason travels with it as context. Nobody is put to work by this step.
ApplyNotConfirmed(t) ==
    /\ pending[t]
    /\ verdict[t] = "not_confirmed"
    /\ verdict_for[t] = sub[t]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<author, req, own, judgeable, submitter, sub,
                   withdrawn_by, claimed_by>>

\* --------------------------------------------------------------- withdrawal

\* Retracting a request is the requester's call, whatever the Task is doing.
\* It is not a submission and no judge is asked. It ends the hold and the
\* pending submission too: a closed request owes nothing and awaits nothing.
Withdraw(t, who) ==
    /\ req[t] = "Open"
    /\ who = author[t] \/ who = Operator
    /\ req' = [req EXCEPT ![t] = "Withdrawn"]
    /\ withdrawn_by' = [withdrawn_by EXCEPT ![t] = who]
    /\ own' = [own EXCEPT ![t] = NoOne]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<author, judgeable, submitter, sub, claimed_by>>

NextClean ==
    \/ \E t \in Tasks, a \in Agents :
         Claim(t, a) \/ Release(t, a) \/ Submit(t, a) \/ Resubmit(t, a)
    \/ \E t \in Tasks :
         \/ JudgeReturns(t)
         \/ JudgeCannotAnswer(t)
         \/ OperatorReturns(t)
         \/ DiscardSuperseded(t)
         \/ ApplyConfirmed(t)
         \/ ApplyNotConfirmed(t)
    \/ \E t \in Tasks, who \in Requesters : Withdraw(t, who)

\* ================================================================ bug models

\* The code when this was written: a rejection restores InProgress for the
\* producer, whatever the producer has picked up since.
BugVerdictReturnsTaskToSubmitter(t) ==
    /\ pending[t]
    /\ verdict[t] = "not_confirmed"
    /\ verdict_for[t] = sub[t]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ own' = [own EXCEPT ![t] = submitter[t]]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<author, req, judgeable, submitter, sub, withdrawn_by,
                   claimed_by>>

\* The code when this was written: a holder that wants out for good places a
\* stop request that only the operator may answer.
BugStopSubmissionOnlyOperatorAnswers(t, a) ==
    /\ own[t] = a
    /\ sub[t] < MaxSubmissions
    /\ own' = [own EXCEPT ![t] = NoOne]
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ judgeable' = [judgeable EXCEPT ![t] = FALSE]
    /\ submitter' = [submitter EXCEPT ![t] = a]
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<author, req, verdict, verdict_for, withdrawn_by, stalled,
                   claimed_by>>

\* The code when this was written: any agent may cancel a Todo it did not ask
\* for.
BugAnyoneWithdraws(t, a) ==
    /\ req[t] = "Open"
    /\ own[t] = NoOne
    /\ ~pending[t]
    /\ a # author[t]
    /\ req' = [req EXCEPT ![t] = "Withdrawn"]
    /\ withdrawn_by' = [withdrawn_by EXCEPT ![t] = a]
    /\ UNCHANGED <<author, own, pending, judgeable, submitter, sub, verdict,
                   verdict_for, stalled, claimed_by>>

\* A slip the new transitions make possible: the request is closed but the
\* agent that held the Task is left holding it.
BugWithdrawKeepsHolder(t, who) ==
    /\ req[t] = "Open"
    /\ who = author[t] \/ who = Operator
    /\ req' = [req EXCEPT ![t] = "Withdrawn"]
    /\ withdrawn_by' = [withdrawn_by EXCEPT ![t] = who]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<author, own, judgeable, submitter, sub, claimed_by>>

\* A slip: submitting without letting go, so the Task is held and pending.
BugSubmitKeepsHold(t, a) ==
    /\ own[t] = a
    /\ sub[t] < MaxSubmissions
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ judgeable' = [judgeable EXCEPT ![t] = TRUE]
    /\ submitter' = [submitter EXCEPT ![t] = a]
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ UNCHANGED <<author, req, own, withdrawn_by, stalled, claimed_by>>

\* Carried over from TaskLifecycle.tla (BugSkipClaim): work is submitted by an
\* agent that never held the Task.
BugSubmitWithoutHold(t, a) ==
    /\ req[t] = "Open"
    /\ own[t] = NoOne
    /\ ~pending[t]
    /\ a \notin claimed_by[t]
    /\ sub[t] < MaxSubmissions
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ judgeable' = [judgeable EXCEPT ![t] = TRUE]
    /\ submitter' = [submitter EXCEPT ![t] = a]
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ UNCHANGED <<author, req, own, withdrawn_by, stalled, claimed_by>>

\* Carried over from TaskLifecycle.tla.
BugAcceptWithoutVerdict(t, a) ==
    /\ own[t] = a
    /\ req' = [req EXCEPT ![t] = "Accepted"]
    /\ own' = [own EXCEPT ![t] = NoOne]
    /\ UNCHANGED <<author, pending, judgeable, submitter, sub, verdict,
                   verdict_for, withdrawn_by, stalled, claimed_by>>

BugSupersededVerdictAccepts(t) ==
    /\ pending[t]
    /\ verdict[t] = "confirmed"
    /\ verdict_for[t] # sub[t]
    /\ req' = [req EXCEPT ![t] = "Accepted"]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<author, own, judgeable, submitter, sub, verdict,
                   verdict_for, withdrawn_by, claimed_by>>

SpecClean == Init /\ [][NextClean]_vars
SpecBugVerdictReturns ==
    Init /\ [][NextClean \/ \E t \in Tasks : BugVerdictReturnsTaskToSubmitter(t)]_vars
SpecBugStopSubmission ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents :
                              BugStopSubmissionOnlyOperatorAnswers(t, a)]_vars
SpecBugAnyoneWithdraws ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents : BugAnyoneWithdraws(t, a)]_vars
SpecBugWithdrawKeepsHolder ==
    Init /\ [][NextClean \/ \E t \in Tasks, who \in Requesters :
                              BugWithdrawKeepsHolder(t, who)]_vars
SpecBugSubmitKeepsHold ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents : BugSubmitKeepsHold(t, a)]_vars
SpecBugSubmitWithoutHold ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents : BugSubmitWithoutHold(t, a)]_vars
SpecBugAcceptWithoutVerdict ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents :
                              BugAcceptWithoutVerdict(t, a)]_vars
SpecBugSupersededVerdict ==
    Init /\ [][NextClean \/ \E t \in Tasks : BugSupersededVerdictAccepts(t)]_vars

\* ================================================================ properties

\* An agent holds at most one Task. Only Claim creates a hold and Claim checks
\* this, so nothing else may create one.
OneTaskPerAgent == \A a \in Agents : Cardinality(Held(a)) <= 1

\* A Task is held or before the authority, never both.
HeldOrPendingNotBoth == \A t \in Tasks : ~(own[t] # NoOne /\ pending[t])

\* A closed request owes nothing and awaits nothing.
ClosedOwesNothing ==
    \A t \in Tasks : req[t] # "Open" => (own[t] = NoOne /\ ~pending[t])

\* No kind of submission is one that only the operator may answer. This is a
\* statement about kinds, not about liveness: a review can still fail
\* (JudgeCannotAnswer), and then the operator is who repairs it.
NoOperatorOnlySubmissionKind == \A t \in Tasks : pending[t] => judgeable[t]

\* A stall is a property of a pending submission and ends with it.
StalledOnlyWhilePending == \A t \in Tasks : stalled[t] => pending[t]

\* A submission comes from an agent that held the Task.
SubmissionRequiresHold ==
    \A t \in Tasks : pending[t] => submitter[t] \in claimed_by[t]

\* Accepted only through a confirming verdict read against the live submission.
AcceptedRequiresLiveConfirmation ==
    \A t \in Tasks :
        req[t] = "Accepted" => (verdict[t] = "confirmed" /\ verdict_for[t] = sub[t])

\* Withdrawn only by whoever asked, or by the operator.
WithdrawnRequiresStanding ==
    \A t \in Tasks :
        req[t] = "Withdrawn" => withdrawn_by[t] \in {author[t], Operator}

Safety ==
    /\ TypeOK
    /\ OneTaskPerAgent
    /\ HeldOrPendingNotBoth
    /\ ClosedOwesNothing
    /\ NoOperatorOnlySubmissionKind
    /\ StalledOnlyWhilePending
    /\ SubmissionRequiresHold
    /\ AcceptedRequiresLiveConfirmation
    /\ WithdrawnRequiresStanding

\* A step that answers a submission never gives the Task to anyone: a Task
\* gains a holder only in a step that started with no submission pending.
VerdictNeverAssigns ==
    [][\A t \in Tasks : (own[t] = NoOne /\ own'[t] # NoOne) => ~pending[t]]_vars

==============================================================================
