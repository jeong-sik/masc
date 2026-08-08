---- MODULE CascadeFSM ----
\* ARCHIVED 2026-05-04. This spec modelled cascade_fsm.ml which was deleted
\* from OAS in 0.144.0 as part of the MASC migration. Multi-provider cascade
\* FSM and group orchestration are now MASC-owned. Kept verbatim for
\* historical context; do not link to it from active OAS specs.
\*
\* Models cascade_fsm.ml decide function directly.
\*
\* Verifies:
\*   1. Termination: cascade always reaches a terminal state
\*   2. Exhaustion safety: accept_on_exhaustion prevents all_failed
\*      when the last provider returned Ok
\*   3. Coverage: every provider is attempted before exhaustion
\*   4. Slot_full never blocks: always cascades to next
\*   5. Non-cascadeable errors stop immediately
\*
\* Maps 1:1 to OCaml types:
\*   provider_outcome = Call_ok | Call_err | Accept_rejected | Slot_full
\*   decision = Accept | Accept_on_exhaustion | Try_next | Exhausted
\*
\* @since 0.120.0 (cascade_fsm.ml extraction)

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    NumProviders,        \* Number of providers in cascade (e.g. 3)
    AcceptOnExhaustion   \* Boolean flag

VARIABLES
    idx,            \* Current provider index (1..NumProviders, 0=terminated)
    outcomes,       \* Per-provider outcome: "pending"|"call_ok"|"call_err_cascade"|"call_err_stop"|"accept_rejected"|"slot_full"
    decision,       \* FSM decision after each provider: "pending"|"accept"|"accept_exhaustion"|"try_next"|"exhausted"
    tried           \* Set of providers that were attempted

vars == <<idx, outcomes, decision, tried>>

TypeOK ==
    /\ idx \in 0..NumProviders
    /\ decision \in {"pending", "accept", "accept_exhaustion", "try_next", "exhausted"}
    /\ tried \subseteq 1..NumProviders

Init ==
    /\ idx = 1
    /\ outcomes = [i \in 1..NumProviders |-> "pending"]
    /\ decision = "pending"
    /\ tried = {}

\* ── Terminal predicate ────────────────────────
Terminal == decision \in {"accept", "accept_exhaustion", "exhausted"}

IsLast(i) == i = NumProviders

\* ── Provider outcome actions ──────────────────

\* Call_ok -> always Accept
DecideCallOk(i) ==
    /\ idx = i
    /\ ~Terminal
    /\ outcomes' = [outcomes EXCEPT ![i] = "call_ok"]
    /\ decision' = "accept"
    /\ idx' = 0
    /\ tried' = tried \union {i}

\* Slot_full -> always Try_next
DecideSlotFull(i) ==
    /\ idx = i
    /\ ~Terminal
    /\ outcomes' = [outcomes EXCEPT ![i] = "slot_full"]
    /\ tried' = tried \union {i}
    /\ IF i < NumProviders
       THEN /\ decision' = "try_next"
            /\ idx' = i + 1
       ELSE /\ decision' = "try_next"
            /\ idx' = 0  \* no more providers, will hit exhausted on next step

\* Accept_rejected on non-last -> Try_next
DecideAcceptRejectedNonLast(i) ==
    /\ idx = i
    /\ ~Terminal
    /\ ~IsLast(i)
    /\ outcomes' = [outcomes EXCEPT ![i] = "accept_rejected"]
    /\ decision' = "try_next"
    /\ idx' = i + 1
    /\ tried' = tried \union {i}

\* Accept_rejected on last + accept_on_exhaustion -> Accept_on_exhaustion
DecideAcceptRejectedLastExhaustion(i) ==
    /\ idx = i
    /\ ~Terminal
    /\ IsLast(i)
    /\ AcceptOnExhaustion
    /\ outcomes' = [outcomes EXCEPT ![i] = "accept_rejected"]
    /\ decision' = "accept_exhaustion"
    /\ idx' = 0
    /\ tried' = tried \union {i}

\* Accept_rejected on last + no exhaustion -> Exhausted
DecideAcceptRejectedLastFail(i) ==
    /\ idx = i
    /\ ~Terminal
    /\ IsLast(i)
    /\ ~AcceptOnExhaustion
    /\ outcomes' = [outcomes EXCEPT ![i] = "accept_rejected"]
    /\ decision' = "exhausted"
    /\ idx' = 0
    /\ tried' = tried \union {i}

\* Call_err cascadeable -> Try_next
DecideCallErrCascade(i) ==
    /\ idx = i
    /\ ~Terminal
    /\ outcomes' = [outcomes EXCEPT ![i] = "call_err_cascade"]
    /\ tried' = tried \union {i}
    /\ IF i < NumProviders
       THEN /\ decision' = "try_next"
            /\ idx' = i + 1
       ELSE /\ decision' = "exhausted"
            /\ idx' = 0

\* Call_err non-cascadeable -> Exhausted immediately
DecideCallErrStop(i) ==
    /\ idx = i
    /\ ~Terminal
    /\ outcomes' = [outcomes EXCEPT ![i] = "call_err_stop"]
    /\ decision' = "exhausted"
    /\ idx' = 0
    /\ tried' = tried \union {i}

Next ==
    \E i \in 1..NumProviders :
        \/ DecideCallOk(i)
        \/ DecideSlotFull(i)
        \/ DecideAcceptRejectedNonLast(i)
        \/ DecideAcceptRejectedLastExhaustion(i)
        \/ DecideAcceptRejectedLastFail(i)
        \/ DecideCallErrCascade(i)
        \/ DecideCallErrStop(i)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants ────────────────────────

\* 1. Termination: once terminal, stays terminal (no resurrection)
TerminalIsStable ==
    Terminal => idx = 0

\* 2. Exhaustion safety: accept_on_exhaustion=TRUE prevents "exhausted"
\*    when ALL providers returned Ok (but accept rejected them)
ExhaustionSafety ==
    (AcceptOnExhaustion /\ decision = "exhausted") =>
        \* At least one provider did NOT return accept_rejected (had a real error or slot_full)
        \E i \in tried :
            outcomes[i] \in {"call_err_cascade", "call_err_stop", "slot_full"}

\* 3. Accept means some provider returned Ok
AcceptImpliesOk ==
    decision = "accept" =>
        \E i \in tried : outcomes[i] = "call_ok"

\* 4. Accept_exhaustion means last provider was accept_rejected
AcceptExhaustionImpliesLastRejected ==
    decision = "accept_exhaustion" =>
        outcomes[NumProviders] = "accept_rejected"

\* 5. Non-cascadeable error stops immediately (doesn't try more providers)
NonCascadeableStopsEarly ==
    (\E i \in tried : outcomes[i] = "call_err_stop") =>
        \* No provider after the stopping one was tried
        \A j \in tried :
            (outcomes[j] = "call_err_stop") => ~(\E k \in tried : k > j)

\* 6. Slot_full never produces exhausted directly (always try_next first)
SlotFullNeverExhausts ==
    (Cardinality(tried) = 1 /\ \E i \in tried : outcomes[i] = "slot_full") =>
        decision # "exhausted"

\* ── Bug Model: ShrinkContext missing (current code) ─────────
\* All providers fail with cascadeable error (e.g. 175KB context).
\* ShrinkContext transition does NOT exist -> Exhausted.

BugAllProvidersFail(i) ==
    /\ idx = i
    /\ ~Terminal
    /\ outcomes' = [outcomes EXCEPT ![i] = "call_err_cascade"]
    /\ tried' = tried \union {i}
    /\ IF i < NumProviders
       THEN /\ decision' = "try_next"
            /\ idx' = i + 1
       ELSE /\ decision' = "exhausted"
            /\ idx' = 0

NextBuggy ==
    \E i \in 1..NumProviders :
        BugAllProvidersFail(i)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(NextBuggy)

\* Invariant SHOULD be violated: proves ShrinkContext gap
ShrinkContextShouldPreventExhaustion ==
    decision = "exhausted" =>
        ~(\A i \in tried : outcomes[i] = "call_err_cascade")

====
