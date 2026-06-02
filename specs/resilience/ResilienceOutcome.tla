---- MODULE ResilienceOutcome ----
\* Cycle 19 / Tier I5 catch-up spec.
\*
\* Models the ternary outcome GADT exposed by
\* lib/shared_types/resilience_outcome.{mli,ml}:
\*
\*   FullSuccess { value, confidence, artifacts }
\*   PartialSuccess { value, completed, failed, confidence, degradation_level }
\*   GracefulFailure { fallback, reason, recovery_strategy, confidence }
\*
\* This spec captures the well-formedness invariants that hold
\* across constructor sites and field updates:
\*
\*   - confidence is in [0, 1] (modelled as a denominator / max ratio)
\*   - degradation_level is in [1, 4] (PartialSuccess only)
\*   - completed and failed artifact sets are disjoint
\*   - the recovery_strategy field of GracefulFailure is non-empty
\*
\* OCaml <-> TLA+ mapping:
\*
\*   variable                | OCaml site
\*   ------------------------+--------------------------------------------------
\*   outcomes                | a snapshot list of outcome records that callers
\*                           | have produced; runtime does not own a registry.
\*
\*   record fields (per-class)
\*     class                 | "full" | "partial" | "graceful"
\*     confidence_num        | Confidence.to_float * confidence_den
\*     degradation_level     | Resilience_outcome.PartialSuccess.degradation_level
\*     completed             | Resilience_outcome.PartialSuccess.completed (artifact ids)
\*     failed                | keys of Resilience_outcome.PartialSuccess.failed list
\*     recovery_strategy     | Resilience_outcome.GracefulFailure.recovery_strategy

EXTENDS TLC, Naturals, Sequences, FiniteSets

CONSTANTS
    ArtifactIds,    \* finite universe of artifact ids
    Strategies      \* finite universe of recovery_strategy strings (non-empty)

\* Confidence is modelled as confidence_num / confidence_den, with
\* confidence_den fixed at 100 so the legal range is [0, 100].
ConfidenceMax == 100

OutcomeClass == {"full", "partial", "graceful"}

Outcome == [
    class : OutcomeClass,
    confidence_num : 0..ConfidenceMax,
    degradation_level : 1..4,
    completed : SUBSET ArtifactIds,
    failed : SUBSET ArtifactIds,
    recovery_strategy : Strategies
]

VARIABLES
    outcomes        \* finite sequence of Outcome values produced so far

vars == <<outcomes>>

\* ── Type invariant ───────────────────────────────────────────────
\* outcomes is a finite sequence (Seq) of Outcome records. We
\* bound the sequence length via a separate model constant in
\* the .cfg if needed; here we rely on Init starting empty and
\* AppendOutcome adding one at a time.
TypeOK ==
    \A i \in 1..Len(outcomes) :
        outcomes[i] \in Outcome

\* ── Per-class well-formedness ────────────────────────────────────
ConfidenceInRange ==
    \A i \in 1..Len(outcomes) :
        outcomes[i].confidence_num >= 0
        /\ outcomes[i].confidence_num <= ConfidenceMax

DegradationLevelInRange ==
    \A i \in 1..Len(outcomes) :
        outcomes[i].degradation_level >= 1
        /\ outcomes[i].degradation_level <= 4

CompletedFailedDisjoint ==
    \A i \in 1..Len(outcomes) :
        outcomes[i].class # "partial" \/
        outcomes[i].completed \cap outcomes[i].failed = {}

RecoveryStrategyDeclared ==
    \A i \in 1..Len(outcomes) :
        outcomes[i].class # "graceful" \/
        outcomes[i].recovery_strategy \in Strategies

\* ── Init / Next ──────────────────────────────────────────────────
Init ==
    outcomes = << >>

(* Construct a candidate outcome with arbitrary chosen field
   values, gated on the per-class semantics. The spec forbids
   ill-formed candidates from being appended; runtime enforces
   the same via constructor-site validation. *)
AppendFull(conf, arts) ==
    /\ conf \in 0..ConfidenceMax
    /\ arts \subseteq ArtifactIds
    /\ outcomes' =
        Append(outcomes,
               [ class |-> "full",
                 confidence_num |-> conf,
                 degradation_level |-> 1,
                 completed |-> arts,
                 failed |-> {},
                 recovery_strategy |-> CHOOSE s \in Strategies : TRUE ])

AppendPartial(conf, completed, failed, level) ==
    /\ conf \in 0..ConfidenceMax
    /\ completed \subseteq ArtifactIds
    /\ failed \subseteq ArtifactIds
    /\ completed \cap failed = {}
    /\ level \in 1..4
    /\ outcomes' =
        Append(outcomes,
               [ class |-> "partial",
                 confidence_num |-> conf,
                 degradation_level |-> level,
                 completed |-> completed,
                 failed |-> failed,
                 recovery_strategy |-> CHOOSE s \in Strategies : TRUE ])

AppendGraceful(conf, strategy) ==
    /\ conf \in 0..ConfidenceMax
    /\ strategy \in Strategies
    /\ outcomes' =
        Append(outcomes,
               [ class |-> "graceful",
                 confidence_num |-> conf,
                 degradation_level |-> 1,
                 completed |-> {},
                 failed |-> {},
                 recovery_strategy |-> strategy ])

Next ==
    \/ \E conf \in {0, 50, 100}, arts \in SUBSET ArtifactIds :
            AppendFull(conf, arts)
    \/ \E conf \in {0, 50, 100},
          completed \in SUBSET ArtifactIds,
          failed \in SUBSET ArtifactIds,
          level \in 1..4 :
            AppendPartial(conf, completed, failed, level)
    \/ \E conf \in {0, 50, 100}, strategy \in Strategies :
            AppendGraceful(conf, strategy)

Spec == Init /\ [][Next]_vars

\* ── Bug model (RFC-Q2-7) ────────────────────────────────────────
\*
\* Models the bug class where the caller computes [completed] and
\* [failed] artifact sets without enforcing disjointness — e.g. a
\* shared mutable state mutation lets the same artifact id land in
\* both. The clean AppendPartial enforces completed \cap failed = {}
\* at the precondition; the bug action drops that check.

AppendPartialNonDisjoint(conf, completed, failed, level) ==
    /\ conf \in 0..ConfidenceMax
    /\ completed \subseteq ArtifactIds
    /\ failed \subseteq ArtifactIds
    \* deliberately omitted: completed \cap failed = {}
    /\ completed \cap failed # {}  \* force overlap to actually happen
    /\ level \in 1..4
    /\ outcomes' =
        Append(outcomes,
               [ class |-> "partial",
                 confidence_num |-> conf,
                 degradation_level |-> level,
                 completed |-> completed,
                 failed |-> failed,
                 recovery_strategy |-> CHOOSE s \in Strategies : TRUE ])

NextBuggy ==
    \/ Next
    \/ \E conf \in {0, 50, 100},
          completed \in SUBSET ArtifactIds,
          failed \in SUBSET ArtifactIds,
          level \in 1..4 :
            AppendPartialNonDisjoint(conf, completed, failed, level)

SpecBuggy == Init /\ [][NextBuggy]_vars

\* State-space bound for TLC: keep the outcomes sequence small
\* enough to enumerate exhaustively. Wired in via the .cfg
\* CONSTRAINT clause.
BoundedOutcomes == Len(outcomes) <= 2

THEOREM Spec => []TypeOK
THEOREM Spec => []ConfidenceInRange
THEOREM Spec => []DegradationLevelInRange
THEOREM Spec => []CompletedFailedDisjoint
THEOREM Spec => []RecoveryStrategyDeclared

====
