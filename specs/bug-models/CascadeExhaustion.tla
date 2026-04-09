---- MODULE CascadeExhaustion ----
\* Bug Model: Cascade accept_on_exhaustion paradox.
\*
\* Models cascade_executor.ml:complete_cascade_with_accept.
\* When accept_on_exhaustion=TRUE and ALL providers return Ok but are
\* rejected by accept, the last provider's response should be accepted.
\*
\* Bug hypothesis: the last provider returns Error (not Ok), so
\* accept_on_exhaustion never fires.  The error message says
\* "rejected by accept validator" because the PREVIOUS Ok response
\* was rejected, and that becomes last_err.

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    NumProviders,       \* Number of providers in cascade (e.g. 2)
    AcceptOnExhaustion  \* Boolean: accept_on_exhaustion flag

VARIABLES
    provider_idx,       \* Current provider index (1..NumProviders, 0=done)
    provider_result,    \* Per-provider outcome: "ok" | "error" | "pending"
    accept_verdict,     \* Per-provider accept verdict: TRUE | FALSE | "na"
    cascade_outcome,    \* Final: "pending" | "accepted" | "exhaustion_accept" | "all_failed"
    last_err            \* Last error message (for "All models failed" diagnostic)

vars == <<provider_idx, provider_result, accept_verdict, cascade_outcome, last_err>>

TypeOK ==
    /\ provider_idx \in 0..NumProviders
    /\ cascade_outcome \in {"pending", "accepted", "exhaustion_accept", "all_failed"}

Init ==
    /\ provider_idx = 1
    /\ provider_result = [i \in 1..NumProviders |-> "pending"]
    /\ accept_verdict = [i \in 1..NumProviders |-> "na"]
    /\ cascade_outcome = "pending"
    /\ last_err = "none"

\* Provider returns Ok and accept says yes -> done
ProviderOkAccepted(i) ==
    /\ provider_idx = i
    /\ cascade_outcome = "pending"
    /\ provider_result' = [provider_result EXCEPT ![i] = "ok"]
    /\ accept_verdict' = [accept_verdict EXCEPT ![i] = TRUE]
    /\ cascade_outcome' = "accepted"
    /\ UNCHANGED <<provider_idx, last_err>>

\* Provider returns Ok but accept rejects -> cascade or exhaustion_accept
ProviderOkRejected(i) ==
    /\ provider_idx = i
    /\ cascade_outcome = "pending"
    /\ provider_result' = [provider_result EXCEPT ![i] = "ok"]
    /\ accept_verdict' = [accept_verdict EXCEPT ![i] = FALSE]
    /\ last_err' = "rejected by accept validator"
    /\ IF i = NumProviders  \* is_last
       THEN /\ IF AcceptOnExhaustion
               THEN cascade_outcome' = "exhaustion_accept"
               ELSE cascade_outcome' = "all_failed"
            /\ UNCHANGED provider_idx
       ELSE /\ cascade_outcome' = "pending"
            /\ provider_idx' = i + 1

\* Provider returns Error -> cascade (if cascadable) or fail
ProviderError(i) ==
    /\ provider_idx = i
    /\ cascade_outcome = "pending"
    /\ provider_result' = [provider_result EXCEPT ![i] = "error"]
    /\ accept_verdict' = [accept_verdict EXCEPT ![i] = "na"]
    /\ last_err' = "provider error"
    /\ IF i < NumProviders
       THEN /\ provider_idx' = i + 1
            /\ cascade_outcome' = "pending"
       ELSE /\ provider_idx' = 0
            /\ cascade_outcome' = "all_failed"

\* No more providers
Exhausted ==
    /\ provider_idx = 0
    /\ cascade_outcome = "pending"
    /\ cascade_outcome' = "all_failed"
    /\ UNCHANGED <<provider_idx, provider_result, accept_verdict, last_err>>

Next ==
    \/ \E i \in 1..NumProviders :
        \/ ProviderOkAccepted(i)
        \/ ProviderOkRejected(i)
        \/ ProviderError(i)
    \/ Exhausted

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants ──────────────────────────────────

\* Core invariant: if accept_on_exhaustion=TRUE, we never reach all_failed
\* when ALL providers returned Ok (their responses existed but were rejected).
ExhaustionSafetyWhenAllOk ==
    cascade_outcome = "all_failed" =>
        \* At least one provider must have returned Error
        \E i \in 1..NumProviders : provider_result[i] = "error"

\* Weaker: accept_on_exhaustion should prevent all_failed when last is Ok
ExhaustionSafetyLastOk ==
    (AcceptOnExhaustion /\ cascade_outcome = "all_failed") =>
        provider_result[NumProviders] # "ok"

ExhaustionDiagnosticConsistency ==
    (cascade_outcome = "all_failed" /\ last_err = "rejected by accept validator") =>
        provider_result[NumProviders] = "ok"

\* ── Bug Model ──────────────────────────────────────────

\* Bug: last provider returns Error, so accept_on_exhaustion never fires.
\* The cascade reports "rejected by accept validator" (from previous Ok rejection)
\* even though the actual failure was an Error on the last provider.
\* This is NOT a code bug — it's an architectural blind spot:
\* accept_on_exhaustion only gates Ok responses, not Error responses.

BugLastProviderAlwaysErrors(i) ==
    /\ provider_idx = i
    /\ i = NumProviders
    /\ cascade_outcome = "pending"
    /\ provider_result' = [provider_result EXCEPT ![i] = "error"]
    /\ accept_verdict' = [accept_verdict EXCEPT ![i] = "na"]
    \* The key: last_err is "rejected by accept validator" from PREVIOUS provider
    /\ last_err' = IF last_err = "rejected by accept validator"
                   THEN "rejected by accept validator"
                   ELSE "provider error"
    /\ provider_idx' = 0
    /\ cascade_outcome' = "all_failed"

NextBuggy ==
    \/ \E i \in 1..NumProviders :
        \/ ProviderOkAccepted(i)
        \/ ProviderOkRejected(i)
        \/ IF i = NumProviders
           THEN BugLastProviderAlwaysErrors(i)
           ELSE ProviderError(i)
    \/ Exhausted

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(NextBuggy)

====
