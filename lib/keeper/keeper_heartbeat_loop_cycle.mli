(** Keeper cycle execution with error-class handling. *)

type cycle_outcome =
  | Completed of
      { meta : Keeper_meta_contract.keeper_meta
      ; continuation_route :
          Keeper_unified_turn.continuation_route_disposition
      }
  | Checkpointed of Keeper_meta_contract.keeper_meta
  | Input_required of Keeper_meta_contract.keeper_meta
  | Cancelled of Keeper_meta_contract.keeper_meta
  | Skipped of Keeper_meta_contract.keeper_meta
  | Failed of
      { meta : Keeper_meta_contract.keeper_meta
      ; failure : Keeper_unified_turn.turn_failure
      }
  | Manual_compaction_failed of
      { meta : Keeper_meta_contract.keeper_meta
      ; failure : Keeper_manual_compaction.failure
      }
  | Manual_compaction_not_applied of
      { meta : Keeper_meta_contract.keeper_meta
      ; no_compaction : Keeper_post_turn.no_compaction
      }
  | Manual_compaction_applied of
      { receipt : Keeper_manual_compaction.applied_receipt
      ; evidence : Keeper_compaction_evidence.t
        (** Checkpoint size on both sides of the compaction, carried so the
            owner projection can record what a commit saved (#29109). *)
      ; followup : cycle_outcome
      }

val meta : cycle_outcome -> Keeper_meta_contract.keeper_meta
(** Metadata projection for callers that must continue the heartbeat state
    machine independently of whether the turn completed, failed, or was not
    admitted.  Queue ownership must inspect the full {!cycle_outcome}; this
    projection alone is never completion evidence. *)

val deferred_runtime_lane :
  cycle_outcome -> Keeper_turn_driver.deferred_runtime_lane option

val run_keeper_cycle
  :  admission_token:Keeper_turn_dispatch_authority.token
  -> ?deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane
  -> ?on_deferred_runtime_consumed:(unit -> unit)
  -> ?event_bus:Agent_core.Event_bus.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> ctx:_ Keeper_types_profile.context
  -> meta_after_triage:Keeper_meta_contract.keeper_meta
  -> stop:bool Atomic.t
  -> obs:Keeper_world_observation.world_observation
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> shared_context:Agent_core.Context.t
  -> wake:Keeper_registry.wake_reason
  -> ?manual_compaction_requested:bool
  -> unit
  -> cycle_outcome
