(** Success-path post-processing for [Keeper_unified_turn]. Completion-contract
    values remain observable receipt data and never turn runtime success into a
    Keeper lifecycle failure. *)

module For_testing : sig
  type terminal_outcome =
    | Terminal_done
    | Terminal_checkpoint
    | Terminal_input_required

  val terminal_outcome_of_result : Keeper_agent_run.run_result -> terminal_outcome
  val terminal_outcome_is_completed_turn : terminal_outcome -> bool

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

  val acknowledge_pending_messages
    :  Keeper_meta_contract.keeper_meta
    -> Keeper_world_observation.world_observation
    -> Keeper_meta_contract.keeper_meta
end

type handle_result =
  | Completed of Keeper_meta_contract.keeper_meta
(** Final runtime-success turn state. *)

val handle
  :  config:Workspace.config
  -> base_dir:string
  -> meta:Keeper_meta_contract.keeper_meta
  -> turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> observation:Keeper_world_observation.world_observation
  -> final_execution:Keeper_turn_runtime_budget.runtime_execution
  -> latency_ms:int
  -> degraded_retry_applied:bool
  -> degraded_retry_runtime:string option
  -> fallback_reason:Keeper_error_classify.degraded_retry_reason option
  -> current_turn_blocker_info:Keeper_meta_contract.blocker_info option
  -> keeper_turn_id:int
  -> Keeper_agent_run.run_result
  -> handle_result
