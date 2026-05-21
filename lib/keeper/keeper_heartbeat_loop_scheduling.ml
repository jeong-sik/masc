(** Keepalive scheduling decision for the heartbeat loop, extracted from
    [keeper_heartbeat_loop.ml]. Holds the record type returned by
    [decide_keepalive_scheduling] and the pure decision function that
    combines the turn verdict with cascade backpressure admission. *)

open Keeper_types
module Observations = Keeper_heartbeat_loop_observations

(* Re-export cascade_backpressure_decision so the record field below
   matches the parent's view byte-identically. *)
type cascade_backpressure_decision = Observations.cascade_backpressure_decision =
  | Cascade_admitted
  | Cascade_backpressured of {
      cascade_name : string;
      reason : string;
    }

let cascade_backpressure_observation_reasons =
  Observations.cascade_backpressure_observation_reasons
;;

let cascade_backpressure_decision = Observations.cascade_backpressure_decision

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  cascade_backpressure : cascade_backpressure_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  admission_reasons : string list;
  channel : string;
}

let decide_keepalive_scheduling
      ?(cascade_resilience_of_name =
        Keeper_exec_preflight.cascade_resilience_of_name)
      ?(cascade_status_of_name =
        fun ~cascade_name -> Keeper_health_probe.get_cascade_status ~cascade_name)
      ~stop
      ~meta
      obs
  =
  let turn_decision = Keeper_world_observation.keeper_cycle_decision ~meta obs in
  let requested_should_run_turn =
    (not (Atomic.get stop)) && turn_decision.should_run
  in
  let cascade_name = cascade_name_of_meta meta in
  let cascade_resilience = cascade_resilience_of_name cascade_name in
  let cascade_backpressure =
    cascade_backpressure_decision
      ~cascade_resilience:(Some cascade_resilience)
      ~should_run_turn:requested_should_run_turn
      ~cascade_name
      ~cascade_status:(cascade_status_of_name ~cascade_name)
  in
  let should_run_turn =
    match cascade_backpressure with
    | Cascade_admitted -> requested_should_run_turn
    | Cascade_backpressured _ -> false
  in
  let verdict_reasons =
    Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict
  in
  let admission_reasons =
    match cascade_backpressure with
    | Cascade_admitted -> verdict_reasons
    | Cascade_backpressured { reason; _ } ->
      cascade_backpressure_observation_reasons ~reason
  in
  let channel = Keeper_world_observation.channel_to_string turn_decision.channel in
  { turn_decision
  ; requested_should_run_turn
  ; cascade_backpressure
  ; should_run_turn
  ; verdict_reasons
  ; admission_reasons
  ; channel
  }
;;
