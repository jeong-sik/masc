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

(** Maximum consecutive no-op proactive cycles before the scheduler suppresses
    autonomous turns. When a keeper produces only observation reads (board_list,
    context_status, etc.) with no substantive action for [max_consecutive_noop]
    consecutive cycles, the scheduler skips the turn to avoid wasting context
    and provider tokens. The count resets on any productive cycle via
    [proactive_rt.consecutive_noop_count]. *)
let max_consecutive_noop = 3

let decide_keepalive_scheduling
      ?(event_queue_triggers = [])
      ~stop
      ~meta
      obs
  =
  let turn_decision =
    Keeper_world_observation.keeper_cycle_decision
      ~event_queue_triggers
      ~meta
      obs
  in
  let should_run_turn =
    (not (Atomic.get stop)) && turn_decision.should_run
  in
  let noop_suppressed =
    should_run_turn
    && turn_decision.channel = Scheduled_autonomous
    && meta.runtime.proactive_rt.consecutive_noop_count >= max_consecutive_noop
  in
  let should_run_turn =
    should_run_turn && not noop_suppressed
  in
  let verdict_reasons =
    Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict
    |> fun reasons ->
    if noop_suppressed
    then reasons @ [ Printf.sprintf "noop_suppressed(consecutive=%d,threshold=%d)"
                       meta.runtime.proactive_rt.consecutive_noop_count
                       max_consecutive_noop ]
    else reasons
  in
  let channel = Keeper_world_observation.channel_to_string turn_decision.channel in
  { turn_decision
  ; should_run_turn
  ; verdict_reasons
  ; channel
  }
;;
