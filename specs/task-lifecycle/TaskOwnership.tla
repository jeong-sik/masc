---------------------------- MODULE TaskOwnership ----------------------------
\* Task lifecycle over several Tasks and several agents.
\* Target model of docs/rfc/RFC-task-lifecycle-a-verdict-assigns-no-work.md.
\*
\* TaskLifecycle.tla models one Task and no agent, so it cannot state what this
\* module is about: who holds what, and what a verdict is allowed to change.
\* Three facts are kept apart and each has its own writers. Names follow the
\* code: created_by, holder ("already holds"), producer, approved / rejected.
\*
\*   outcome[t]  is the Task still open, or Done, or Cancelled?
\*               writers: a verdict (Done), whoever created the Task or the
\*               operator (Cancelled)
\*   holder[t]   who holds the Task right now?
\*               writers: the agent itself (Claim, Release, Submit)
\*   pending[t]  is a submission before the authority?
\*               writers: the producer (Submit, Resubmit), a verdict
\*
\* Closing a Task ends its hold and its submission with it, so whoever may
\* close the Task also clears holder[t] and pending[t]. Nothing else writes
\* across these lines. In particular a verdict answers a submission and never
\* chooses who works next. The bug models below are what the code did when
\* this was written, or slips the design has to exclude.
\*
\* How the three facts read as [task_status] (lib/types/types_core.mli):
\*   Open, nobody holds, nothing pending   Todo
\*   Open, holder[t] is an agent           Claimed or InProgress (Start does not
\*                                         change who holds, so it is not modelled)
\*   Open, pending[t]                      AwaitingVerification
\*   Done, Cancelled                       the same names

EXTENDS Integers, FiniteSets

CONSTANTS Tasks, Agents, MaxSubmissions, NoOne, Operator

VARIABLES
    created_by,    \* who created the Task; fixed at creation
    outcome,       \* "Open" | "Done" | "Cancelled"
    holder,        \* who holds the Task, or NoOne
    pending,       \* a submission awaits review
    judgeable,     \* the pending submission is of a kind the system judge may answer
    producer,      \* who placed the pending submission
    sub,           \* identity of the latest submission
    verdict,       \* "none" | "approved" | "rejected"
    verdict_for,   \* which submission the returned verdict read
    cancelled_by,  \* who cancelled the Task
    stalled,       \* the judge cannot answer the pending submission right now
    returned,      \* the last submission came back rejected and nobody took it since
    claimed_by     \* every agent that has held the Task

vars ==
    <<created_by, outcome, holder, pending, judgeable, producer, sub, verdict,
      verdict_for, cancelled_by, stalled, returned, claimed_by>>

Creators == Agents \cup {Operator}

TypeOK ==
    /\ created_by \in [Tasks -> Creators]
    /\ outcome \in [Tasks -> {"Open", "Done", "Cancelled"}]
    /\ holder \in [Tasks -> Agents \cup {NoOne}]
    /\ pending \in [Tasks -> BOOLEAN]
    /\ judgeable \in [Tasks -> BOOLEAN]
    /\ producer \in [Tasks -> Agents \cup {NoOne}]
    /\ sub \in [Tasks -> 0..MaxSubmissions]
    /\ verdict \in [Tasks -> {"none", "approved", "rejected"}]
    /\ verdict_for \in [Tasks -> 0..MaxSubmissions]
    /\ cancelled_by \in [Tasks -> Creators \cup {NoOne}]
    /\ stalled \in [Tasks -> BOOLEAN]
    /\ returned \in [Tasks -> BOOLEAN]
    /\ claimed_by \in [Tasks -> SUBSET Agents]

Init ==
    /\ created_by \in [Tasks -> Creators]
    /\ outcome = [t \in Tasks |-> "Open"]
    /\ holder = [t \in Tasks |-> NoOne]
    /\ pending = [t \in Tasks |-> FALSE]
    /\ judgeable = [t \in Tasks |-> TRUE]
    /\ producer = [t \in Tasks |-> NoOne]
    /\ sub = [t \in Tasks |-> 0]
    /\ verdict = [t \in Tasks |-> "none"]
    /\ verdict_for = [t \in Tasks |-> 0]
    /\ cancelled_by = [t \in Tasks |-> NoOne]
    /\ stalled = [t \in Tasks |-> FALSE]
    /\ returned = [t \in Tasks |-> FALSE]
    /\ claimed_by = [t \in Tasks |-> {}]

Held(a) == {t \in Tasks : holder[t] = a}

\* ---------------------------------------------------------------- ownership

\* One Task at a time, and only a Task nobody holds and nobody is judging.
Claim(t, a) ==
    /\ outcome[t] = "Open"
    /\ holder[t] = NoOne
    /\ ~pending[t]
    /\ Held(a) = {}
    /\ holder' = [holder EXCEPT ![t] = a]
    /\ claimed_by' = [claimed_by EXCEPT ![t] = @ \cup {a}]
    \* Taking a returned Task ends the returned state: somebody holds it again.
    /\ returned' = [returned EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<created_by, outcome, pending, judgeable, producer, sub, verdict,
                   verdict_for, cancelled_by, stalled>>

\* The holder gives the Task back. An operator releasing a Task for an agent
\* that no longer exists has the same effect and is not modelled apart.
Release(t, a) ==
    /\ holder[t] = a
    /\ holder' = [holder EXCEPT ![t] = NoOne]
    /\ UNCHANGED <<created_by, outcome, pending, judgeable, producer, sub, verdict,
                   verdict_for, cancelled_by, stalled, returned, claimed_by>>

\* --------------------------------------------------------------- submission

\* Submitting hands the Task over to the authority and lets go of it.
Submit(t, a) ==
    /\ holder[t] = a
    /\ sub[t] < MaxSubmissions
    /\ holder' = [holder EXCEPT ![t] = NoOne]
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ judgeable' = [judgeable EXCEPT ![t] = TRUE]
    /\ producer' = [producer EXCEPT ![t] = a]
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<created_by, outcome, cancelled_by, returned, claimed_by>>

\* The producer may replace its holder submission while nobody has answered it.
\* This is a right over the submission, not over the Task: holder[t] stays NoOne.
\* A new submission is looked at afresh, so it also clears a stall.
Resubmit(t, a) ==
    /\ pending[t]
    /\ producer[t] = a
    /\ sub[t] < MaxSubmissions
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<created_by, outcome, holder, pending, judgeable, producer,
                   cancelled_by, returned, claimed_by>>

\* ------------------------------------------------------------------ verdict

JudgeReturns(t) ==
    /\ pending[t]
    /\ judgeable[t]
    /\ ~stalled[t]
    /\ verdict[t] = "none"
    /\ \E s \in 1..sub[t], v \in {"approved", "rejected"} :
         /\ verdict' = [verdict EXCEPT ![t] = v]
         /\ verdict_for' = [verdict_for EXCEPT ![t] = s]
    /\ UNCHANGED <<created_by, outcome, holder, pending, judgeable, producer, sub,
                   cancelled_by, stalled, returned, claimed_by>>

\* The review could not be carried out: the evaluator is misconfigured, its
\* lookup surface failed, and nothing will retry. The submission stays where
\* it is. This is a failure, not a kind of submission: [judgeable] stays TRUE.
JudgeCannotAnswer(t) ==
    /\ pending[t]
    /\ judgeable[t]
    /\ ~stalled[t]
    /\ verdict[t] = "none"
    /\ stalled' = [stalled EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<created_by, outcome, holder, pending, judgeable, producer, sub,
                   verdict, verdict_for, cancelled_by, returned, claimed_by>>

\* The operator may answer any pending submission, stalled or not. The answer
\* names the submission the operator read, so a click that raced a
\* resubmission is discarded like any other superseded verdict.
OperatorReturns(t) ==
    /\ pending[t]
    /\ verdict[t] = "none"
    /\ \E s \in 1..sub[t], v \in {"approved", "rejected"} :
         /\ verdict' = [verdict EXCEPT ![t] = v]
         /\ verdict_for' = [verdict_for EXCEPT ![t] = s]
    /\ UNCHANGED <<created_by, outcome, holder, pending, judgeable, producer, sub,
                   cancelled_by, stalled, returned, claimed_by>>

DiscardSuperseded(t) ==
    /\ pending[t]
    /\ verdict[t] # "none"
    /\ verdict_for[t] # sub[t]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ UNCHANGED <<created_by, outcome, holder, pending, judgeable, producer, sub,
                   cancelled_by, stalled, returned, claimed_by>>

ApplyApproved(t) ==
    /\ pending[t]
    /\ verdict[t] = "approved"
    /\ verdict_for[t] = sub[t]
    /\ outcome' = [outcome EXCEPT ![t] = "Done"]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<created_by, holder, judgeable, producer, sub, verdict,
                   verdict_for, cancelled_by, returned, claimed_by>>

\* The submission was rejected. The Task is simply open and unheld again;
\* the reason travels with it as context. Nobody is put to work by this step.
ApplyRejected(t) ==
    /\ pending[t]
    /\ verdict[t] = "rejected"
    /\ verdict_for[t] = sub[t]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ returned' = [returned EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<created_by, outcome, holder, judgeable, producer, sub,
                   cancelled_by, claimed_by>>

\* ------------------------------------------------------------- cancellation

\* Cancelling a Task is for whoever created it, whatever the Task is doing.
\* It is not a submission and no judge is asked. It ends the hold and the
\* pending submission too: a closed Task owes nothing and awaits nothing.
Cancel(t, who) ==
    /\ outcome[t] = "Open"
    /\ who = created_by[t] \/ who = Operator
    /\ outcome' = [outcome EXCEPT ![t] = "Cancelled"]
    /\ cancelled_by' = [cancelled_by EXCEPT ![t] = who]
    /\ holder' = [holder EXCEPT ![t] = NoOne]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ returned' = [returned EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<created_by, judgeable, producer, sub, claimed_by>>

NextClean ==
    \/ \E t \in Tasks, a \in Agents :
         Claim(t, a) \/ Release(t, a) \/ Submit(t, a) \/ Resubmit(t, a)
    \/ \E t \in Tasks :
         \/ JudgeReturns(t)
         \/ JudgeCannotAnswer(t)
         \/ OperatorReturns(t)
         \/ DiscardSuperseded(t)
         \/ ApplyApproved(t)
         \/ ApplyRejected(t)
    \/ \E t \in Tasks, who \in Creators : Cancel(t, who)

\* ================================================================ bug models

\* The code when this was written: a rejection restores InProgress for the
\* producer, whatever the producer has picked up since.
BugVerdictReturnsTaskToProducer(t) ==
    /\ pending[t]
    /\ verdict[t] = "rejected"
    /\ verdict_for[t] = sub[t]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ holder' = [holder EXCEPT ![t] = producer[t]]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<created_by, outcome, judgeable, producer, sub, cancelled_by,
                   returned, claimed_by>>

\* The code when this was written: a holder that wants out for good places a
\* cancel request that only the operator may answer.
BugCancelRequestOnlyOperatorAnswers(t, a) ==
    /\ holder[t] = a
    /\ sub[t] < MaxSubmissions
    /\ holder' = [holder EXCEPT ![t] = NoOne]
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ judgeable' = [judgeable EXCEPT ![t] = FALSE]
    /\ producer' = [producer EXCEPT ![t] = a]
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<created_by, outcome, verdict, verdict_for, cancelled_by, stalled,
                   returned, claimed_by>>

\* The code when this was written: any agent may cancel a Todo it did not ask
\* for.
BugAnyoneCancels(t, a) ==
    /\ outcome[t] = "Open"
    /\ holder[t] = NoOne
    /\ ~pending[t]
    /\ a # created_by[t]
    /\ outcome' = [outcome EXCEPT ![t] = "Cancelled"]
    /\ cancelled_by' = [cancelled_by EXCEPT ![t] = a]
    /\ UNCHANGED <<created_by, holder, pending, judgeable, producer, sub, verdict,
                   verdict_for, stalled, returned, claimed_by>>

\* A slip the new transitions make possible: the Task is closed but the
\* agent that held the Task is left holding it.
BugCancelKeepsHolder(t, who) ==
    /\ outcome[t] = "Open"
    /\ who = created_by[t] \/ who = Operator
    /\ outcome' = [outcome EXCEPT ![t] = "Cancelled"]
    /\ cancelled_by' = [cancelled_by EXCEPT ![t] = who]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<created_by, holder, judgeable, producer, sub, returned, claimed_by>>

\* A slip: submitting without letting go, so the Task is held and pending.
BugSubmitKeepsHold(t, a) ==
    /\ holder[t] = a
    /\ sub[t] < MaxSubmissions
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ judgeable' = [judgeable EXCEPT ![t] = TRUE]
    /\ producer' = [producer EXCEPT ![t] = a]
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ UNCHANGED <<created_by, outcome, holder, cancelled_by, stalled, returned, claimed_by>>

\* The design this replaces: a rejected Task goes to Todo, so the record no
\* longer names the agent whose submission was refused. The reason survives in
\* a free-text memo; the name does not.
BugRejectedForgetsProducer(t) ==
    /\ pending[t]
    /\ verdict[t] = "rejected"
    /\ verdict_for[t] = sub[t]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ returned' = [returned EXCEPT ![t] = TRUE]
    /\ producer' = [producer EXCEPT ![t] = NoOne]
    /\ UNCHANGED <<created_by, outcome, holder, judgeable, sub, cancelled_by,
                   claimed_by>>

\* Carried over from TaskLifecycle.tla (BugSkipClaim): work is submitted by an
\* agent that never held the Task.
BugSubmitWithoutHold(t, a) ==
    /\ outcome[t] = "Open"
    /\ holder[t] = NoOne
    /\ ~pending[t]
    /\ a \notin claimed_by[t]
    /\ sub[t] < MaxSubmissions
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ judgeable' = [judgeable EXCEPT ![t] = TRUE]
    /\ producer' = [producer EXCEPT ![t] = a]
    /\ sub' = [sub EXCEPT ![t] = @ + 1]
    /\ verdict' = [verdict EXCEPT ![t] = "none"]
    /\ verdict_for' = [verdict_for EXCEPT ![t] = 0]
    /\ UNCHANGED <<created_by, outcome, holder, cancelled_by, stalled, returned, claimed_by>>

\* Carried over from TaskLifecycle.tla.
BugDoneWithoutVerdict(t, a) ==
    /\ holder[t] = a
    /\ outcome' = [outcome EXCEPT ![t] = "Done"]
    /\ holder' = [holder EXCEPT ![t] = NoOne]
    /\ UNCHANGED <<created_by, pending, judgeable, producer, sub, verdict,
                   verdict_for, cancelled_by, stalled, returned, claimed_by>>

BugSupersededVerdictCompletes(t) ==
    /\ pending[t]
    /\ verdict[t] = "approved"
    /\ verdict_for[t] # sub[t]
    /\ outcome' = [outcome EXCEPT ![t] = "Done"]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ stalled' = [stalled EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<created_by, holder, judgeable, producer, sub, verdict,
                   verdict_for, cancelled_by, returned, claimed_by>>

\* A claim that takes a returned Task but leaves the returned mark standing.
\* The Task is then held and returned at once, which is the state the operator
\* list is built to exclude.
BugClaimKeepsReturned(t, a) ==
    /\ outcome[t] = "Open"
    /\ holder[t] = NoOne
    /\ ~pending[t]
    /\ returned[t]
    /\ Held(a) = {}
    /\ holder' = [holder EXCEPT ![t] = a]
    /\ claimed_by' = [claimed_by EXCEPT ![t] = @ \cup {a}]
    /\ UNCHANGED <<created_by, outcome, pending, judgeable, producer, sub, verdict,
                   verdict_for, cancelled_by, stalled, returned>>

SpecClean == Init /\ [][NextClean]_vars
SpecBugVerdictReturns ==
    Init /\ [][NextClean \/ \E t \in Tasks : BugVerdictReturnsTaskToProducer(t)]_vars
SpecBugCancelRequest ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents :
                              BugCancelRequestOnlyOperatorAnswers(t, a)]_vars
SpecBugAnyoneCancels ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents : BugAnyoneCancels(t, a)]_vars
SpecBugCancelKeepsHolder ==
    Init /\ [][NextClean \/ \E t \in Tasks, who \in Creators :
                              BugCancelKeepsHolder(t, who)]_vars
SpecBugSubmitKeepsHold ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents : BugSubmitKeepsHold(t, a)]_vars
SpecBugRejectedForgetsProducer ==
    Init /\ [][NextClean \/ \E t \in Tasks : BugRejectedForgetsProducer(t)]_vars
SpecBugSubmitWithoutHold ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents : BugSubmitWithoutHold(t, a)]_vars
SpecBugDoneWithoutVerdict ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents :
                              BugDoneWithoutVerdict(t, a)]_vars
SpecBugSupersededVerdict ==
    Init /\ [][NextClean \/ \E t \in Tasks : BugSupersededVerdictCompletes(t)]_vars
SpecBugClaimKeepsReturned ==
    Init /\ [][NextClean \/ \E t \in Tasks, a \in Agents :
                              BugClaimKeepsReturned(t, a)]_vars

\* ================================================================ properties

\* An agent holds at most one Task. Only Claim creates a hold and Claim checks
\* this, so nothing else may create one.
OneTaskPerAgent == \A a \in Agents : Cardinality(Held(a)) <= 1

\* A Task is held or before the authority, never both.
HeldOrPendingNotBoth == \A t \in Tasks : ~(holder[t] # NoOne /\ pending[t])

\* A closed Task owes nothing and awaits nothing.
ClosedOwesNothing ==
    \A t \in Tasks : outcome[t] # "Open" => (holder[t] = NoOne /\ ~pending[t])

\* No kind of submission is one that only the operator may answer. This is a
\* statement about kinds, not about liveness: a review can still fail
\* (JudgeCannotAnswer), and then the operator is who repairs it.
NoOperatorOnlySubmissionKind == \A t \in Tasks : pending[t] => judgeable[t]

\* A Rejected Task is open, unheld and not pending. It is claimable, like Todo.
RejectedIsOpenAndUnheld ==
    \A t \in Tasks :
        returned[t] => (outcome[t] = "Open" /\ holder[t] = NoOne /\ ~pending[t])

\* A Rejected Task still names the agent whose submission was refused. This is
\* the whole reason it is a state of its own and not a return to Todo.
RejectedNamesItsProducer ==
    \A t \in Tasks : returned[t] => producer[t] # NoOne

\* A stall is a property of a pending submission and ends with it.
StalledOnlyWhilePending == \A t \in Tasks : stalled[t] => pending[t]

\* A submission comes from an agent that held the Task.
SubmissionRequiresHold ==
    \A t \in Tasks : pending[t] => producer[t] \in claimed_by[t]

\* Done only through an approving verdict read against the live submission.
DoneRequiresLiveApproval ==
    \A t \in Tasks :
        outcome[t] = "Done" => (verdict[t] = "approved" /\ verdict_for[t] = sub[t])

\* Cancelled only by whoever created the Task, or by the operator.
CancelledRequiresStanding ==
    \A t \in Tasks :
        outcome[t] = "Cancelled" => cancelled_by[t] \in {created_by[t], Operator}

\* Reachability guard, not a safety property. It is written as something that
\* must FAIL: its cfg expects a violation. If a future edit stops the clean
\* model from reaching a returned Task, this cfg goes quiet and the runner
\* reports it. Without it, RejectedIsOpenAndUnheld and RejectedNamesItsProducer
\* can go back to being vacuously true and the clean run still passes, which is
\* how they shipped in the first place.
RejectedNeverHappens == \A t \in Tasks : ~returned[t]

Safety ==
    /\ TypeOK
    /\ OneTaskPerAgent
    /\ HeldOrPendingNotBoth
    /\ ClosedOwesNothing
    /\ NoOperatorOnlySubmissionKind
    /\ StalledOnlyWhilePending
    /\ RejectedIsOpenAndUnheld
    /\ RejectedNamesItsProducer
    /\ SubmissionRequiresHold
    /\ DoneRequiresLiveApproval
    /\ CancelledRequiresStanding

\* A step that answers a submission never gives the Task to anyone: a Task
\* gains a holder only in a step that started with no submission pending.
VerdictNeverAssigns ==
    [][\A t \in Tasks : (holder[t] = NoOne /\ holder'[t] # NoOne) => ~pending[t]]_vars

\* Reachability guard for the way OUT, expecting a violation like
\* RejectedNeverHappens guards the way in. Those two are different questions:
\* a model can reach a returned Task and still never let anyone take it, which
\* is the graveyard D1 is judged against. Written as something that must FAIL,
\* so it goes quiet the day Claim stops admitting a returned Task.
RejectedNeverResumed ==
    [][\A t \in Tasks : ~(returned[t] /\ holder[t] = NoOne /\ holder'[t] # NoOne)]_vars

==============================================================================
