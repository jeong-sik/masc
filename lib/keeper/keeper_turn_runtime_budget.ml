(* Keeper_turn_runtime_budget — runtime execution types, Keeper lifecycle
   sync, and context budget resolution.

   Extracted from keeper_unified_turn.ml (L501-1079) during the god-file split. *)

open Keeper_meta_contract
open Keeper_context_runtime
module EC = Keeper_error_classify
module StringMap = Set_util.StringMap

type runtime_execution = {
  runtime_id : string;
  max_context_resolution : Keeper_context_runtime.max_context_resolution;
  max_context : int;
  temperature : float;
}

type turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
}

let empty_turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.empty_turn_event_bus_summary

let merge_turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.merge_turn_event_bus_summary

let add_payload_kind =
  Keeper_turn_runtime_budget_event_bus.add_payload_kind

let summarize_turn_event_bus
    (events : Agent_core.Event_bus.event list) : turn_event_bus_summary =
  List.fold_left
    (fun acc (evt : Agent_core.Event_bus.event) ->
      let correlation_id =
        match acc.correlation_id with
        | Some _ -> acc.correlation_id
        | None -> Some evt.meta.correlation_id
      in
      let run_id =
        match acc.run_id with
        | Some _ -> acc.run_id
        | None -> Some evt.meta.run_id
      in
      let caused_by =
        match acc.caused_by with
        | Some _ -> acc.caused_by
        | None -> evt.meta.caused_by
      in
      { correlation_id;
        run_id;
        caused_by;
        event_count = acc.event_count + 1;
        payload_kinds =
          add_payload_kind acc.payload_kinds
            (Agent_core.Event_bus.payload_kind evt.payload);
      })
    empty_turn_event_bus_summary
    events

let runtime_budget_logged : unit StringMap.t Atomic.t =
  Atomic.make StringMap.empty

let runtime_budget_log_key ~keeper_name ~primary_budget ~runtime_budget =
  Printf.sprintf "%s|%d|%d" keeper_name primary_budget runtime_budget

let resolved_max_context_for_turn
      ~(meta : keeper_meta)
      (resolution : Keeper_context_runtime.max_context_resolution)
  : int
  =
  if resolution.primary_budget < resolution.runtime_budget then begin
    let key =
      runtime_budget_log_key
        ~keeper_name:meta.name
        ~primary_budget:resolution.primary_budget
        ~runtime_budget:resolution.runtime_budget
    in
    let rec log_once () =
      let old = Atomic.get runtime_budget_logged in
      if StringMap.mem key old
      then ()
      else
        let new_map = StringMap.add key () old in
        if Atomic.compare_and_set runtime_budget_logged old new_map
        then
          Log.Keeper.info
            "%s: mixed runtime context window primary=%d runtime_max=%d; using primary for initial context window"
            meta.name resolution.primary_budget resolution.runtime_budget
        else log_once ()
    in
    log_once ()
  end;
   (match resolution.requested_override with
    | Some requested ->
     Log.Keeper.debug
       "%s: using max_context_override=%d context_budget=%d primary_budget=%d effective_budget=%d"
       meta.name requested resolution.requested_context_window resolution.primary_budget
       resolution.effective_budget
   | None -> ());
  resolution.effective_budget
