(** Keeper cycle execution under slot control with error-class handling. *)

val run_keeper_cycle_with_slot
  :  ctx:_ Keeper_types.context
  -> meta_after_cursor_persist:Keeper_types.keeper_meta
  -> stop:bool Atomic.t
  -> obs:Keeper_world_observation.world_observation
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> shared_context:Agent_sdk.Context.t
  -> semaphore_wait_ms:int
  -> slot_control:Keeper_turn_slot.keeper_turn_slot_control
  -> ?selected_item:string * Cascade_ref.cascade_item
  -> unit
  -> Keeper_types.keeper_meta
