---- MODULE KeeperDecisionPipeline ----
\* Keeper Decision Pipeline — TLA+ Formal Specification
\*
\* Models the feedback loop between Guard evaluation, Thompson Sampling,
\* and Tool Policy restriction.  Verifies that proposed damping mechanisms
\* (penalty cap per cycle + recovery floor shards) prevent death spirals.
\*
\* Key properties verified:
\*   - ToolSetNeverEmpty:          recovery floor guarantees minimum tools
\*   - RecoveryFloorMaintained:    tool_count >= RecoveryFloorSize (stronger)
\*   - PenaltyCapEnforced:         at most PenaltyCapPerCycle penalties per cycle
\*   - FailingEventuallyRecovers:  Failing always reaches Running (liveness)
\*
\* Bug model: BugRemoveRecoveryFloor demonstrates that removing the recovery
\* floor allows ToolSetNeverEmpty violation and breaks FailingEventuallyRecovers.
\*
\* Mirrors: Phase B of Keeper Decision Layer v2 plan (Rev.5)
\* OCaml mapping (E7 table, plan Part 2.5):
\*   fsm_phase                  ↔ Keeper_state_machine.DerivePhase
\*   tool_count                 ↔ |keeper_tool_policy.resolve_tools| (cardinality)
\*   thompson_alpha             ↔ Thompson_sampling.agent_stats.alpha (discretized)
\*   thompson_beta              ↔ Thompson_sampling.agent_stats.beta  (discretized)
\*   guard_penalties_this_cycle ↔ per-cycle counter (B1: guard→thompson bridge)

EXTENDS Naturals

CONSTANTS
    MaxAlpha,              \* Upper bound for Thompson alpha (state space limit)
    MaxBeta,               \* Upper bound for Thompson beta  (state space limit)
    PenaltyCapPerCycle,    \* Max guard→thompson penalties per heartbeat cycle (design: 1)
    TotalRemovableShards,  \* Removable shards (board, filesystem, shell, ...)
    RecoveryFloorSize      \* Non-removable shards (base; shard.removable = false)

ASSUME RecoveryFloorSize >= 1  \* At least one non-removable shard must exist

VARIABLES
    fsm_phase,                  \* "Running" | "Failing"
    tool_count,                 \* Total available tools (floor..max)
    thompson_alpha,             \* Beta prior: successes (discretized, min 1)
    thompson_beta,              \* Beta prior: failures  (discretized, min 1)
    guard_penalties_this_cycle, \* Per-cycle penalty counter
    turn_outcome                \* "None" | "Success" | "Failure"

vars == <<fsm_phase, tool_count, thompson_alpha, thompson_beta,
          guard_penalties_this_cycle, turn_outcome>>

MaxToolCount == TotalRemovableShards + RecoveryFloorSize

\* ── Initial State ─────────────────────────────────────────

Init ==
    /\ fsm_phase = "Running"
    /\ tool_count = MaxToolCount          \* All shards granted at start
    /\ thompson_alpha = 2                 \* Slightly positive prior
    /\ thompson_beta = 1                  \* (alpha > beta → healthy)
    /\ guard_penalties_this_cycle = 0
    /\ turn_outcome = "None"

\* ── Actions ───────────────────────────────────────────────

\* Guard fires: measurement thresholds exceeded (repetition, alignment, context).
\* Transitions to Failing; applies Thompson penalty capped per cycle.
\* Mirrors: keeper_guard.ml evaluate → Guardrail_stop event.
\*          B1: guard→thompson bridge with penalty cap.
GuardFires ==
    /\ fsm_phase \in {"Running", "Failing"}
    /\ guard_penalties_this_cycle < PenaltyCapPerCycle
    /\ thompson_beta' = IF thompson_beta < MaxBeta
                         THEN thompson_beta + 1
                         ELSE thompson_beta
    /\ guard_penalties_this_cycle' = guard_penalties_this_cycle + 1
    /\ fsm_phase' = "Failing"
    /\ UNCHANGED <<tool_count, thompson_alpha, turn_outcome>>

\* Tool restriction: Failing phase removes removable shards.
\* Recovery floor (non-removable shards) enforces a hard lower bound.
\* Mirrors: B2 — keeper_tool_policy.ml Failing → recovery_minimum_shards.
\*          tool_shard.ml: shard.removable = false → cannot be revoked.
ToolRestriction ==
    /\ fsm_phase = "Failing"
    /\ tool_count > RecoveryFloorSize     \* Floor enforced
    /\ tool_count' = tool_count - 1
    /\ UNCHANGED <<fsm_phase, thompson_alpha, thompson_beta,
                   guard_penalties_this_cycle, turn_outcome>>

\* Turn succeeds: keeper completes a task with available tools.
\* Positive Thompson signal (alpha increases).
\* Mirrors: keeper_state_machine.ml TurnSucceeded event.
TurnSucceeds ==
    /\ fsm_phase \in {"Running", "Failing"}
    /\ tool_count > 0
    /\ turn_outcome' = "Success"
    /\ thompson_alpha' = IF thompson_alpha < MaxAlpha
                          THEN thompson_alpha + 1
                          ELSE thompson_alpha
    /\ UNCHANGED <<fsm_phase, tool_count, thompson_beta,
                   guard_penalties_this_cycle>>

\* Turn fails: task not completed (insufficient tools, complexity, etc.).
\* Does NOT directly update Thompson — guard evaluation handles negatives.
\* Mirrors: keeper_state_machine.ml TurnFailed event.
TurnFails ==
    /\ fsm_phase \in {"Running", "Failing"}
    /\ tool_count > 0
    /\ turn_outcome' = "Failure"
    /\ UNCHANGED <<fsm_phase, tool_count, thompson_alpha, thompson_beta,
                   guard_penalties_this_cycle>>

\* Recovery heartbeat: successful turn clears Failing condition.
\* Mirrors: keeper_state_machine.ml HeartbeatOk clearing guardrail_triggered.
RecoveryHeartbeat ==
    /\ fsm_phase = "Failing"
    /\ turn_outcome = "Success"
    /\ fsm_phase' = "Running"
    /\ guard_penalties_this_cycle' = 0    \* Reset on recovery
    /\ UNCHANGED <<tool_count, thompson_alpha, thompson_beta, turn_outcome>>

\* Shard restoration: Running keeper with positive score regains shards.
\* Mirrors: B2 — tool_shard.grant_shard on improved performance.
ShardRestoration ==
    /\ fsm_phase = "Running"
    /\ tool_count < MaxToolCount
    /\ thompson_alpha > thompson_beta     \* Positive Thompson score
    /\ tool_count' = tool_count + 1
    /\ UNCHANGED <<fsm_phase, thompson_alpha, thompson_beta,
                   guard_penalties_this_cycle, turn_outcome>>

\* Cycle boundary: heartbeat cycle advances, per-cycle penalty counter resets.
NewCycle ==
    /\ guard_penalties_this_cycle > 0
    /\ guard_penalties_this_cycle' = 0
    /\ UNCHANGED <<fsm_phase, tool_count, thompson_alpha, thompson_beta,
                   turn_outcome>>

\* ── Next State ────────────────────────────────────────────

Next ==
    \/ GuardFires
    \/ ToolRestriction
    \/ TurnSucceeds
    \/ TurnFails
    \/ RecoveryHeartbeat
    \/ ShardRestoration
    \/ NewCycle

\* ── Bug Model ─────────────────────────────────────────────

\* BUG: Recovery floor removed — tool_count can drop below RecoveryFloorSize.
\* Models: revoke_shard ignoring removable=false, or recovery_minimum_shards
\* not enforced in Failing phase.
\* Consequence: tool_count reaches 0 → TurnSucceeds permanently disabled
\*              → RecoveryHeartbeat never fires → Failing forever (death spiral).
BugRemoveRecoveryFloor ==
    /\ fsm_phase = "Failing"
    /\ tool_count > 0
    \* BUG: ignores RecoveryFloorSize, removes shard below floor
    /\ tool_count' = tool_count - 1
    /\ UNCHANGED <<fsm_phase, thompson_alpha, thompson_beta,
                   guard_penalties_this_cycle, turn_outcome>>

NextBuggy ==
    \/ Next
    \/ BugRemoveRecoveryFloor

\* ── Fairness ──────────────────────────────────────────────

Fairness ==
    /\ WF_vars(TurnSucceeds)           \* Turns eventually succeed if tools available
    /\ SF_vars(RecoveryHeartbeat)      \* Strong fairness: recovery fires even if
                                        \* intermittently disabled by guard/turn events.
                                        \* Justified: heartbeat runs on periodic timer,
                                        \* independent of guard evaluation order.
    /\ WF_vars(NewCycle)               \* Heartbeat cycles advance
    /\ WF_vars(ShardRestoration)       \* Shards restored when score positive

Spec == Init /\ [][Next]_vars /\ Fairness

SpecBuggy == Init /\ [][NextBuggy]_vars /\ Fairness

\* ── Safety Properties ─────────────────────────────────────

\* S1: Tool set never completely empty.
\* Recovery floor (non-removable shards) always provides minimum tools.
\* Clean: satisfied — ToolRestriction stops at RecoveryFloorSize.
\* Buggy: violated — BugRemoveRecoveryFloor bypasses floor → tool_count = 0.
ToolSetNeverEmpty == tool_count > 0

\* S2: Recovery floor maintained — stronger than S1.
\* tool_count never drops below non-removable shard count.
RecoveryFloorMaintained == tool_count >= RecoveryFloorSize

\* S3: Guard penalty bounded per heartbeat cycle.
\* Prevents rapid Thompson degradation from consecutive guard firings.
PenaltyCapEnforced == guard_penalties_this_cycle <= PenaltyCapPerCycle

\* ── Type Invariant ────────────────────────────────────────

TypeOK ==
    /\ fsm_phase \in {"Running", "Failing"}
    /\ tool_count \in 0..MaxToolCount
    /\ thompson_alpha \in 1..MaxAlpha
    /\ thompson_beta \in 1..MaxBeta
    /\ guard_penalties_this_cycle \in 0..PenaltyCapPerCycle
    /\ turn_outcome \in {"None", "Success", "Failure"}

\* ── Liveness Properties ───────────────────────────────────

\* L1: Failing eventually recovers to Running.
\* Proof sketch (clean model):
\*   1. tool_count >= RecoveryFloorSize > 0 always         (S1, ASSUME)
\*   2. TurnSucceeds enabled (tool_count > 0) and fair     (WF)
\*   3. turn_outcome = "Success" eventually                 (WF step 2)
\*   4. RecoveryHeartbeat enabled and fair                  (WF)
\*   5. fsm_phase = "Running"                               (WF step 4)
\*
\* Buggy model: at tool_count = 0, TurnSucceeds is permanently disabled,
\* breaking step 2. Failing persists forever → liveness violation.
FailingEventuallyRecovers == (fsm_phase = "Failing") ~> (fsm_phase = "Running")

====
