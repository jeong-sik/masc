(* Keeper_turn_runtime_budget — runtime execution types, context overflow
   observation, Keeper lifecycle sync, and context budget resolution.

   Extracted from keeper_unified_turn.ml (L501-1079) during the god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
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

let turn_event_bus_evidence_detail
    (summary : turn_event_bus_summary) : string =
  Printf.sprintf
    "agent_core_event_evidence(events=%d,payload_kinds=[%s])"
    summary.event_count
    (String.concat "," summary.payload_kinds)

type capacity_refusal =
  | Provider_context_window of { limit_tokens : int option }
  | Provider_request_body_refusal of { status : int }

(* Two-axis refusal view over the AGENT_CORE error type. The error is matched
   once, directly. Non-capacity errors and the serving-constraint facts
   (evidence validity, unmeasurable tokens) stay [None]: they are not a
   capacity limit and must never be guessed into one. *)
let capacity_refusal_of_error
    (err : Agent_core.Error.t) : capacity_refusal option =
  match err with
  | Agent_core.Error.Api (ContextOverflow { limit; _ }) ->
    Some (Provider_context_window { limit_tokens = limit })
  | Agent_core.Error.Api
      (InvalidRequest
         { reason = Request_body_refused_by_provider { status }; _ })
    ->
    Some (Provider_request_body_refusal { status })
  | Agent_core.Error.Api (InputCapacity _)
  | Agent_core.Error.Api
      (InvalidRequest
         { reason =
             ( Json_parse_error
             | Attempt_rejected
             | Refusal_body_not_received
             | Unknown_invalid_request )
         ; _
         })
  | Agent_core.Error.Api
      ( RateLimited _ | Overloaded _ | ServerError _ | AuthError _
      | AuthorizationError _ | PaymentRequired _ | NotFound _ | NetworkError _
      | Timeout _ )
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Config _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } ->
    None
;;

let current_keeper_meta ~(config : Workspace.config) ~(fallback_meta : keeper_meta) =
  match Keeper_registry.get ~base_path:config.base_path fallback_meta.name with
  | Some entry -> entry.meta
  | None -> fallback_meta

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
