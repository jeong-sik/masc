---- MODULE Bounded ----
\* Boundary spec for the bounded execution loop (lib/bounded.ml).
\*
\* Source declares formal-verification intent up front (lib/bounded.ml:3-9):
\*
\*     Provides formal guarantees:
\*     - Termination: Always terminates via hard_max_iterations
\*     - Safety: Post-check prevents silent constraint violations
\*     - Soundness: Typed comparisons with explicit error handling
\*
\* This spec encodes the two contracts the source can be held to with
\* small finite state: termination via the hard ceiling, and the
\* predictive token-budget check that prevents silent overshoot. The
\* full retry/cost/time axes are deliberately out of scope here -- they
\* would balloon the state space without surfacing additional bug
\* classes. A follow-up spec can grow them once these invariants are
\* paid for.
\*
\* Source loop (lib/bounded.ml:296-320):
\*
\*     let rec loop () =
\*       if state.turns >= constraints.hard_max_iterations then
\*         { status = `Constraint_exceeded; ... }
\*       else
\*         match check_constraints_with_buffer state with
\*         | Some reason -> { status = `Constraint_exceeded; ... }
\*         | None -> ... advance turn ...
\*
\* Bug Model (memory: TLA+ Bug Model pattern):
\*   Spec       (clean): Step advances only when both gates allow.
\*   SpecBuggy:
\*       SkipHardLimit   - turns increments past hard_max -> Termination violated
\*       BudgetBypass    - tokens grow past max_tokens -> TokenBudget violated
\*
\* Reference: issue #11522 Phase 4 (MED candidate).

EXTENDS TLC, Naturals

CONSTANTS
    HardMax,       \* hard_max_iterations
    MaxTokens,     \* constraints.max_tokens (Some n)
    Buffer         \* token_buffer for predictive check

VARIABLES
    turns,         \* state.turns
    tokens,        \* total tokens accumulated so far
    status         \* {"running", "completed", "constraint_exceeded"}

vars == << turns, tokens, status >>

StatusSet == {"running", "completed", "constraint_exceeded"}

\* TokensMax bounds the variable for TLC. We allow one slot above the
\* contract limit so the buggy spec can drive the system across the
\* line and the invariant can detect it.
TokensMax == MaxTokens + Buffer + 1

TypeOK ==
    /\ turns \in 0..(HardMax + 1)
    /\ tokens \in 0..TokensMax
    /\ status \in StatusSet

Init ==
    /\ turns = 0
    /\ tokens = 0
    /\ status = "running"

\* Predictive guard: the source checks [tokens + buffer <= max_tokens]
\* before consuming a turn. The model exposes the same predicate.
PredictiveOk(extra) ==
    tokens + extra + Buffer <= MaxTokens

\* A clean step: status running, hard ceiling not yet reached, the
\* predictive guard would still hold after [extra] tokens. Mirrors the
\* OCaml branch where both gates pass.
Step(extra) ==
    /\ status = "running"
    /\ turns < HardMax
    /\ extra \in 1..(MaxTokens - tokens - Buffer)
    /\ PredictiveOk(extra)
    /\ turns' = turns + 1
    /\ tokens' = tokens + extra
    /\ UNCHANGED << status >>

\* Hard limit hit: source returns Constraint_exceeded.
HitHardLimit ==
    /\ status = "running"
    /\ turns >= HardMax
    /\ status' = "constraint_exceeded"
    /\ UNCHANGED << turns, tokens >>

\* Predictive guard fired: source returns Constraint_exceeded before
\* consuming the turn. The model permits this transition whenever
\* PredictiveOk would fail for any positive extra.
HitBudgetGuard ==
    /\ status = "running"
    /\ tokens + Buffer >= MaxTokens
    /\ status' = "constraint_exceeded"
    /\ UNCHANGED << turns, tokens >>

\* The loop returned a normal completion result before either guard
\* fired (caller decided to stop). Counters frozen.
Complete ==
    /\ status = "running"
    /\ status' = "completed"
    /\ UNCHANGED << turns, tokens >>

Next ==
    \/ \E extra \in 1..(MaxTokens - tokens - Buffer) : Step(extra)
    \/ HitHardLimit
    \/ HitBudgetGuard
    \/ Complete

Spec == Init /\ [][Next]_vars

\* ── Invariants ────────────────────────────────────────────────────────────

\* I1 Termination. The hard ceiling is binding. turns NEVER exceeds
\* hard_max_iterations; the post-check returns Constraint_exceeded if
\* the loop would have crossed it.
Termination ==
    turns <= HardMax

\* I2 TokenBudget. Cumulative tokens stay at or below max_tokens. The
\* predictive check uses [tokens + buffer], so a clean run can land at
\* any value <= MaxTokens; what is forbidden is overshoot past
\* MaxTokens itself.
TokenBudget ==
    tokens <= MaxTokens

\* ── Bug actions (used only by SpecBuggy) ──────────────────────────────────

\* B1 SkipHardLimit. Refactor drops the [turns >= hard_max] check.
\* turns crosses HardMax in one step -> Termination violated.
SkipHardLimit(extra) ==
    /\ status = "running"
    /\ turns = HardMax
    /\ extra \in 1..(MaxTokens - tokens)
    /\ turns' = turns + 1
    /\ tokens' = tokens + extra
    /\ UNCHANGED << status >>

\* B2 BudgetBypass. Refactor drops the predictive check
\* [check_constraints_with_buffer]. tokens overshoots MaxTokens ->
\* TokenBudget violated.
BudgetBypass(extra) ==
    /\ status = "running"
    /\ tokens >= MaxTokens
    /\ extra \in 1..(TokensMax - tokens - 1)
    /\ turns < HardMax
    /\ turns' = turns + 1
    /\ tokens' = tokens + extra
    /\ UNCHANGED << status >>

NextBuggy ==
    \/ Next
    \/ \E extra \in 1..(MaxTokens - tokens) : SkipHardLimit(extra)
    \/ \E extra \in 1..(TokensMax - tokens - 1) : BudgetBypass(extra)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
