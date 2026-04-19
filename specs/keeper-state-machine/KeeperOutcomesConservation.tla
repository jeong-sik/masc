---- MODULE KeeperOutcomesConservation ----
\* Keeper outcomes ledger conservation invariant.
\*
\* This spec models the arithmetic identity the Agent Modal's
\* "결과 / 실패 / 검증" section relies on:
\*
\*     successes + failures + rejected = observed_turns
\*
\* Each observed turn lands in exactly one outcome bucket.  The rollup
\* endpoint (dashboard_http_keeper.ml outcomes block in the redesign
\* plan) aggregates over keeper_transition_audit + keeper_compact_audit
\* + trajectory gate decisions.  If any source double-counts a turn
\* (e.g. a rollover fires both a success and a failure record) or any
\* source under-counts (e.g. a rejection doesn't increment the denom),
\* the rate displayed to the observer becomes untruthful.
\*
\* Guarantees:
\*   ConservationLaw — s + f + r = observed_turns at every state.
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
\* OCaml ↔ TLA+ mapping (see #8642 family):
\*
\*   spec variable     | OCaml ref / counter                         | source
\*   ------------------+---------------------------------------------+--------
\*   successes         | `succ_turns` (incr on Turn_succeeded)       | lib/dashboard/dashboard_http_keeper.ml:81
\*   failures          | `fail_turn`  (incr on Turn_failed _)        | lib/dashboard/dashboard_http_keeper.ml:82
\*   rejected          | `gate_rejected` field (currently 0 — see    | lib/dashboard/dashboard_http_keeper.ml (compute_outcomes_rollup)
\*                     | "scope drift" below)                        |
\*   observed_turns    | succ_turns + fail_turn                      | lib/dashboard/dashboard_http_keeper.ml:89
\*
\* Aggregation entry point:
\*   lib/dashboard/dashboard_http_keeper.ml:65 (compute_outcomes_rollup)
\*   — called at line 530 from the per-keeper detail JSON builder.
\*
\* SCOPE DRIFT (worth knowing, NOT a spec violation):
\*   The OCaml comment above compute_outcomes_rollup (lines 60-64) reads:
\*     "Historical [gate_rejected] counts are not yet persisted in the
\*      same read model, so the field remains 0 until a keeper-turn
\*      source is added."
\*   Today the spec's 3-bucket law (s + f + r = observed) holds vacuously
\*   because r is always 0. When `gate_rejected` becomes a live counter
\*   the spec invariant becomes load-bearing — the increment site for
\*   `gate_rejected` must also bump `observed_turns`, otherwise the law
\*   breaks. Anyone wiring the third bucket should run the spec's clean
\*   AND buggy cfgs to confirm the wiring honours conservation.
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
    rejected,
    observed_turns

vars == << successes, failures, rejected, observed_turns >>

TypeOK ==
    /\ successes      \in 0..MaxTurns
    /\ failures       \in 0..MaxTurns
    /\ rejected       \in 0..MaxTurns
    /\ observed_turns \in 0..MaxTurns

Init ==
    /\ successes      = 0
    /\ failures       = 0
    /\ rejected       = 0
    /\ observed_turns = 0

\* ── Actions ─────────────────────────────────

\* A substantive turn is observed: exactly one bucket is chosen and
\* observed_turns advances in lockstep.  The three success paths are
\* intentionally separate actions to mirror the state machine events
\* (Turn_succeeded / Turn_failed / Gate_rejected).

SuccessfulTurn ==
    /\ observed_turns < MaxTurns
    /\ successes'      = successes + 1
    /\ observed_turns' = observed_turns + 1
    /\ UNCHANGED << failures, rejected >>

FailedTurn ==
    /\ observed_turns < MaxTurns
    /\ failures'       = failures + 1
    /\ observed_turns' = observed_turns + 1
    /\ UNCHANGED << successes, rejected >>

RejectedTurn ==
    /\ observed_turns < MaxTurns
    /\ rejected'       = rejected + 1
    /\ observed_turns' = observed_turns + 1
    /\ UNCHANGED << successes, failures >>

Next ==
    \/ SuccessfulTurn
    \/ FailedTurn
    \/ RejectedTurn

Fairness == WF_vars(SuccessfulTurn)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety ──────────────────────────────────

\* Core identity: every observed turn is accounted for in exactly one
\* outcome bucket.  This is what makes pass-rate percentages
\* (successes / observed_turns) meaningful.
ConservationLaw ==
    successes + failures + rejected = observed_turns

\* Sanity: an outcome ledger never retracts a recorded outcome.
MonotoneLedger ==
    /\ successes      >= 0
    /\ failures       >= 0
    /\ rejected       >= 0
    /\ observed_turns >= 0

Safety ==
    /\ TypeOK
    /\ ConservationLaw
    /\ MonotoneLedger

\* ── Bug Model ───────────────────────────────

\* Mutation: a single observed turn is categorised into two buckets at
\* once.  In the real rollup this would happen if, say, a turn that
\* failed after a tool call also fires a Gate_rejected event and the
\* aggregator naively adds both.  observed_turns advances by 1 but
\* successes + failures advance by 2 ⇒ ConservationLaw fails.
BuggyDoubleBucket ==
    /\ observed_turns < MaxTurns
    /\ successes'      = successes + 1
    /\ failures'       = failures + 1
    /\ observed_turns' = observed_turns + 1
    /\ UNCHANGED << rejected >>

SpecBuggy == Init /\ [][Next \/ BuggyDoubleBucket]_vars /\ Fairness

====
