(** Keepalive scheduling decision for the keeper heartbeat loop. *)

type runtime_backpressure_decision =
  Keeper_heartbeat_loop_observations.runtime_backpressure_decision =
  | Runtime_admitted
  | Runtime_backpressured of {
      cascade_name : string;
      reason : string;
    }

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  runtime_backpressure : runtime_backpressure_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  admission_reasons : string list;
  channel : string;
}

val decide_keepalive_scheduling :
  ?runtime_resilience_of_name:(string -> Keeper_runtime_resilience.runtime_resilience) ->
  ?cascade_status_of_name:
    (cascade_name:string -> Keeper_health_probe.health_status) ->
  stop:bool Atomic.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_world_observation.world_observation ->
  keepalive_scheduling_decision
