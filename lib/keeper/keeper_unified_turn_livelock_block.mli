(** Livelock block handling for keeper unified turns. *)

val handle
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> generation:int
  -> keeper_turn_id:int
  -> turn_id:int
  -> initial_execution:Keeper_turn_cascade_budget.cascade_execution
  -> reason:Keeper_turn_livelock.gate_reason
  -> (Keeper_types.keeper_meta, Agent_sdk.Error.sdk_error) result
