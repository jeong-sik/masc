(** Keepalive scheduling decision for the keeper heartbeat loop. *)

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

val decide_keepalive_scheduling :
  ?reactive_wake:bool ->
  ?event_queue_triggers:Keeper_world_observation.event_queue_trigger list ->
  stop:bool Atomic.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_world_observation.world_observation ->
  keepalive_scheduling_decision
(** [should_run_turn] combines only the typed world/lifecycle decision with
    the explicit loop stop flag. Runtime health, provider cooldown, budgets,
    and provider failures are observations rather than admission authority. *)
