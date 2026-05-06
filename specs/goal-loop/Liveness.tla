---- MODULE Liveness ----
\* Prompt-level GOAL LOOP phase-progress contract.
\*
\* The loop may terminate as PASS only after the strict row corpus is complete.
\* If row evidence is incomplete, Verify must terminate as blocked instead of
\* silently reporting success. Fairness encodes the scheduler assumption that
\* each enabled phase eventually runs.

EXTENDS TLC

VARIABLES phase, corpus, verify_status

vars == <<phase, corpus, verify_status>>

PhaseSet == {"observe", "orient", "decide", "act", "verify", "terminal"}
CorpusSet == {"unknown", "complete", "incomplete"}
VerifySet == {"none", "pass", "blocked"}

TypeOK ==
    /\ phase \in PhaseSet
    /\ corpus \in CorpusSet
    /\ verify_status \in VerifySet

Init ==
    /\ phase = "observe"
    /\ corpus = "unknown"
    /\ verify_status = "none"

OrientComplete ==
    /\ phase = "observe"
    /\ phase' = "orient"
    /\ corpus' = "complete"
    /\ UNCHANGED verify_status

OrientIncomplete ==
    /\ phase = "observe"
    /\ phase' = "orient"
    /\ corpus' = "incomplete"
    /\ UNCHANGED verify_status

Decide ==
    /\ phase = "orient"
    /\ phase' = "decide"
    /\ UNCHANGED <<corpus, verify_status>>

Act ==
    /\ phase = "decide"
    /\ phase' = "act"
    /\ UNCHANGED <<corpus, verify_status>>

EnterVerify ==
    /\ phase = "act"
    /\ phase' = "verify"
    /\ UNCHANGED <<corpus, verify_status>>

VerifyPass ==
    /\ phase = "verify"
    /\ corpus = "complete"
    /\ phase' = "terminal"
    /\ verify_status' = "pass"
    /\ UNCHANGED corpus

VerifyBlocked ==
    /\ phase = "verify"
    /\ corpus = "incomplete"
    /\ phase' = "terminal"
    /\ verify_status' = "blocked"
    /\ UNCHANGED corpus

Next ==
    \/ OrientComplete
    \/ OrientIncomplete
    \/ Decide
    \/ Act
    \/ EnterVerify
    \/ VerifyPass
    \/ VerifyBlocked

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(OrientComplete)
    /\ WF_vars(OrientIncomplete)
    /\ WF_vars(Decide)
    /\ WF_vars(Act)
    /\ WF_vars(EnterVerify)
    /\ WF_vars(VerifyPass)
    /\ WF_vars(VerifyBlocked)

NoFalsePass ==
    verify_status = "pass" => corpus = "complete"

IncompleteRowsBlock ==
    corpus = "incomplete" /\ phase = "terminal" => verify_status = "blocked"

EventuallyTerminates == <> (phase = "terminal")

Safety ==
    /\ TypeOK
    /\ NoFalsePass
    /\ IncompleteRowsBlock
====
