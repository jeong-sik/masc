(** Keeper cycle execution with error-class handling. *)

val run_keeper_cycle
  :  ctx:_ Keeper_types_profile.context
  -> meta_after_cursor_persist:Keeper_meta_contract.keeper_meta
  -> stop:bool Atomic.t
  -> obs:Keeper_world_observation.world_observation
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> shared_context:Agent_sdk.Context.t
  -> holder_wait_ms:int
  -> unit
  -> Keeper_meta_contract.keeper_meta
