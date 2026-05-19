(** Keeper_unified_metrics_json_support — decision and snapshot JSON helpers for Keeper_unified_metrics. *)

open Keeper_types
open Keeper_exec_context

let cdal_mode_violations_ref_suffix = "evidence/mode_violations.json"

let cdal_raw_evidence_ref_count (proof : Masc_mcp_cdal_runtime.Cdal_proof.t) : int =
  List.length proof.raw_evidence_refs

let cdal_violation_ref_count (proof : Masc_mcp_cdal_runtime.Cdal_proof.t) : int =
  proof.raw_evidence_refs
  |> List.filter (String.ends_with ~suffix:cdal_mode_violations_ref_suffix)
  |> List.length

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
      let cascade_name =
        match r.cascade_observation with
        | Some observation ->
            Keeper_cascade_profile.runtime_name_to_string observation.cascade_name
        | None -> cascade_name_of_meta meta
      in
      `Assoc
        [ ("cascade_name", `String cascade_name)
        ; "selected_model", `Null
        ; "candidate_models", `List []
        ]
  | None ->
      `Assoc
        [ ("cascade_name", `String (cascade_name_of_meta meta))
        ; ("selected_model", `Null)
        ; "candidate_models", `List []
        ]

let redacted_cascade_attempt_to_json
    (attempt : Cascade_legacy_runner.cascade_attempt) : Yojson.Safe.t =
  `Assoc
    [ "attempt_index", `Int attempt.attempt_index
    ; ( "latency_ms"
      , match attempt.latency_ms with
        | Some value -> `Int value
        | None -> `Null )
    ; ( "error"
      , match attempt.error with
        | Some value -> `String value
        | None -> `Null )
    ]
;;

let redacted_cascade_fallback_event_to_json
    (event : Cascade_legacy_runner.cascade_fallback_event) : Yojson.Safe.t =
  `Assoc [ "reason", `String event.reason ]
;;

let redacted_cascade_observation_to_json
    (obs : Cascade_legacy_runner.cascade_observation) : Yojson.Safe.t =
  let cascade_name =
    Keeper_cascade_profile.runtime_name_to_string obs.cascade_name
  in
  `Assoc
    [ "cascade_name", `String cascade_name
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
      , `List (List.map redacted_cascade_attempt_to_json obs.attempts) )
    ; ( "fallback_events"
      , `List
          (List.map redacted_cascade_fallback_event_to_json obs.fallback_events)
      )
    ; "attempt_details_available", `Bool obs.attempt_details_available
    ; "attempt_details_source", `String obs.attempt_details_source
    ]
;;

let tool_contract_json ~(tool_call_count : int) ~(tools_used : string list)
    (result : Keeper_agent_run.run_result option) =
  let requirement, required_tool_names, missing_required_tool_names =
    match result with
    | Some r ->
        ( Some r.tool_surface.tool_requirement,
          r.tool_surface.required_tool_names,
          r.tool_surface.missing_required_tool_names )
    | None -> (None, [], [])
  in
  `Assoc
    [ ("requirement", match requirement with
      | Some r -> Keeper_agent_tool_surface.tool_requirement_to_yojson r
      | None -> `String "unknown")
    ; ( "required_tool_names",
        `List (List.map (fun value -> `String value) required_tool_names) )
    ; ( "missing_required_tool_names",
        `List (List.map (fun value -> `String value) missing_required_tool_names) )
    ; ("tool_call_count", `Int tool_call_count)
    ; ("tools_used", `List (List.map (fun value -> `String value) tools_used))
    ]
