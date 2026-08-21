(* Keeper_turn_runtime_budget — runtime execution types, fail-open rotation,
   context overflow observation, Keeper lifecycle
   sync, and context budget resolution.

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
  | Serialized_request_body of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Provider_request_body_refusal of { status : int }

type capacity_non_compaction =
  | Serving_evidence_not_yet_valid of
      { now_unix_s : int
      ; checked_at_unix_s : int
      }
  | Serving_evidence_expired of
      { now_unix_s : int
      ; expires_at_unix_s : int
      }
  | Token_measurement_unavailable

type capacity_transition =
  | Not_capacity
  | Capacity_refusal_classified of Compaction_trigger.t
  | Capacity_non_compacting of capacity_non_compaction

let capacity_transition_of_error
    (err : Agent_core.Error.t) : capacity_transition =
  match err with
  | Agent_core.Error.Api (ContextOverflow { limit; _ }) ->
    Capacity_refusal_classified
      (Compaction_trigger.Provider_overflow { limit_tokens = limit })
  | Agent_core.Error.Api
      (InvalidRequest
         { reason = Request_body_too_large { actual_bytes; limit_bytes }; _ })
    ->
    Capacity_refusal_classified
      (Compaction_trigger.Request_body_over_capacity
         { actual_bytes; limit_bytes })
  | Agent_core.Error.Api
      (InvalidRequest
         { reason = Request_body_refused_by_provider { status }; _ })
    ->
    Capacity_refusal_classified
      (Compaction_trigger.Request_body_refused_by_provider { status })
  | Agent_core.Error.Api
      (InputCapacity
         { reason =
             Serving_constraint_rejected
               (Llm_provider.Serving_constraint.Boundary_unknown
                  { input_tokens; accepted_through; rejected_from })
         ; _
         })
    ->
    Capacity_refusal_classified
      (Compaction_trigger.Serving_input_capacity
         (Compaction_trigger.Boundary_unknown
            { input_tokens; accepted_through; rejected_from }))
  | Agent_core.Error.Api
      (InputCapacity
         { reason =
             Serving_constraint_rejected
               (Llm_provider.Serving_constraint.Input_rejected
                  { input_tokens; accepted_through; rejected_from })
         ; _
         })
    ->
    Capacity_refusal_classified
      (Compaction_trigger.Serving_input_capacity
         (Compaction_trigger.Input_rejected
            { input_tokens; accepted_through; rejected_from }))
  | Agent_core.Error.Api
      (InputCapacity
         { reason =
             Serving_constraint_rejected
               (Llm_provider.Serving_constraint.Evidence_not_yet_valid
                  { now_unix_s; checked_at_unix_s })
         ; _
         })
    ->
    Capacity_non_compacting
      (Serving_evidence_not_yet_valid { now_unix_s; checked_at_unix_s })
  | Agent_core.Error.Api
      (InputCapacity
         { reason =
             Serving_constraint_rejected
               (Llm_provider.Serving_constraint.Evidence_expired
                  { now_unix_s; expires_at_unix_s })
         ; _
         })
    ->
    Capacity_non_compacting
      (Serving_evidence_expired { now_unix_s; expires_at_unix_s })
  | Agent_core.Error.Api
      (InputCapacity { reason = Token_measurement_unavailable _; _ }) ->
    Capacity_non_compacting Token_measurement_unavailable
  | Agent_core.Error.Api
      (InvalidRequest
         { reason = Json_parse_error | Attempt_rejected | Unknown_invalid_request; _ })
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
    Not_capacity
;;

(* The two-axis refusal view is a projection of the canonical transition
   classifier. This keeps one exhaustive agent-core error match while preserving the
   narrow token/byte API used by existing lifecycle projections. *)
let capacity_refusal_of_error
    (err : Agent_core.Error.t) : capacity_refusal option =
  match capacity_transition_of_error err with
  | Capacity_refusal_classified (Compaction_trigger.Provider_overflow { limit_tokens }) ->
    Some (Provider_context_window { limit_tokens })
  | Capacity_refusal_classified
      (Compaction_trigger.Request_body_over_capacity { actual_bytes; limit_bytes })
    ->
    Some (Serialized_request_body { actual_bytes; limit_bytes })
  | Capacity_refusal_classified
      (Compaction_trigger.Request_body_refused_by_provider { status }) ->
    Some (Provider_request_body_refusal { status })
  | Capacity_refusal_classified (Compaction_trigger.Serving_input_capacity _)
  | Capacity_refusal_classified Compaction_trigger.Manual
  | Capacity_non_compacting _
  | Not_capacity ->
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
