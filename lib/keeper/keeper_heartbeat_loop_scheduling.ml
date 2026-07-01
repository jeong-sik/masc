(** Keepalive scheduling decision for the heartbeat loop, extracted from
    [keeper_heartbeat_loop.ml]. Holds the record type returned by
    [decide_keepalive_scheduling] and the pure decision function that
    combines the turn verdict with runtime backpressure admission. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
module Observations = Keeper_heartbeat_loop_observations

type runtime_backpressure_decision = Observations.runtime_backpressure_decision =
  | Runtime_admitted
  | Runtime_backpressured of {
      runtime_id : string;
      reason : string;
    }

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  runtime_backpressure : runtime_backpressure_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

let decide_keepalive_scheduling
      ?(runtime_id_of_meta = Keeper_meta_contract.runtime_id_of_meta)
      ?(runtime_resilience_of_name = fun _ -> None)
      ?(keeper_resilience_of_name = fun _ -> None)
      ?(reactive_wake = false)
      ?(event_queue_triggers = [])
      ~stop
      ~meta
      obs
  =
  let turn_decision =
    Keeper_world_observation.keeper_cycle_decision
      ~reactive_wake
      ~event_queue_triggers
      ~meta
      obs
  in
  let requested_should_run_turn =
    (not (Atomic.get stop)) && turn_decision.should_run
  in
  (* RFC-0303 Phase 3: the self-cadence wake-tombstone gate is removed. Phase 2
     stimulus-gated the autonomous cadence (min_interval is now a rate-limit on
     opportunity-driven turns, not a standalone trigger), so the tombstone that
     suppressed blind self-wakes no longer has an input. [should_run_turn] is now
     gated only by runtime backpressure on [requested_should_run_turn]. *)
  let runtime_id = runtime_id_of_meta meta in
  let runtime_backpressure =
    match keeper_resilience_of_name meta.name with
    | Some blocker ->
      Observations.runtime_backpressure_decision
        ~reason_prefix:"keeper_health"
        ~runtime_resilience:(Some blocker)
        ~should_run_turn:requested_should_run_turn
        ~runtime_id
    | None ->
      Observations.runtime_backpressure_decision
        ~reason_prefix:"runtime_resilience"
        ~runtime_resilience:(runtime_resilience_of_name runtime_id)
        ~should_run_turn:requested_should_run_turn
        ~runtime_id
  in
  let should_run_turn =
    match runtime_backpressure with
    | Runtime_admitted -> requested_should_run_turn
    | Runtime_backpressured _ -> false
  in
  let verdict_reasons =
    let base = Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict in
    match runtime_backpressure with
    | Runtime_backpressured _ -> "runtime_backpressure" :: base
    | Runtime_admitted -> base
  in
  let channel = Keeper_world_observation.channel_to_string turn_decision.channel in
  { turn_decision
  ; requested_should_run_turn
  ; runtime_backpressure
  ; should_run_turn
  ; verdict_reasons
  ; channel
  }
;;
