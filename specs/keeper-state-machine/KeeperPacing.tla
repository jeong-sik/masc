---- MODULE KeeperPacing ----
\* RFC-0313 W0 — Keeper Existence Invariance.
\*
\* Models the pacing-only failure discipline: a turn failure may change
\* WHEN the next turn runs (per-runtime revisit deadline) and WHERE it
\* runs (which runtime is eligible first), but never WHETHER the keeper
\* exists. Existence is owned by exactly two axes, each with its own
\* owner:
\*
\*   intent  — operator only:  registered / operator_paused / shutdown
\*   fiber   — process reality: alive / dead (relaunch is always available
\*             while intent /= shutdown; the implementation paces relaunch
\*             through the same revisit mechanism, which never blocks it
\*             permanently)
\*
\* Failure actions write only [eligible_at]: a nondeterministic delay
\* d \in 1..MaxBackoff covers exponential widening and provider
\* retry_after alike; MaxBackoff is the config cap. Deterministic errors
\* (Escalate_judgment route) have the same state effect here — they add
\* a judgment stimulus elsewhere but touch neither intent nor fiber.
\*
\* Guarantees:
\*   NoFailureDrivenExistenceChange — no failure transition flips intent
\*       or fiber (tracked by the [failure_touched_existence] history
\*       variable; only bug-model actions can set it).
\*   PacingBounded — every revisit deadline stays within now + MaxBackoff:
\*       the typed equivalent of "no terminal state exists in pacing".
\*       A keeper that is registered+alive therefore always has a finite
\*       next-turn due time (min over eligible_at).
\*   TypeOK — domains.
\*
\* Bug Model (feedback_tla-spec-audit-outcome-trichotomy):
\*   Clean cfg            : Safety (TypeOK + both invariants) passes.
\*   -buggy cfg           : BuggyFailureSetsPaused models today's streak
\*                          auto-pause (a failure flips the paused axis).
\*                          NoFailureDrivenExistenceChange MUST be violated.
\*   -buggy-unbounded cfg : BuggyUnboundedBackoff models restart-budget
\*                          DEAD / tombstone: a failure pushes the revisit
\*                          deadline past the cap — a de-facto terminal
\*                          state. PacingBounded MUST be violated.
\*   If either buggy cfg passes, the corresponding invariant is too weak
\*   and must be strengthened before relying on it.
\*
\* Implementation mapping (spec <-> runtime, cited by symbol anchor —
\* line numbers drift):
\*
\*   To be replaced (the ladder this spec forbids):
\*     lib/keeper/keeper_unified_turn_failure.ml —
\*       [record_failure_and_maybe_escalate]'s [runtime_auto_paused] /
\*       [completion_contract_auto_paused] / [idle_detected_auto_paused]
\*       arms (streak >= turn_fail_streak_threshold -> paused=true) and
\*       the [count >= threshold -> raise Keeper_fiber_crash] escalation.
\*     lib/keeper/keeper_supervisor.ml — [queue_crashed_entry]'s
\*       restart-budget exhaustion arm ([to_mark_dead]).
\*
\*   To be introduced (W1): lib/keeper/keeper_pacing.mli —
\*     [on_failure] maps to TurnFailure (per-runtime widening, capped;
\*     provider retry_after wins), [on_success] maps to TurnSuccess
\*     (clears the runtime's revisit), [next_turn_due] = min eligible_at
\*     over the catalog, starting from the configured base runtime
\*     (return-to-base already holds on main: rotation is not persisted,
\*     every turn restarts from the runtime.toml assignment).
\*
\*   Kept as-is: operator pause/resume (the only pause), fiber relaunch
\*     (supervisor), the HITL ambiguous-partial-commit gate (operator
\*     intent acquisition, not failure-driven existence change).
\*
\* Evidence driving the invariants: 2026-07-06 storm fixture
\* (test/fixtures/pacing_storm_20260706/) — 2,004 rotation retries in
\* 300s ping-ponging between two saturated runtimes with zero revisit
\* spacing, suppressed at the time by existence changes (auto-pause).
\*
\* Out of scope here (sibling specs):
\*   - phase selection / FSM shape (KeeperStateMachine, KeeperTurnFSM)
\*   - circuit breaker counting (KeeperCircuitBreaker)
\*   - operator pause broadcast fan-out (OperatorPauseBroadcast)

EXTENDS Integers, TLC

CONSTANTS
    Runtimes,     \* model values: the keeper's runtime catalog
    MaxTime,      \* clock bound (state-space cap)
    MaxBackoff    \* revisit widening cap (config cap in the impl)

VARIABLES
    intent,                      \* operator-owned existence axis
    fiber,                       \* process-reality existence axis
    eligible_at,                 \* [Runtimes -> deadline] pacing map
    now,                         \* bounded clock
    failure_touched_existence    \* history: TRUE iff a failure changed an existence axis

vars == << intent, fiber, eligible_at, now, failure_touched_existence >>

Intents == {"registered", "operator_paused", "shutdown"}
Fibers  == {"alive", "dead"}

\* Domain leaves headroom (+1) so the buggy-unbounded action stays inside
\* TypeOK and is caught by PacingBounded — the invariant under test —
\* rather than by a domain error.
DeadlineDomain == 0..(MaxTime + MaxBackoff + 1)

TypeOK ==
    /\ intent \in Intents
    /\ fiber \in Fibers
    /\ eligible_at \in [Runtimes -> DeadlineDomain]
    /\ now \in 0..MaxTime
    /\ failure_touched_existence \in BOOLEAN

Init ==
    /\ intent = "registered"
    /\ fiber = "alive"
    /\ eligible_at = [r \in Runtimes |-> 0]
    /\ now = 0
    /\ failure_touched_existence = FALSE

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED << intent, fiber, eligible_at, failure_touched_existence >>

\* A runtime is turnable when the keeper exists on both axes and the
\* runtime's revisit deadline has passed.
Turnable(r) ==
    /\ intent = "registered"
    /\ fiber = "alive"
    /\ eligible_at[r] <= now

TurnSuccess(r) ==
    /\ Turnable(r)
    /\ eligible_at' = [eligible_at EXCEPT ![r] = now]
    /\ UNCHANGED << intent, fiber, now, failure_touched_existence >>

\* Any failure class — transient, provider-bound, or deterministic
\* (escalated for judgment) — may only widen this runtime's revisit.
TurnFailure(r) ==
    /\ Turnable(r)
    /\ \E d \in 1..MaxBackoff :
         eligible_at' = [eligible_at EXCEPT ![r] = now + d]
    /\ UNCHANGED << intent, fiber, now, failure_touched_existence >>

OperatorPause ==
    /\ intent = "registered"
    /\ intent' = "operator_paused"
    /\ UNCHANGED << fiber, eligible_at, now, failure_touched_existence >>

OperatorResume ==
    /\ intent = "operator_paused"
    /\ intent' = "registered"
    /\ UNCHANGED << fiber, eligible_at, now, failure_touched_existence >>

OperatorShutdown ==
    /\ intent /= "shutdown"
    /\ intent' = "shutdown"
    /\ UNCHANGED << fiber, eligible_at, now, failure_touched_existence >>

FiberDies ==
    /\ fiber = "alive"
    /\ fiber' = "dead"
    /\ UNCHANGED << intent, eligible_at, now, failure_touched_existence >>

\* Relaunch is always available while not shut down — there is no
\* restart budget and no DEAD state to fall into.
Relaunch ==
    /\ fiber = "dead"
    /\ intent /= "shutdown"
    /\ fiber' = "alive"
    /\ UNCHANGED << intent, eligible_at, now, failure_touched_existence >>

Next ==
    \/ Tick
    \/ \E r \in Runtimes : TurnSuccess(r) \/ TurnFailure(r)
    \/ OperatorPause
    \/ OperatorResume
    \/ OperatorShutdown
    \/ FiberDies
    \/ Relaunch

Spec == Init /\ [][Next]_vars

----
\* Invariants

\* No failure transition may change an existence axis. Trivial in the
\* clean spec (no clean action sets the flag) — its strength is proven
\* by the -buggy cfg, which MUST violate it.
NoFailureDrivenExistenceChange == failure_touched_existence = FALSE

\* Every revisit deadline stays within the cap: pacing has no terminal
\* value, so a registered+alive keeper always has a finite next turn.
PacingBounded == \A r \in Runtimes : eligible_at[r] <= now + MaxBackoff

Safety == TypeOK /\ NoFailureDrivenExistenceChange /\ PacingBounded

----
\* Bug models

\* Models keeper_unified_turn_failure.ml's streak auto-pause arms:
\* a turn failure flips the paused existence axis.
BuggyFailureSetsPaused(r) ==
    /\ Turnable(r)
    /\ intent' = "operator_paused"
    /\ failure_touched_existence' = TRUE
    /\ \E d \in 1..MaxBackoff :
         eligible_at' = [eligible_at EXCEPT ![r] = now + d]
    /\ UNCHANGED << fiber, now >>

NextBuggy == Next \/ \E r \in Runtimes : BuggyFailureSetsPaused(r)

SpecBuggy == Init /\ [][NextBuggy]_vars

\* Models restart-budget DEAD / wake tombstones: a failure pushes the
\* revisit deadline past the cap — a de-facto terminal state expressed
\* as pacing.
BuggyUnboundedBackoff(r) ==
    /\ Turnable(r)
    /\ eligible_at' = [eligible_at EXCEPT ![r] = now + MaxBackoff + 1]
    /\ UNCHANGED << intent, fiber, now, failure_touched_existence >>

NextBuggyUnbounded == Next \/ \E r \in Runtimes : BuggyUnboundedBackoff(r)

SpecBuggyUnbounded == Init /\ [][NextBuggyUnbounded]_vars

====
