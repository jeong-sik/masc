module U = Yojson.Safe.Util

type evidence_state =
  | Available
  | Unavailable
  | Missing

let evidence_state_to_string = function
  | Available -> "available"
  | Unavailable -> "unavailable"
  | Missing -> "missing"

let non_empty_string = function
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let string_member_opt key json = non_empty_string (U.member key json)

let bool_member_opt key json =
  match U.member key json with
  | `Bool value -> Some value
  | _ -> None

let list_member key json =
  match U.member key json with
  | `List items -> items
  | _ -> []

let string_list_member key json =
  list_member key json
  |> List.filter_map (function
       | `String value when String.trim value <> "" -> Some (String.trim value)
       | _ -> None)

let has_non_null key json =
  match U.member key json with
  | `Null -> false
  | _ -> true

let bool_opt_to_json = function
  | Some value -> `Bool value
  | None -> `Null

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)

let trace_capability json = string_member_opt "trace_capability" json

let tool_surface_names json =
  let explicit = string_list_member "tool_surface_names" json in
  if explicit <> [] then
    Team_session_types.dedup_strings explicit
  else
    Team_session_types.dedup_strings
      (string_list_member "tool_surface_masc_names" json
      @ string_list_member "tool_surface_shell_names" json)

let tool_surface_status json =
  match string_member_opt "tool_surface_status" json with
  | Some _ as value -> value
  | None ->
      Some
        (if tool_surface_names json <> [] then "available" else "missing")

let tool_surface_status_with_names ~names json =
  match string_member_opt "tool_surface_status" json with
  | Some _ as value -> value
  | None ->
      Some (if names <> [] then "available" else "missing")

let trace_validated json =
  match bool_member_opt "validated" json with
  | Some _ as value -> value
  | None -> (
      match U.member "trace_validation" json with
      | `Assoc _ as validation -> bool_member_opt "ok" validation
      | _ -> None)

let session_conformance_failures json =
  match U.member "session_conformance" json with
  | `Assoc _ as conformance -> (
      match U.member "checks" conformance with
      | `List items ->
          items
          |> List.filter_map (fun item ->
                 match U.member "name" item, U.member "passed" item with
                 | `String name, `Bool false -> Some name
                 | _ -> None)
      | _ -> [])
  | _ -> []

let validation_failures json =
  let trace_failures =
    match U.member "trace_validation" json with
    | `Assoc _ as validation -> (
        match U.member "checks" validation with
        | `List items ->
            items
            |> List.filter_map (fun item ->
                   match U.member "name" item, U.member "passed" item with
                   | `String name, `Bool false -> Some name
                   | _ -> None)
        | _ -> [])
    | _ -> []
  in
  Team_session_types.dedup_strings
    (trace_failures @ session_conformance_failures json)

let trace_evidence_state json =
  let has_trace_evidence =
    has_non_null "trace_ref" json
    || has_non_null "trace_summary" json
    || has_non_null "trace_validation" json
  in
  match trace_capability json with
  | Some "raw" ->
      if has_trace_evidence then Available else Missing
  | Some "summary_only" ->
      if has_trace_evidence then Available else Unavailable
  | Some _ ->
      if has_trace_evidence then Available else Unavailable
  | None ->
      if has_trace_evidence then Available
      else if has_non_null "evidence_session_id" json then Unavailable
      else Missing

let proof_refs_present json =
  has_non_null "proof_run_id" json
  || has_non_null "checkpoint_ref" json
  || list_member "tool_trace_refs" json <> []
  || list_member "raw_evidence_refs" json <> []

let proof_evidence_state json =
  match bool_member_opt "proof_present" json with
  | Some true ->
      if proof_refs_present json then Available else Missing
  | Some false ->
      if proof_refs_present json then Missing else Unavailable
  | None ->
      if proof_refs_present json then Available else Unavailable

let summary_json json =
  let summary = U.member "trace_summary" json in
  let normalized_tool_surface_names = tool_surface_names json in
  let normalized_tool_surface_status =
    tool_surface_status_with_names ~names:normalized_tool_surface_names json
  in
  let summary_member key =
    match summary with
    | `Assoc _ -> U.member key summary
    | _ -> `Null
  in
  let base_fields =
    [
      ("session_id", U.member "session_id" json);
      ("operation_id", U.member "operation_id" json);
      ("worker_run_id", U.member "worker_run_id" json);
      ("cdal_run_id", U.member "cdal_run_id" json);
      ("contract_id", U.member "contract_id" json);
      ("result_status", U.member "result_status" json);
      ("worker_name", U.member "worker_name" json);
      ("status", U.member "status" json);
      ("mode", U.member "mode" json);
      ("wait_mode", U.member "wait_mode" json);
      ("success", U.member "success" json);
      ("execution_scope", U.member "execution_scope" json);
      ("requested_worker_class", U.member "requested_worker_class" json);
      ("requested_worker_size", U.member "requested_worker_size" json);
      ("requested_runtime", U.member "requested_runtime" json);
      ("requested_model", U.member "requested_model" json);
      ("resolved_runtime", U.member "resolved_runtime" json);
      ("resolved_model", U.member "resolved_model" json);
      ("routing_reason", U.member "routing_reason" json);
      ( "tool_surface_status",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          normalized_tool_surface_status );
      ("tool_surface_source", U.member "tool_surface_source" json);
      ("tool_surface_names", string_list_to_json normalized_tool_surface_names);
      ( "tool_surface_masc_names",
        string_list_to_json (string_list_member "tool_surface_masc_names" json)
      );
      ( "tool_surface_shell_names",
        string_list_to_json
          (string_list_member "tool_surface_shell_names" json) );
      ("tool_surface_count", `Int (List.length normalized_tool_surface_names));
      ("tool_names", U.member "tool_names" json);
      ("tool_call_count", U.member "tool_call_count" json);
      ("output_preview", U.member "output_preview" json);
      ("trace_capability", U.member "trace_capability" json);
      ( "trace_evidence_status",
        `String (evidence_state_to_string (trace_evidence_state json)) );
      ("trace_ref", U.member "trace_ref" json);
      ("trace_summary_present", `Bool (has_non_null "trace_summary" json));
      ("trace_validation_present", `Bool (has_non_null "trace_validation" json));
      ("trace_validated", bool_opt_to_json (trace_validated json));
      ("validation_failures", string_list_to_json (validation_failures json));
      ("record_count", summary_member "record_count");
      ("assistant_block_count", summary_member "assistant_block_count");
      ( "final_text",
        if U.member "final_text" json <> `Null then
          U.member "final_text" json
        else
          summary_member "final_text" );
      ( "stop_reason",
        if U.member "stop_reason" json <> `Null then
          U.member "stop_reason" json
        else
          summary_member "stop_reason" );
      ("failure_reason", U.member "failure_reason" json);
      ( "error",
        if U.member "error" json <> `Null then
          U.member "error" json
        else
          summary_member "error" );
      ("proof_present", U.member "proof_present" json);
      ( "proof_evidence_status",
        `String (evidence_state_to_string (proof_evidence_state json)) );
      ("tool_trace_refs", U.member "tool_trace_refs" json);
      ("raw_evidence_refs", U.member "raw_evidence_refs" json);
      ("checkpoint_ref", U.member "checkpoint_ref" json);
      ("evidence_session_id", U.member "evidence_session_id" json);
      ("evidence_refs", U.member "evidence_refs" json);
      ("session_conformance", U.member "session_conformance" json);
      ("ts_iso", U.member "ts_iso" json);
    ]
  in
  let proof_fields =
    match U.member "proof_run_id" json with
    | `String _ ->
        [
          ("proof_run_id", U.member "proof_run_id" json);
          ("proof_status", U.member "proof_status" json);
          ("proof_risk_class", U.member "proof_risk_class" json);
          ("proof_execution_mode", U.member "proof_execution_mode" json);
          ("proof_evidence_count", U.member "proof_evidence_count" json);
        ]
    | _ -> []
  in
  `Assoc (base_fields @ proof_fields)
