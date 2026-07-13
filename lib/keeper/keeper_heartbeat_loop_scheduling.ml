(** Keepalive scheduling decision for the heartbeat loop, extracted from
    [keeper_heartbeat_loop.ml]. Runtime/provider observations do not participate
    in admission here: an eligible Keeper turn reaches the provider boundary,
    where an unavailable call fails explicitly and runtime fallback can run. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

let decide_keepalive_scheduling
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
  let should_run_turn =
    (not (Atomic.get stop)) && turn_decision.should_run
  in
  let verdict_reasons =
    Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict
  in
  let channel = Keeper_world_observation.channel_to_string turn_decision.channel in
  { turn_decision
  ; should_run_turn
  ; verdict_reasons
  ; channel
  }
;;
