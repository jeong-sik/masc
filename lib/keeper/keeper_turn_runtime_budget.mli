(* Keeper_turn_runtime_budget — runtime execution types, Keeper lifecycle
   sync, and context budget resolution.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_meta_contract
open Keeper_context_runtime
module EC = Keeper_error_classify

type runtime_execution = {
  runtime_id : string;
  max_context_resolution : max_context_resolution;
  max_context : int;
  temperature : float;
}

type turn_event_bus_summary = Keeper_turn_runtime_budget_event_bus.turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
}

val empty_turn_event_bus_summary : turn_event_bus_summary

val merge_turn_event_bus_summary :
  turn_event_bus_summary -> turn_event_bus_summary -> turn_event_bus_summary

val summarize_turn_event_bus :
  Agent_core.Event_bus.event list -> turn_event_bus_summary

val resolved_max_context_for_turn
  :  meta:keeper_meta
  -> Keeper_context_runtime.max_context_resolution
  -> int
(** Resolve the initial keeper turn context budget from the keeper's routed
    runtime's prevalidated resolution, so lifecycle context math matches the
    provider that will receive the first request. *)
