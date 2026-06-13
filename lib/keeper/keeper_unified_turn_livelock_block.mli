(** Livelock block handling for keeper unified turns. *)

val handle
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> generation:int
  -> keeper_turn_id:int
  -> turn_id:int
  -> initial_execution:Keeper_turn_runtime_budget.runtime_execution
  -> reason:Keeper_turn_livelock.gate_reason
  -> (Keeper_meta_contract.keeper_meta, Agent_sdk.Error.sdk_error) result
