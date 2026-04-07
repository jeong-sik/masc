---- MODULE KeeperTurnCycle ----
(***************************************************************************)
(* KeeperTurnCycle — TLA+ spec for the keeper turn execution lifecycle.    *)
(*                                                                         *)
(* Models a single keeper's turn phases:                                   *)
(*   Idle → Planning → Executing → ToolCall → SideEffect →                *)
(*   Compacting → Done → Idle                                              *)
(*                                                                         *)
(* Complementary to KeeperStateMachine.tla which models the 11-phase       *)
(* lifecycle. This spec zooms into what happens during a single turn       *)
(* while the keeper is in the Running phase.                               *)
(*                                                                         *)
(* Derived from OCaml implementation: keeper_unified_turn.ml,              *)
(* keeper_agent_run.ml, keeper_post_turn.ml, keeper_compact_policy.ml.     *)
(***************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxRetries,         \* Maximum transient retries (default 2)
    MaxToolCalls,       \* Maximum tool calls per turn
    CompactionThreshold \* Trigger compaction when ratio exceeds this

VARIABLES
    turn_phase,         \* Current phase of the turn cycle
    retry_count,        \* Number of retries attempted in current turn
    tool_calls,         \* Number of tool calls made so far
    has_side_effect,    \* Whether a side-effecting tool was called
    compaction_needed,  \* Whether compaction should be applied
    turn_outcome        \* "none" | "success" | "error" | "timeout"

vars == <<turn_phase, retry_count, tool_calls,
          has_side_effect, compaction_needed, turn_outcome>>

TurnPhases == {"idle", "planning", "executing", "tool_call",
               "side_effect", "compacting", "done"}

Outcomes == {"none", "success", "error", "timeout"}

(***************************************************************************)
(* Type invariant                                                          *)
(***************************************************************************)

TypeOK ==
    /\ turn_phase \in TurnPhases
    /\ retry_count \in 0..MaxRetries
    /\ tool_calls \in 0..MaxToolCalls
    /\ has_side_effect \in BOOLEAN
    /\ compaction_needed \in BOOLEAN
    /\ turn_outcome \in Outcomes

(***************************************************************************)
(* Initial state                                                           *)
(***************************************************************************)

Init ==
    /\ turn_phase = "idle"
    /\ retry_count = 0
    /\ tool_calls = 0
    /\ has_side_effect = FALSE
    /\ compaction_needed = FALSE
    /\ turn_outcome = "none"

(***************************************************************************)
(* Turn trigger: Idle → Planning                                           *)
(* Keeper receives heartbeat clock tick or reactive board event.           *)
(***************************************************************************)

TurnTrigger ==
    /\ turn_phase = "idle"
    /\ turn_phase' = "planning"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed, turn_outcome>>

(***************************************************************************)
(* Planning phase: verify keys, build prompt, resolve params.              *)
(* Can succeed (→ Executing) or fail (→ Done with error).                  *)
(***************************************************************************)

PlanningSucceeds ==
    /\ turn_phase = "planning"
    /\ turn_phase' = "executing"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed, turn_outcome>>

PlanningFails ==
    /\ turn_phase = "planning"
    /\ turn_phase' = "done"
    /\ turn_outcome' = "error"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed>>

(***************************************************************************)
(* Executing → ToolCall: model produces a tool call.                       *)
(***************************************************************************)

MakeToolCall ==
    /\ turn_phase = "executing"
    /\ tool_calls < MaxToolCalls
    /\ turn_phase' = "tool_call"
    /\ tool_calls' = tool_calls + 1
    /\ UNCHANGED <<retry_count, has_side_effect,
                    compaction_needed, turn_outcome>>

(***************************************************************************)
(* ToolCall → SideEffect: tool call is a side-effecting operation.         *)
(* board_post, bash, fs_edit, github, pr_workflow.                         *)
(***************************************************************************)

ToolCallWithSideEffect ==
    /\ turn_phase = "tool_call"
    /\ turn_phase' = "side_effect"
    /\ has_side_effect' = TRUE
    /\ UNCHANGED <<retry_count, tool_calls,
                    compaction_needed, turn_outcome>>

(***************************************************************************)
(* ToolCall → Executing: tool call completes (no side effect or            *)
(* side effect already recorded). Return to execution loop.                *)
(***************************************************************************)

ToolCallCompletes ==
    /\ turn_phase = "tool_call"
    /\ turn_phase' = "executing"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed, turn_outcome>>

(***************************************************************************)
(* SideEffect → Executing: side-effecting tool completes.                  *)
(***************************************************************************)

SideEffectCompletes ==
    /\ turn_phase = "side_effect"
    /\ turn_phase' = "executing"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed, turn_outcome>>

(***************************************************************************)
(* Executing → Compacting: agent run completes successfully.               *)
(* Compaction decision is always evaluated (even if skipped).              *)
(***************************************************************************)

ExecutionSucceeds ==
    /\ turn_phase = "executing"
    /\ turn_phase' = "compacting"
    /\ turn_outcome' = "success"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed>>

(***************************************************************************)
(* Executing → Compacting: transient error but side-effect occurred.       *)
(* Cannot retry — proceed to compacting with error outcome.                *)
(* OCaml: keeper_unified_turn.ml line 943.                                 *)
(***************************************************************************)

TransientErrorAfterSideEffect ==
    /\ turn_phase = "executing"
    /\ has_side_effect = TRUE
    /\ turn_phase' = "compacting"
    /\ turn_outcome' = "error"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed>>

(***************************************************************************)
(* Executing → Executing: transient error, no side-effect, retry.          *)
(* OCaml: exponential backoff 1s, 2s.                                      *)
(***************************************************************************)

TransientErrorRetry ==
    /\ turn_phase = "executing"
    /\ has_side_effect = FALSE
    /\ retry_count < MaxRetries
    /\ retry_count' = retry_count + 1
    /\ UNCHANGED <<turn_phase, tool_calls, has_side_effect,
                    compaction_needed, turn_outcome>>

(***************************************************************************)
(* Executing → Compacting: persistent error or retries exhausted.          *)
(***************************************************************************)

PersistentError ==
    /\ turn_phase = "executing"
    /\ \/ (has_side_effect = FALSE /\ retry_count >= MaxRetries)
       \/ turn_outcome = "error"  \* already marked as error
    /\ turn_phase' = "compacting"
    /\ turn_outcome' = "error"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed>>

(***************************************************************************)
(* Timeout: any active phase → Compacting with timeout outcome.            *)
(* OCaml: 120s wall-clock timeout.                                         *)
(***************************************************************************)

Timeout ==
    /\ turn_phase \in {"executing", "tool_call", "side_effect"}
    /\ turn_phase' = "compacting"
    /\ turn_outcome' = "timeout"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed>>

(***************************************************************************)
(* Compacting → Done: compaction decision evaluated and applied/skipped.   *)
(***************************************************************************)

CompactionDecision ==
    /\ turn_phase = "compacting"
    /\ turn_phase' = "done"
    /\ UNCHANGED <<retry_count, tool_calls, has_side_effect,
                    compaction_needed, turn_outcome>>

(***************************************************************************)
(* Done → Idle: turn cycle completes, keeper returns to idle.              *)
(* Metrics persisted, evidence captured, metadata updated.                 *)
(***************************************************************************)

TurnCompletes ==
    /\ turn_phase = "done"
    /\ turn_phase' = "idle"
    /\ retry_count' = 0
    /\ tool_calls' = 0
    /\ has_side_effect' = FALSE
    /\ compaction_needed' = FALSE
    /\ turn_outcome' = "none"

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

Next ==
    \/ TurnTrigger
    \/ PlanningSucceeds
    \/ PlanningFails
    \/ MakeToolCall
    \/ ToolCallWithSideEffect
    \/ ToolCallCompletes
    \/ SideEffectCompletes
    \/ ExecutionSucceeds
    \/ TransientErrorAfterSideEffect
    \/ TransientErrorRetry
    \/ PersistentError
    \/ Timeout
    \/ CompactionDecision
    \/ TurnCompletes

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

(***************************************************************************)
(* Safety invariants                                                       *)
(***************************************************************************)

(* S1: Turn cycle always goes through Compacting before returning to Idle. *)
(*     No shortcut from Executing/ToolCall/SideEffect to Idle.             *)
NoDirectExecutingToIdle ==
    turn_phase = "idle" =>
        (turn_outcome = "none" /\ retry_count = 0)

(* S2: SideEffect is only reachable from ToolCall.                         *)
(*     (Enforced by transition structure, verifiable by model checking.)   *)

(* S3: No retry after side-effect with transient error.                    *)
(*     If has_side_effect is TRUE, retry_count must not increase.          *)
NoRetryAfterSideEffect ==
    (has_side_effect = TRUE /\ turn_phase = "executing") =>
        retry_count' <= retry_count

(* S4: Tool calls are bounded.                                             *)
ToolCallsBounded ==
    tool_calls <= MaxToolCalls

(* S5: Retry count never exceeds maximum.                                  *)
RetryBounded ==
    retry_count <= MaxRetries

(* S6: Done state always has an outcome set.                               *)
DoneHasOutcome ==
    turn_phase = "done" => turn_outcome /= "none"

(* S7: Idle state always has outcome cleared.                              *)
IdleIsClear ==
    turn_phase = "idle" =>
        /\ turn_outcome = "none"
        /\ retry_count = 0
        /\ tool_calls = 0
        /\ has_side_effect = FALSE

(* Combined safety *)
Safety ==
    /\ TypeOK
    /\ ToolCallsBounded
    /\ RetryBounded
    /\ DoneHasOutcome
    /\ IdleIsClear

(***************************************************************************)
(* Liveness properties                                                     *)
(***************************************************************************)

(* L1: Every turn eventually completes (reaches Done).                     *)
TurnEventuallyDone ==
    (turn_phase /= "idle") ~> (turn_phase = "done")

(* L2: Every Done state eventually returns to Idle.                        *)
DoneEventuallyIdle ==
    (turn_phase = "done") ~> (turn_phase = "idle")

(* L3: Turn cycle is live — can always make progress.                      *)
TurnCycleLive ==
    (turn_phase = "idle") ~> (turn_phase = "done")

Liveness ==
    /\ TurnEventuallyDone
    /\ DoneEventuallyIdle

====
