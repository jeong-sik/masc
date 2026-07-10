(** Keeper cycle execution with error-class handling. *)

val run_keeper_cycle
  :  ?event_bus:Agent_sdk.Event_bus.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> ctx:_ Keeper_types_profile.context
  -> meta_after_triage:Keeper_meta_contract.keeper_meta
  -> stop:bool Atomic.t
  -> obs:Keeper_world_observation.world_observation
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> shared_context:Agent_sdk.Context.t
  -> wake:Keeper_registry.wake_reason
  -> unit
  -> Keeper_meta_contract.keeper_meta
