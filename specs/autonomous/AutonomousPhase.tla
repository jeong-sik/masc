---- MODULE AutonomousPhase ----
\* Cycle 27 / Tier B5 catch-up spec.
\*
\* Models the 8-phase autonomous loop taxonomy and 19 legal
\* transitions encoded in lib/autonomous/autonomous_phase.{mli,ml}.
\* Each transition is constructed via a 2-parameter GADT in OCaml
\* (Transition.t : ('from, 'to_) t); illegal transitions cannot be
\* constructed at compile time.
\*
\* Phases (8):
\*   idle perceiving intending planning executing
\*   verifying reflecting adapting
\*
\* Legal transitions (19) per autonomous_ARCHITECTURE.md §3.2:
\*   idle       → perceiving | adapting
\*   perceiving → idle | intending
\*   intending  → planning | idle
\*   planning   → executing | intending
\*   executing  → verifying | adapting | idle
\*   verifying  → reflecting | adapting
\*   reflecting → idle | adapting | planning
\*   adapting   → planning | idle | perceiving
\*
\* This spec asserts: any reachable history is a sequence of
\* legal transitions starting at idle.

EXTENDS TLC, Naturals, Sequences, FiniteSets

CONSTANTS
    MaxHistory  \* state-space bound on chain length

Phases == { "idle", "perceiving", "intending", "planning",
            "executing", "verifying", "reflecting", "adapting" }

LegalTransitions ==
    { <<"idle", "perceiving">>, <<"idle", "adapting">>,
      <<"perceiving", "idle">>, <<"perceiving", "intending">>,
      <<"intending", "planning">>, <<"intending", "idle">>,
      <<"planning", "executing">>, <<"planning", "intending">>,
      <<"executing", "verifying">>, <<"executing", "adapting">>,
      <<"executing", "idle">>,
      <<"verifying", "reflecting">>, <<"verifying", "adapting">>,
      <<"reflecting", "idle">>, <<"reflecting", "adapting">>,
      <<"reflecting", "planning">>,
      <<"adapting", "planning">>, <<"adapting", "idle">>,
      <<"adapting", "perceiving">> }

VARIABLES
    current,
    history

vars == <<current, history>>

\* ── Type invariant ───────────────────────────────────────────────
TypeOK ==
    /\ current \in Phases
    /\ history \in Seq(Phases)
    /\ Len(history) >= 1

\* The autonomous loop always starts at idle.
StartedAtIdle ==
    Len(history) >= 1 => history[1] = "idle"

\* current is always the most recent entry of history.
CurrentMatchesHead ==
    Len(history) >= 1 => current = history[Len(history)]

\* Every consecutive pair in history is a legal transition.
OnlyLegalTransitions ==
    \A i \in 1..(Len(history) - 1) :
        <<history[i], history[i+1]>> \in LegalTransitions

\* ── Init / Next ──────────────────────────────────────────────────
Init ==
    /\ current = "idle"
    /\ history = << "idle" >>

Step(next_phase) ==
    /\ <<current, next_phase>> \in LegalTransitions
    /\ current' = next_phase
    /\ history' = Append(history, next_phase)

Next ==
    \E next_phase \in Phases : Step(next_phase)

Spec == Init /\ [][Next]_vars

BoundedHistory == Len(history) <= MaxHistory

\* ── Bug model (RFC-Q2-2) ────────────────────────────────────────
\*
\* Models the bug class where an illegal phase transition slips past
\* the OCaml-side GADT guard and reaches the runtime history. The
\* GADT in [Autonomous_phase.Transition.t : ('from, 'to_) t] makes
\* this unconstructible at the type level, but the spec verifies
\* that even if the constraint were lifted (e.g. via Obj.magic or a
\* serialisation round-trip), [OnlyLegalTransitions] catches it.

IllegalStep(next_phase) ==
    /\ next_phase \in Phases
    /\ next_phase /= current  \* skip the trivial self-loop case
    /\ <<current, next_phase>> \notin LegalTransitions
    /\ current' = next_phase
    /\ history' = Append(history, next_phase)

NextBuggy ==
    \/ Next
    \/ \E next_phase \in Phases : IllegalStep(next_phase)

SpecBuggy == Init /\ [][NextBuggy]_vars

THEOREM Spec => []TypeOK
THEOREM Spec => []StartedAtIdle
THEOREM Spec => []CurrentMatchesHead
THEOREM Spec => []OnlyLegalTransitions

====
