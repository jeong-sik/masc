(** Keepalive scheduling decision for the heartbeat loop, extracted from
    [keeper_heartbeat_loop.ml]. Holds the record type returned by
    [decide_keepalive_scheduling] and the pure decision function that
    combines the turn verdict with cascade backpressure admission. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
module Observations = Keeper_heartbeat_loop_observations

(* Re-export runtime_backpressure_decision so the record field below
   matches the parent's view byte-identically. *)
type runtime_backpressure_decision = Observations.runtime_backpressure_decision =
  | Runtime_admitted
  | Runtime_backpressured of {
      runtime_id : string;
      reason : string;
    }

let runtime_backpressure_observation_reasons =
  Observations.runtime_backpressure_observation_reasons
;;

let runtime_backpressure_decision = Observations.runtime_backpressure_decision

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  runtime_backpressure : runtime_backpressure_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  admission_reasons : string list;
  channel : string;
}

let decide_keepalive_scheduling
      ?(runtime_resilience_of_name =
        Keeper_runtime_resilience.runtime_resilience_of_name)
      ?(runtime_status_of_name =
        fun ~runtime_id -> Keeper_health_probe.get_runtime_status ~runtime_id)
      ~stop
      ~meta
      obs
  =
  let turn_decision = Keeper_world_observation.keeper_cycle_decision ~meta obs in
  let requested_should_run_turn =
    (not (Atomic.get stop)) && turn_decision.should_run
  in
  let runtime_id = runtime_id_of_meta meta in
  let runtime_resilience = runtime_resilience_of_name runtime_id in
  let runtime_backpressure =
    runtime_backpressure_decision
      ~runtime_resilience:(Some runtime_resilience)
      ~should_run_turn:requested_should_run_turn
      ~runtime_id
      ~runtime_status:(runtime_status_of_name ~runtime_id)
  in
  let should_run_turn =
    match runtime_backpressure with
    | Runtime_admitted -> requested_should_run_turn
    | Runtime_backpressured _ -> false
  in
  let verdict_reasons =
    Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict
  in
  let admission_reasons =
    match runtime_backpressure with
    | Runtime_admitted -> verdict_reasons
    | Runtime_backpressured { reason; _ } ->
      runtime_backpressure_observation_reasons ~reason
  in
  let channel = Keeper_world_observation.channel_to_string turn_decision.channel in
  { turn_decision
  ; requested_should_run_turn
  ; runtime_backpressure
  ; should_run_turn
  ; verdict_reasons
  ; admission_reasons
  ; channel
  }
;;
