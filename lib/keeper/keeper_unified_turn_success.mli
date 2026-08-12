(** Success-path post-processing for [Keeper_unified_turn]. Completion-contract
    values remain observable receipt data and never turn runtime success into a
    Keeper lifecycle failure. *)

module For_testing : sig
  type terminal_outcome =
    | Terminal_done
    | Terminal_checkpoint
    | Terminal_input_required


  val persist_terminal_turn_meta_for_outcome
    :  config:Workspace.config
    -> original_meta:Keeper_meta_contract.keeper_meta
    -> updated_meta:Keeper_meta_contract.keeper_meta
    -> terminal_outcome:terminal_outcome
    -> Keeper_meta_contract.keeper_meta

  val reset_turn_failures_for_stop_reason
    :  config:Workspace.config
    -> updated_meta:Keeper_meta_contract.keeper_meta
    -> Keeper_agent_run.run_result
    -> unit

  type cycle_post_action =
    | Assign_task
    | Empty_queue_sleep

  val post_action_of_channel
    :  Keeper_world_observation.keeper_cycle_channel
    -> cycle_post_action
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
  -> degraded_retry_applied:bool
  -> degraded_retry_runtime:string option
  -> fallback_reason:Keeper_error_classify.degraded_retry_reason option
  -> keeper_turn_id:int
  -> Keeper_execution_outcome.t
  -> handle_result
(** Common success terminal pipeline for both direct chat and autonomous
    execution. The normalized outcome declares the lane-specific consumer;
    lifecycle, durable Owner meta, projections, and terminal FSM commit here
    exactly once. *)
