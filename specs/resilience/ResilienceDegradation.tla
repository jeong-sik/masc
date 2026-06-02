---- MODULE ResilienceDegradation ----
\* Cycle 27 / Tier A11 catch-up spec.
\*
\* Models the 4-level Degradation lattice and its strategy
\* derivation, as implemented in lib/resilience/degradation.{mli,ml}.
\*
\* Levels (4):
\*   L1 — full capability (canonical strategy)
\*   L2 — reduced ambition (Retry → Fallback)
\*   L3 — minimal capability (Handoff)
\*   L4 — fallback only (Abort)
\*
\* The lattice is monotonic: degradation only increases. Once the
\* operator has authorised L4, the runtime cannot transparently
\* drop back to L1 without an explicit recovery action.
\*
\* The L4 + Permanent invariant: at the most-degraded level, a
\* permanent error must NEVER trigger Retry — Retry on a permanent
\* condition is fault-amplifying.

EXTENDS TLC, Naturals, Sequences, FiniteSets

CONSTANTS
    MaxDecisions  \* state-space bound on decision sequence

Levels == { "L1", "L2", "L3", "L4" }

ErrorModes == { "Transient", "Permanent", "ResourceExhausted",
                "Ambiguity", "Consensus", "Degradation" }

Strategies == { "Retry", "Fallback", "Handoff", "Abort" }

LevelRank ==
    [ L1 |-> 1, L2 |-> 2, L3 |-> 3, L4 |-> 4 ]

\* For the L1 canonical strategy mapping, see Recovery.default_strategy:
\*   Transient        → Retry
\*   Permanent        → Fallback or Handoff (depending on fallback)
\*   ResourceExhausted→ Fallback or Abort
\*   Ambiguity        → Handoff (no Speculate yet — A11 Speculative)
\*   Consensus        → Handoff
\*   Degradation      → Fallback (via Degradation.apply_level)

VARIABLES
    level,
    decisions       \* sequence of [level, error_mode, strategy]

vars == <<level, decisions>>

Decision == [
    level : Levels,
    error_mode : ErrorModes,
    strategy : Strategies
]

\* ── Type invariant ───────────────────────────────────────────────
TypeOK ==
    /\ level \in Levels
    /\ decisions \in Seq(Decision)

\* level is monotonic: it never drops back to a lower level.
MonotonicDegradation ==
    \A i \in 1..(Len(decisions) - 1) :
        LevelRank[decisions[i+1].level] >= LevelRank[decisions[i].level]

\* L4 + Permanent → strategy ≠ Retry. This is the safety invariant
\* that motivates Tier A11's apply_level_to_strategy.
NoRetryAtL4Permanent ==
    \A i \in 1..Len(decisions) :
        decisions[i].level = "L4" /\
        decisions[i].error_mode = "Permanent" =>
            decisions[i].strategy /= "Retry"

\* L4 also forbids Retry on ResourceExhausted (the budget is gone).
NoRetryAtL4Exhausted ==
    \A i \in 1..Len(decisions) :
        decisions[i].level = "L4" /\
        decisions[i].error_mode = "ResourceExhausted" =>
            decisions[i].strategy /= "Retry"

\* ── Init / Next ──────────────────────────────────────────────────
Init ==
    /\ level = "L1"
    /\ decisions = << >>

EscalateLevel(new_level) ==
    /\ LevelRank[new_level] >= LevelRank[level]
    /\ level' = new_level
    /\ UNCHANGED decisions

\* Apply at L1: canonical mapping — Retry for transient.
ApplyL1(emode) ==
    /\ level = "L1"
    /\ LET strategy ==
            IF emode = "Transient" THEN "Retry"
            ELSE IF emode \in { "Permanent", "Degradation" }
                 THEN "Fallback"
            ELSE "Handoff"
       IN decisions' =
            Append(decisions,
                   [ level |-> level,
                     error_mode |-> emode,
                     strategy |-> strategy ])
    /\ UNCHANGED level

\* Apply at L2: Transient demoted from Retry to Fallback.
ApplyL2(emode) ==
    /\ level = "L2"
    /\ LET strategy ==
            IF emode = "Transient" THEN "Fallback"
            ELSE IF emode = "Permanent" THEN "Fallback"
            ELSE "Handoff"
       IN decisions' =
            Append(decisions,
                   [ level |-> level,
                     error_mode |-> emode,
                     strategy |-> strategy ])
    /\ UNCHANGED level

\* Apply at L3: most things → Handoff.
ApplyL3(emode) ==
    /\ level = "L3"
    /\ decisions' =
            Append(decisions,
                   [ level |-> level,
                     error_mode |-> emode,
                     strategy |-> "Handoff" ])
    /\ UNCHANGED level

\* Apply at L4: critical — Retry forbidden. Abort or Handoff only.
ApplyL4(emode) ==
    /\ level = "L4"
    /\ LET strategy ==
            IF emode \in { "Permanent", "ResourceExhausted" }
            THEN "Abort"
            ELSE "Handoff"
       IN decisions' =
            Append(decisions,
                   [ level |-> level,
                     error_mode |-> emode,
                     strategy |-> strategy ])
    /\ UNCHANGED level

Next ==
    \/ \E new_level \in Levels : EscalateLevel(new_level)
    \/ \E emode \in ErrorModes : ApplyL1(emode)
    \/ \E emode \in ErrorModes : ApplyL2(emode)
    \/ \E emode \in ErrorModes : ApplyL3(emode)
    \/ \E emode \in ErrorModes : ApplyL4(emode)

Spec == Init /\ [][Next]_vars

BoundedDecisions == Len(decisions) <= MaxDecisions

\* ── Bug model (RFC-Q2-6) ────────────────────────────────────────
\*
\* Models the bug class where the lattice monotonicity is broken —
\* operator-authorised L4 transparently drops back to L1 without
\* an explicit recovery action. The clean EscalateLevel only allows
\* level transitions where the level index increases (or holds).
\* The bug action drops that constraint, allowing arbitrary
\* lattice regression.

LatticeRegress(new_level) ==
    /\ new_level \in Levels
    /\ new_level # level
    \* deliberately omitted: the EscalateLevel monotonicity check.
    \* Any transition is allowed, including L4 -> L1 regression.
    /\ level' = new_level
    /\ UNCHANGED decisions

NextBuggy ==
    \/ Next
    \/ \E new_level \in Levels : LatticeRegress(new_level)

SpecBuggy == Init /\ [][NextBuggy]_vars

THEOREM Spec => []TypeOK
THEOREM Spec => []MonotonicDegradation
THEOREM Spec => []NoRetryAtL4Permanent
THEOREM Spec => []NoRetryAtL4Exhausted

====
