(** Keepalive scheduling decision for the heartbeat loop, extracted from
    [keeper_heartbeat_loop.ml]. Holds the record type returned by
    [decide_keepalive_scheduling] and the pure decision function that
    combines the turn verdict with the loop stop flag. *)

open Keeper_types
open Keeper_meta_contract

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  should_run_turn : bool;
  verdict_reasons : string list;
  skip_reasons : string list;
  channel : string;
}

let decide_keepalive_scheduling ~stop ~meta obs =
  let turn_decision = Keeper_world_observation.keeper_cycle_decision ~meta obs in
  let requested_should_run_turn =
    (not (Atomic.get stop)) && turn_decision.should_run
  in
  let verdict_reasons =
    Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict
  in
  let channel = Keeper_world_observation.channel_to_string turn_decision.channel in
  { turn_decision
  ; requested_should_run_turn
  ; should_run_turn = requested_should_run_turn
  ; verdict_reasons
  ; skip_reasons = verdict_reasons
  ; channel
  }
;;
