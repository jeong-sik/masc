(** Success-path post-processing for [Keeper_unified_turn]. Completion-contract
    values remain observable receipt data and never turn runtime success into a
    Keeper lifecycle failure. *)

module For_testing : sig
  val persist_terminal_turn_meta
    :  config:Workspace.config
    -> original_meta:Keeper_meta_contract.keeper_meta
    -> updated_meta:Keeper_meta_contract.keeper_meta
    -> Keeper_meta_contract.keeper_meta

  val reset_turn_failures_for_stop_reason
    :  config:Workspace.config
    -> updated_meta:Keeper_meta_contract.keeper_meta
    -> Keeper_agent_run.run_result
    -> unit
end

type handle_result =
  | Completed of Keeper_meta_contract.keeper_meta
(** Final runtime-success turn state. *)

val handle
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> observation:Keeper_world_observation.world_observation
  -> latency_ms:int
  -> degraded_retry_applied:Keeper_error_classify.degraded_retry option
  -> degraded_retry_deferred:Keeper_error_classify.degraded_retry option
     (* Both come from [Keeper_agent_result.turn_settlement], which is the only
        place they are decided. The bool that used to sit here carried a
        different fact on each lane. *)
  -> keeper_turn_id:int
  -> spend:Keeper_turn_spend.attempt list
     (* Every attempt's readings, from the same settlement: the turn's
        resolution is the one its result reports, and the rest is spend
        beside it. *)
  -> settled_start:Keeper_unsettled_spend.settled_start option
     (* From the same settlement. Handed to
        [Keeper_unsettled_spend.record_committed] when the Owner commit holds
        and every reading the turn holds has a resolved row in the file. *)
  -> Keeper_execution_outcome.t
  -> handle_result
(** Common success terminal pipeline for both direct chat and autonomous
    execution. The normalized outcome declares the lane-specific consumer;
    lifecycle, durable Owner meta, projections, and terminal FSM commit here
    exactly once. *)
