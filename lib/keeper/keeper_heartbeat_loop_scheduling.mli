(** Keepalive scheduling decision for the keeper heartbeat loop. *)

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  runtime_backpressure : Keeper_heartbeat_loop_observations.runtime_backpressure_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

val decide_keepalive_scheduling :
  ?runtime_id_of_meta:(Keeper_meta_contract.keeper_meta -> string) ->
  ?runtime_resilience_of_name:(string -> string option) ->
  ?keeper_resilience_of_name:(string -> string option) ->
  ?reactive_wake:bool ->
  ?event_queue_triggers:Keeper_world_observation.event_queue_trigger list ->
  ?wake_tombstone_decide:
    (origin:Keeper_wake_tombstone.wake_origin ->
     keeper_name:string ->
     Keeper_wake_tombstone.wake_decision) ->
  stop:bool Atomic.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_world_observation.world_observation ->
  keepalive_scheduling_decision
(** RFC-0294 R2b: [wake_tombstone_decide] (default {!Keeper_wake_tombstone.decide})
    gates a scheduled-autonomous (self-cadence) wake through the no-progress
    tombstone, suppressing [should_run_turn] for a latched keeper while leaving
    [requested_should_run_turn] intact. Injectable for tests. *)
