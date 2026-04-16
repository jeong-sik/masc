---- MODULE CascadeStrategy ----
\* Boundary spec for the pluggable cascade strategy system
\* (lib/cascade/cascade_strategy.{ml,mli} from Phase A #7606 +
\* Phase B #7611).
\*
\* Runtime truth being modelled:
\*   - A cascade call ranges over [Candidates] in a strategy-defined
\*     order; each candidate is attempted at most once per cycle.
\*   - When a cycle exhausts (either filtered to empty or every
\*     candidate failed), the caller advances to [cycle + 1] after
\*     [backoff_ms]; bounded by [max_cycles].
\*   - On success, the loop returns immediately.  On
\*     [cycle = max_cycles - 1] failure, it returns [Cascade_exhausted].
\*
\* What this spec deliberately abstracts away:
\*   - The actual HTTP / IO of the provider call (modelled as a
\*     non-deterministic Success/Failure choice).
\*   - The exact backoff value (the policy's monotonicity is
\*     verified in OCaml unit tests; here we only model the *fact*
\*     that some non-zero delay happens between cycles).
\*   - Sticky TTL expiry as a separate event (modelled as: the
\*     pinned provider is either available or "expired").
\*
\* The spec exists so that the safety properties below are not
\* preserved by accident — i.e. so that buggy variants of the
\* runtime would visibly violate them, per the masc-mcp Bug Model
\* convention (memory feedback_tla-spec-audit-outcome-trichotomy +
\* the BugAction / SpecBuggy pattern in software-development.md).

EXTENDS Naturals, TLC

CONSTANTS
    Candidates,        \* Set of provider keys, e.g. {"a", "b", "c"}
    MaxCycles          \* Upper bound on cycle counter

ASSUME MaxCyclesIsPos == MaxCycles \in Nat /\ MaxCycles >= 1
ASSUME CandidatesNonEmpty == Candidates # {}

VARIABLES
    cycle,             \* 0..MaxCycles  (MaxCycles == "exhausted")
    attempted,         \* set of (cycle, candidate) pairs already tried
    outcome,           \* "in_progress" | "accepted" | "exhausted"
    accepted_provider  \* the candidate that produced "accepted", or "none"

vars == << cycle, attempted, outcome, accepted_provider >>

OutcomeSet == {"in_progress", "accepted", "exhausted"}
NoneProvider == "_none_"
ASSUME NoneProvider \notin Candidates

(* ── Type invariant ─────────────────────────────────────── *)

TypeOK ==
    /\ cycle \in 0..MaxCycles
    /\ outcome \in OutcomeSet
    /\ accepted_provider \in (Candidates \cup {NoneProvider})

(* ── Initial state ──────────────────────────────────────── *)

Init ==
    /\ cycle = 0
    /\ attempted = {}
    /\ outcome = "in_progress"
    /\ accepted_provider = NoneProvider

(* ── Helpers ────────────────────────────────────────────── *)

\* Candidates not yet tried in the current cycle.
RemainingThisCycle ==
    { c \in Candidates : << cycle, c >> \notin attempted }

(* ── Actions ────────────────────────────────────────────── *)

\* Try a candidate this cycle and accept the result.  Models the
\* "Accept" branch in cascade_fsm.decide.
Accept(c) ==
    /\ outcome = "in_progress"
    /\ c \in RemainingThisCycle
    /\ outcome' = "accepted"
    /\ accepted_provider' = c
    /\ attempted' = attempted \cup { << cycle, c >> }
    /\ UNCHANGED cycle

\* Try a candidate this cycle and fail; cascade falls through.
Fail(c) ==
    /\ outcome = "in_progress"
    /\ c \in RemainingThisCycle
    /\ outcome' = outcome
    /\ accepted_provider' = accepted_provider
    /\ attempted' = attempted \cup { << cycle, c >> }
    /\ UNCHANGED cycle

\* Cycle exhausted (no candidate left this cycle).  Either advance
\* to next cycle (after backoff, modelled as pure transition) or
\* terminate with Cascade_exhausted on the last cycle.
AdvanceCycle ==
    /\ outcome = "in_progress"
    /\ RemainingThisCycle = {}
    /\ cycle + 1 < MaxCycles
    /\ cycle' = cycle + 1
    /\ UNCHANGED << attempted, outcome, accepted_provider >>

Exhaust ==
    /\ outcome = "in_progress"
    /\ RemainingThisCycle = {}
    /\ cycle + 1 >= MaxCycles
    /\ outcome' = "exhausted"
    /\ UNCHANGED << cycle, attempted, accepted_provider >>

Next ==
    \/ \E c \in Candidates : Accept(c)
    \/ \E c \in Candidates : Fail(c)
    \/ AdvanceCycle
    \/ Exhaust

\* No fairness modelled.  EventuallyTerminates would require an
\* environmental assumption that providers eventually respond for
\* every (cycle, candidate) pair, which the strategy module does
\* not own — it is enforced by per-call timeouts upstream.  We
\* therefore verify safety invariants only; liveness of the cascade
\* loop is covered by the OCaml unit tests' bounded-iteration check.

Spec == Init /\ [][Next]_vars

(* ── Safety properties ──────────────────────────────────── *)

\* The cycle counter never exceeds the configured bound.  The
\* runtime translation: cycle_loop's [n + 1 >= strategy.cycle.max_cycles]
\* check fires before we recurse, so [cycle = max_cycles] is only
\* reachable when [outcome = "exhausted"].
BoundedCycle ==
    cycle <= MaxCycles - 1

\* Once the cascade settles, attempted is non-empty (we tried
\* something) and the result is consistent.
TerminationConsistency ==
    \/ outcome = "in_progress"
    \/ /\ outcome = "accepted"
       /\ accepted_provider \in Candidates
       /\ \E c \in attempted : c[2] = accepted_provider
    \/ /\ outcome = "exhausted"
       /\ accepted_provider = NoneProvider

\* Aggregate safety invariant referenced by the .cfg INVARIANTS.
\* (NoDoubleAttempt is vacuous because [attempted] is a set, so
\* duplicate adds are absorbed at the model level.  The runtime
\* truth is that [try_cascade] consumes the remaining list by
\* recursion — verified by the OCaml unit tests, not the spec.)
Safety ==
    /\ TypeOK
    /\ BoundedCycle
    /\ TerminationConsistency

(* ──────────────────────────────────────────────────────── *)
(* Bug Model — variants that introduce a regression.         *)
(* ──────────────────────────────────────────────────────── *)

\* Bug 1 — UnboundedCycleAdvance: cycle wrap-around / off-by-one
\* would let the loop advance past MaxCycles.  Models a regression
\* where the [cycle + 1 >= max_cycles] guard is misimplemented as
\* [cycle >= max_cycles] (off-by-one), letting the loop run one
\* extra cycle.
AdvanceCycleBuggy ==
    /\ outcome = "in_progress"
    /\ RemainingThisCycle = {}
    /\ cycle' = cycle + 1                  \* no upper guard
    /\ UNCHANGED << attempted, outcome, accepted_provider >>

NextBuggy ==
    \/ \E c \in Candidates : Accept(c)
    \/ \E c \in Candidates : Fail(c)
    \/ AdvanceCycleBuggy
    \/ Exhaust

SpecBuggy == Init /\ [][NextBuggy]_vars

====
