(** Keepalive scheduling decision for the keeper heartbeat loop. *)

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  runtime_backpressure : Keeper_heartbeat_loop_observations.runtime_backpressure_decision;
  pacing_block : float option;
      (** RFC-0313 W3: seconds until the earliest per-runtime revisit is
          eligible when pacing blocked this turn; [None] when pacing admitted
          it (or when the turn was already not requested / backpressured). *)
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

val decide_keepalive_scheduling :
  ?runtime_id_of_meta:(Keeper_meta_contract.keeper_meta -> string) ->
  ?runtime_resilience_of_name:(string -> string option) ->
  ?keeper_resilience_of_name:(string -> string option) ->
  ?pacing_block_of_name:(string -> float option) ->
  ?reactive_wake:bool ->
  ?event_queue_triggers:Keeper_world_observation.event_queue_trigger list ->
  stop:bool Atomic.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_world_observation.world_observation ->
  keepalive_scheduling_decision
(** RFC-0303 Phase 3: the self-cadence wake-tombstone gate is retired;
    [should_run_turn] is gated by runtime backpressure and (RFC-0313 W3)
    failure revisit pacing on [requested_should_run_turn].
    [pacing_block_of_name] returns the seconds remaining until the keeper's
    earliest runtime revisit is eligible ([None] = run now); the default
    never blocks, callers wire {!Keeper_pacing_shadow.next_due_remaining}
    when [pacing.mode = enforce]. *)
