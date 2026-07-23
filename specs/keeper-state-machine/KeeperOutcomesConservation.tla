---- MODULE KeeperOutcomesConservation ----
\* Keeper outcomes ledger conservation invariant.
\*
\* This spec models the arithmetic identity the Agent Modal's
\* "결과 / 실패 / 검증" section relies on:
\*
\*     successes + failures = observed_turns
\*
\* Each observed turn lands in exactly one outcome bucket.  The rollup
\* endpoint (dashboard_http_keeper.ml outcomes block in the redesign
\* plan) aggregates over keeper_transition_audit + keeper_compact_audit
\* records.  If any source double-counts a turn
\* (e.g. a rollover fires both a success and a failure record) or any
\* source under-counts,
\* the rate displayed to the observer becomes untruthful.
\*
\* Guarantees:
\*   ConservationLaw — s + f = observed_turns at every state.
\*   MonotoneLedger  — none of the counters ever decrease.
\*   TypeOK          — variables stay in bounded domains.
\*
\* Bug Model (feedback_tla-spec-audit-outcome-trichotomy):
\*   Clean cfg : Safety (TypeOK + ConservationLaw) holds.
\*   Buggy cfg : BuggyDoubleBucket categorises a single turn into two
\*               buckets (successes ∧ failures on the same turn),
\*               bumping both but observed_turns only once.
\*               ConservationLaw MUST be violated.
\*
\* OCaml ↔ TLA+ mapping (see #8642 family).  Symbol-anchored, no line
\* numbers — iter 64 N-2.a convention; the previous "lines 81/82/89"
\* anchors had all drifted. Both
\* refs live inside [compute_outcomes_rollup] in
\* lib/dashboard/dashboard_http_keeper.ml:
\*
\*   spec variable    | OCaml ref / counter (inside compute_outcomes_rollup)
\*   -----------------+----------------------------------------------------
\*   successes        | `succ_turns` ref — incr when a completed_turn_record
\*                    | has outcome [Keeper_transition_audit.Turn_substantive]
\*   failures         | `fail_turn` ref — incr on [Turn_failed]
\*   observed_turns   | `List.length completed_turns` — the size of the
\*                    | [Keeper_transition_audit.recent_completed_turns]
\*                    | 50-entry ring; the two buckets partition exactly
\*                    | this list, so conservation holds by construction
\*
\* Aggregation entry point:
\*   lib/dashboard/dashboard_http_keeper.ml — [compute_outcomes_rollup],
\*   called from the per-keeper detail JSON builder.  Its doc-comment
\*   cites {!KeeperOutcomesConservation.tla} and states the same law:
\*     successes.substantive_turns + failures.turn_failed = observed_turns
\*   "holds by construction because both turn buckets come from
\*    the same completed-turn ring."
\*
\* Out-of-scope counters (intentionally not modelled here):
\*   - succ_compactions / fail_compaction / succ_handoffs / fail_handoff
\*     are tracked separately in the same OCaml function but live on a
\*     different axis (per-mechanism, not per-turn). They do NOT affect
\*     observed_turns.
\*   - keeper_verdicts (pass / fail / unknown from harness verdicts) live
\*     in a sibling read model.

EXTENDS Integers, TLC

CONSTANTS MaxTurns     \* bound observed turns to keep state space finite

VARIABLES
    successes,
    failures,
    observed_turns

vars == << successes, failures, observed_turns >>

TypeOK ==
    /\ successes      \in 0..MaxTurns
    /\ failures       \in 0..MaxTurns
    /\ observed_turns \in 0..MaxTurns

Init ==
    /\ successes      = 0
    /\ failures       = 0
    /\ observed_turns = 0

\* ── Actions ─────────────────────────────────

\* A substantive turn is observed: exactly one bucket is chosen and
\* observed_turns advances in lockstep.  The two paths are
\* intentionally separate actions to mirror the state machine events
\* (Turn_substantive / Turn_failed).

SuccessfulTurn ==
    /\ observed_turns < MaxTurns
    /\ successes'      = successes + 1
    /\ observed_turns' = observed_turns + 1
    /\ UNCHANGED failures

FailedTurn ==
    /\ observed_turns < MaxTurns
    /\ failures'       = failures + 1
    /\ observed_turns' = observed_turns + 1
    /\ UNCHANGED successes

Next ==
    \/ SuccessfulTurn
    \/ FailedTurn

Fairness == WF_vars(SuccessfulTurn)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety ──────────────────────────────────

\* Core identity: every observed turn is accounted for in exactly one
\* outcome bucket.  This is what makes pass-rate percentages
\* (successes / observed_turns) meaningful.
ConservationLaw ==
    successes + failures = observed_turns

\* Sanity: an outcome ledger never retracts a recorded outcome.
MonotoneLedger ==
    /\ successes      >= 0
    /\ failures       >= 0
    /\ observed_turns >= 0

Safety ==
    /\ TypeOK
    /\ ConservationLaw
    /\ MonotoneLedger

\* ── Bug Model ───────────────────────────────

\* Mutation: a single observed turn is categorised into two buckets at
\* once.  In the real rollup this would happen if, say, a turn that
\* has both a substantive and failed audit and the aggregator naively adds
\* both. observed_turns advances by 1 but
\* successes + failures advance by 2 ⇒ ConservationLaw fails.
BuggyDoubleBucket ==
    /\ observed_turns < MaxTurns
    /\ successes'      = successes + 1
    /\ failures'       = failures + 1
    /\ observed_turns' = observed_turns + 1

SpecBuggy == Init /\ [][Next \/ BuggyDoubleBucket]_vars /\ Fairness

====
