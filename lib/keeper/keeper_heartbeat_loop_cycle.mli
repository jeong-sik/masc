(** Keeper cycle execution with error-class handling. *)

type cycle_outcome =
  | Completed of
      { meta : Keeper_meta_contract.keeper_meta
      ; continuation_route :
          Keeper_unified_turn.continuation_route_disposition
      }
  | Checkpointed of
      { meta : Keeper_meta_contract.keeper_meta
      ; checkpoint_reason : Keeper_unified_turn.checkpoint_reason
      ; continuation_route :
          Keeper_unified_turn.continuation_route_disposition
      }
  | Input_required of Keeper_meta_contract.keeper_meta
  | Cancelled of Keeper_meta_contract.keeper_meta
  | Skipped of Keeper_meta_contract.keeper_meta
  | Failed of
      { meta : Keeper_meta_contract.keeper_meta
      ; failure : Keeper_unified_turn.turn_failure
      }

val disposition_token : cycle_outcome -> string
(** Canonical lowercase token for how the cycle ended, for evidence that has to
    name the outcome without carrying the whole variant. Exhaustive over
    {!cycle_outcome}: a new way for a turn to end has to be spelled here rather
    than falling into a catch-all that would report it as one of the others. *)

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
  -> ?previous_turn_stop:Keeper_turn_checkpoint_reason.t
  -> ctx:_ Keeper_types_profile.context
  -> meta_after_triage:Keeper_meta_contract.keeper_meta
  -> stop:bool Atomic.t
  -> obs:Keeper_world_observation.world_observation
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> shared_context:Agent_core.Context.t
  -> wake:Keeper_registry.wake_reason
  -> unit
  -> cycle_outcome
(** [?previous_turn_stop] overrides the shared stop cell for this turn —
    tests use it to pin the rendered line. When absent, the wrapper reads
    {!Keeper_last_turn_stop} and, after the cycle, records the outcome there
    ([Some checkpoint_reason] for a checkpoint, [None] for every other
    outcome) so the next turn on any lane is told why this one stopped. *)
