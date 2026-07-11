(** Keeper cycle execution with error-class handling. *)

type cycle_outcome =
  | Completed of Keeper_meta_contract.keeper_meta
  | Failed of
      { meta : Keeper_meta_contract.keeper_meta
      ; error : Agent_sdk.Error.sdk_error
      }
  | Busy of
      { meta : Keeper_meta_contract.keeper_meta
      ; block : Keeper_turn_admission.autonomous_block
      }

val meta : cycle_outcome -> Keeper_meta_contract.keeper_meta
(** Metadata projection for callers that must continue the heartbeat state
    machine independently of whether the turn completed, failed, or was not
    admitted.  Queue ownership must inspect the full {!cycle_outcome}; this
    projection alone is never completion evidence. *)

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
  -> cycle_outcome
