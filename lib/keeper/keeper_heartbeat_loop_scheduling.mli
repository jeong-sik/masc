(** Keepalive scheduling decision for the keeper heartbeat loop. *)

type cascade_backpressure_decision =
  Keeper_heartbeat_loop_observations.cascade_backpressure_decision =
  | Cascade_admitted
  | Cascade_backpressured of {
      cascade_name : string;
      reason : string;
    }

val cascade_backpressure_observation_reasons : reason:string -> string list

val cascade_backpressure_decision :
  cascade_resilience:Keeper_exec_preflight.cascade_resilience option ->
  should_run_turn:bool ->
  cascade_name:string ->
  cascade_status:Keeper_health_probe.health_status ->
  cascade_backpressure_decision

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  cascade_backpressure : cascade_backpressure_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  admission_reasons : string list;
  channel : string;
}

val decide_keepalive_scheduling :
  ?cascade_resilience_of_name:(string -> Keeper_exec_preflight.cascade_resilience) ->
  ?cascade_status_of_name:
    (cascade_name:string -> Keeper_health_probe.health_status) ->
  stop:bool Atomic.t ->
  meta:Keeper_types.keeper_meta ->
  Keeper_world_observation.world_observation ->
  keepalive_scheduling_decision
