(** Keeper_unified_metrics_json_support — decision and snapshot JSON helpers for Keeper_unified_metrics. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime


let decision_id ~(meta : keeper_meta) ~(ts : float) ~(suffix_seed : string) : string =
  let digest =
    Digest.to_hex
      (Digest.string
         (Printf.sprintf "%s|%s|%.6f|%s"
            meta.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id) ts suffix_seed))
  in
  Printf.sprintf "dec-%Ld-%s"
    (Int64.of_float (ts *. 1000.0))
    (String.sub digest 0 8)

let tool_call_detail_to_json
    (detail : Keeper_agent_run.tool_call_detail)
  : Yojson.Safe.t =
  Keeper_agent_run.tool_call_detail_to_json detail

let provider_context_json ~(meta : keeper_meta)
    (result : Keeper_agent_run.run_result option) =
  match result with
  | Some r ->
      let runtime_id =
        match r.runtime_observation with
        | Some observation ->
            observation.runtime_id
        | None -> runtime_id_of_meta meta
      in
      `Assoc
        [ ("runtime_id", `String runtime_id)
        ; "selected_model", `Null
        ; "candidate_models", `List []
        ]
  | None ->
      `Assoc
        [ ("runtime_id", `String (runtime_id_of_meta meta))
        ; ("selected_model", `Null)
        ; "candidate_models", `List []
        ]

let redacted_runtime_attempt_to_json
    (attempt : Runtime_observation.runtime_attempt) : Yojson.Safe.t =
  `Assoc
    [ "attempt_index", `Int attempt.attempt_index
    ; ( "latency_ms", Json_util.int_opt_to_json attempt.latency_ms )
    ; ( "error", Json_util.string_opt_to_json attempt.error )
    ]
;;

let redacted_runtime_fallback_event_to_json
    (event : Runtime_observation.runtime_fallback_event) : Yojson.Safe.t =
  `Assoc [ "reason", `String event.reason ]
;;

let redacted_runtime_observation_to_json
    (obs : Runtime_observation.runtime_observation) : Yojson.Safe.t =
  let runtime_id =
    obs.runtime_id
  in
  `Assoc
    [ "runtime_id", `String runtime_id
    ; "strategy", Json_util.string_opt_to_json obs.strategy
    ; "configured_labels", `List []
    ; "candidate_models", `List []
    ; "primary_model", `Null
    ; "selected_model", `Null
    ; "selected_model_raw", `Null
    ; "selected_index", Json_util.int_opt_to_json obs.selected_index
    ; "fallback_hops", Json_util.int_opt_to_json obs.fallback_hops
    ; "fallback_applied", `Bool obs.fallback_applied
    ; ( "attempts"
      , `List (List.map redacted_runtime_attempt_to_json obs.attempts) )
    ; ( "fallback_events"
      , `List
          (List.map redacted_runtime_fallback_event_to_json obs.fallback_events)
      )
    ; "attempt_details_available", `Bool obs.attempt_details_available
    ; "attempt_details_source", `String obs.attempt_details_source
    ]
;;

let tool_surface_json (result : Keeper_agent_run.run_result option) =
  `Assoc
    [ ( "turn_lane",
        match result with
        | Some r -> Keeper_agent_tool_surface.turn_lane_to_yojson r.tool_surface.turn_lane
        | None -> `Null )
    ]
