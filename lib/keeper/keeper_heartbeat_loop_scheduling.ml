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
      ?(wake_tombstone_decide = Keeper_wake_tombstone.decide)
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
  (* RFC-0294 R2b: the RFC-0246 wake-tombstone was wired only into the external
     wake paths (Keeper_registry Heartbeat / Board_reactive); a keeper latched in
     a no-progress loop kept re-waking on its OWN self-cadence clock. Gate the
     scheduled-autonomous wake through the same tombstone here. This is an
     admission gate (like runtime backpressure), so it suppresses [should_run_turn]
     while leaving [requested_should_run_turn] ("the world wanted a turn") intact.
     Only consult the tombstone when a self-cadence turn was actually requested;
     idle/stop cycles should keep their original skip reason and must not be
     reported as tombstone suppressions.
     Reactive turns are gated upstream in the registry, so only the autonomous
     channel is gated here. *)
  let self_cadence_wake : Keeper_wake_tombstone.wake_decision =
    if
      requested_should_run_turn
      && Keeper_world_observation.is_autonomous turn_decision.channel
    then
      wake_tombstone_decide ~origin:Keeper_wake_tombstone.Self_cadence
        ~keeper_name:meta.name
    else Keeper_wake_tombstone.Wake_allowed
  in
  let self_cadence_wake_allowed =
    match self_cadence_wake with
    | Keeper_wake_tombstone.Wake_allowed -> true
    | Keeper_wake_tombstone.Suppressed _ -> false
  in
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
    | Runtime_admitted -> requested_should_run_turn && self_cadence_wake_allowed
    | Runtime_backpressured _ -> false
  in
  let verdict_reasons =
    let base = Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict in
    let base =
      match self_cadence_wake with
      | Keeper_wake_tombstone.Suppressed reason ->
        Keeper_wake_tombstone.suppression_label reason :: base
      | Keeper_wake_tombstone.Wake_allowed -> base
    in
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
