---- MODULE CascadeFSMShrink ----
\* ARCHIVED 2026-05-04. This spec described a Phase 2 target for cascade_fsm.ml
\* which was deleted from OAS in 0.144.0 as part of the MASC migration.
\* Multi-provider cascade FSM (including ShrinkContext) is now MASC-owned.
\* Kept verbatim for historical context; do not link from active OAS specs.
\*
\* Phase 2 target model: cascade FSM with ShrinkContext transition.
\*
\* Key difference from CascadeFSM: when all providers fail with
\* cascadeable errors, the FSM enters "shrink_pending" (not "exhausted")
\* if shrink budget remains. ShrinkAndRetry then resets the cascade.
\* "exhausted" only fires when no shrink budget remains.
\*
\* This spec validates the Phase 2 target behavior before implementation.

EXTENDS Naturals, FiniteSets

CONSTANTS
    NumProviders,
    AcceptOnExhaustion,
    MaxShrinks

VARIABLES
    idx,
    outcomes,
    decision,
    tried,
    shrink_count

vars == <<idx, outcomes, decision, tried, shrink_count>>

TypeOK ==
    /\ idx \in 0..NumProviders
    /\ decision \in {"pending", "accept", "accept_exhaustion",
                     "try_next", "shrink_pending", "exhausted"}
    /\ tried \subseteq 1..NumProviders
    /\ shrink_count \in 0..MaxShrinks

Init ==
    /\ idx = 1
    /\ outcomes = [i \in 1..NumProviders |-> "pending"]
    /\ decision = "pending"
    /\ tried = {}
    /\ shrink_count = 0

Terminal == decision \in {"accept", "accept_exhaustion", "exhausted"}
IsLast(i) == i = NumProviders

\* ── Provider outcome actions ──────────────────

DecideCallOk(i) ==
    /\ idx = i /\ ~Terminal /\ decision # "shrink_pending"
    /\ outcomes' = [outcomes EXCEPT ![i] = "call_ok"]
    /\ decision' = "accept" /\ idx' = 0
    /\ tried' = tried \union {i}
    /\ UNCHANGED shrink_count

DecideSlotFull(i) ==
    /\ idx = i /\ ~Terminal /\ decision # "shrink_pending"
    /\ outcomes' = [outcomes EXCEPT ![i] = "slot_full"]
    /\ tried' = tried \union {i}
    /\ UNCHANGED shrink_count
    /\ IF i < NumProviders
       THEN /\ decision' = "try_next" /\ idx' = i + 1
       ELSE /\ decision' = "try_next" /\ idx' = 0

DecideAcceptRejectedNonLast(i) ==
    /\ idx = i /\ ~Terminal /\ decision # "shrink_pending"
    /\ ~IsLast(i)
    /\ outcomes' = [outcomes EXCEPT ![i] = "accept_rejected"]
    /\ decision' = "try_next" /\ idx' = i + 1
    /\ tried' = tried \union {i}
    /\ UNCHANGED shrink_count

DecideAcceptRejectedLastExhaustion(i) ==
    /\ idx = i /\ ~Terminal /\ decision # "shrink_pending"
    /\ IsLast(i) /\ AcceptOnExhaustion
    /\ outcomes' = [outcomes EXCEPT ![i] = "accept_rejected"]
    /\ decision' = "accept_exhaustion" /\ idx' = 0
    /\ tried' = tried \union {i}
    /\ UNCHANGED shrink_count

DecideAcceptRejectedLastFail(i) ==
    /\ idx = i /\ ~Terminal /\ decision # "shrink_pending"
    /\ IsLast(i) /\ ~AcceptOnExhaustion
    /\ outcomes' = [outcomes EXCEPT ![i] = "accept_rejected"]
    /\ decision' = "exhausted" /\ idx' = 0
    /\ tried' = tried \union {i}
    /\ UNCHANGED shrink_count

\* Last provider cascadeable error: shrink_pending if budget remains, else exhausted
DecideCallErrCascade(i) ==
    /\ idx = i /\ ~Terminal /\ decision # "shrink_pending"
    /\ outcomes' = [outcomes EXCEPT ![i] = "call_err_cascade"]
    /\ tried' = tried \union {i}
    /\ UNCHANGED shrink_count
    /\ IF i < NumProviders
       THEN /\ decision' = "try_next" /\ idx' = i + 1
       ELSE \* Last provider: check if shrink is available
            /\ idx' = 0
            /\ IF \A j \in (tried \union {i}) : outcomes'[j] = "call_err_cascade"
               THEN IF shrink_count < MaxShrinks
                    THEN decision' = "shrink_pending"
                    ELSE decision' = "exhausted"
               ELSE decision' = "exhausted"

DecideCallErrStop(i) ==
    /\ idx = i /\ ~Terminal /\ decision # "shrink_pending"
    /\ outcomes' = [outcomes EXCEPT ![i] = "call_err_stop"]
    /\ decision' = "exhausted" /\ idx' = 0
    /\ tried' = tried \union {i}
    /\ UNCHANGED shrink_count

\* ── ShrinkContext transition ──────────────────

ShrinkAndRetry ==
    /\ decision = "shrink_pending"
    /\ shrink_count < MaxShrinks
    /\ idx' = 1
    /\ outcomes' = [i \in 1..NumProviders |-> "pending"]
    /\ decision' = "pending"
    /\ tried' = {}
    /\ shrink_count' = shrink_count + 1

Next ==
    \/ \E i \in 1..NumProviders :
        \/ DecideCallOk(i)
        \/ DecideSlotFull(i)
        \/ DecideAcceptRejectedNonLast(i)
        \/ DecideAcceptRejectedLastExhaustion(i)
        \/ DecideAcceptRejectedLastFail(i)
        \/ DecideCallErrCascade(i)
        \/ DecideCallErrStop(i)
    \/ ShrinkAndRetry

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants ────────────────────────

\* Shrink count never exceeds budget
ShrinkBounded == shrink_count <= MaxShrinks

\* "exhausted" only when: (a) shrink budget spent, or (b) not all failures
\* were cascadeable (mixed failures means shrink would not help all providers)
ExhaustedImpliesNoShrinkBudget ==
    decision = "exhausted" =>
        \/ shrink_count >= MaxShrinks
        \/ ~(\A i \in tried : outcomes[i] = "call_err_cascade")

\* Terminal stability
TerminalIsStable ==
    Terminal => idx = 0

\* Accept requires Call_ok
AcceptImpliesOk ==
    decision = "accept" => \E i \in tried : outcomes[i] = "call_ok"

\* shrink_pending is transient (liveness via WF)
\* As a safety check: shrink_pending only when shrink budget remains
ShrinkPendingHasBudget ==
    decision = "shrink_pending" => shrink_count < MaxShrinks

====
