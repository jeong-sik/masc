(** Keeper cycle execution with error-class handling. *)

type cycle_outcome =
  | Completed of Keeper_meta_contract.keeper_meta
  | Cancelled of Keeper_meta_contract.keeper_meta
  | Skipped of Keeper_meta_contract.keeper_meta
  | Failed of
      { meta : Keeper_meta_contract.keeper_meta
      ; failure : Keeper_unified_turn.turn_failure
      }
  | Busy of
      { meta : Keeper_meta_contract.keeper_meta
      ; block : Keeper_turn_admission.autonomous_block
      }
  | Judgment_settled of
      { meta : Keeper_meta_contract.keeper_meta
      ; outcome : failure_judgment_terminal
      }

and failure_judgment_terminal =
  | Judgment_boundary_failed of { detail : string }
  | Judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }

val meta : cycle_outcome -> Keeper_meta_contract.keeper_meta
(** Metadata projection for callers that must continue the heartbeat state
    machine independently of whether the turn completed, failed, or was not
    admitted.  Queue ownership must inspect the full {!cycle_outcome}; this
    projection alone is never completion evidence. *)

val run_keeper_cycle
  :  ?event_bus:Agent_sdk.Event_bus.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> ?continuation_delivery_channel:Keeper_continuation_channel.t
  -> ctx:_ Keeper_types_profile.context
  -> meta_after_triage:Keeper_meta_contract.keeper_meta
  -> stop:bool Atomic.t
  -> obs:Keeper_world_observation.world_observation
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> shared_context:Agent_sdk.Context.t
  -> wake:Keeper_registry.wake_reason
  -> ?failure_judgment:Keeper_event_queue.failure_judgment
  -> unit
  -> cycle_outcome
