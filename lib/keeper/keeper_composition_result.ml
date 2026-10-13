module Plan = Keeper_tool_plan
module Executor = Keeper_tool_plan_executor
module Projection = Keeper_tool_composition_projection

let settled = function
  | Ok nodes -> nodes
  | Error (failure : Executor.failure) -> failure.settled
;;

let node_summary (node : Executor.node_result) =
  let failure =
    match node.result with
    | Tool_result.Completed _ | Tool_result.Deferred _ -> []
    | Tool_result.Failed payload ->
      [ "failure_class", Tool_result.tool_failure_class_to_yojson payload.class_
      ; "failure_message", `String payload.message
      ; "effect_disposition", `String
          (Tool_result.failure_effect_disposition_to_string payload.effect_disposition) ]
  in
  `Assoc
    ([ "node_id", `String (Plan.Node_id.to_string node.node_id)
     ; "execution_id", Ids.Execution_id.to_yojson node.execution_id
     ; "execution_origin", `String (Executor.node_execution_origin_to_string node.execution_origin)
     ; "tool_name", `String node.tool_name
     ; "settled", `Bool true
     ; "disposition", `String (Tool_result.string_of_disposition node.result)
     ; "schedule", Projection.schedule_to_json node.schedule
     ; "output_validation_error", (match node.output_validation_error with
         | None -> `Null
         | Some error -> Projection.plan_execution_error_to_json error)
     ; "failure_effect_disposition", Projection.failure_effect_disposition_to_json node.failure_effect_disposition
     ; "deferred_kind", Projection.deferred_kind_to_json node.deferred_kind ] @ failure)
;;

let cause_summary = function
  | Executor.Run_journal_rejected error ->
    `Assoc [ "kind", `String "run_journal_rejected"
           ; "error", Keeper_tool_execution_journal.error_to_json error ]
  | Executor.Tool_did_not_complete node ->
    `Assoc [ "kind", `String "tool_did_not_complete"; "node", node_summary node ]
  | Executor.Node_observation_failed { node; detail } ->
    `Assoc [ "kind", `String "node_observation_failed"; "node", node_summary node; "detail", `String detail ]
  | Executor.Plan_execution_failed { node_id; schedule; error } ->
    `Assoc [ "kind", `String "plan_execution_failed"
           ; "node_id", `String (Plan.Node_id.to_string node_id)
           ; "schedule", Projection.schedule_to_json schedule
           ; "error", Projection.plan_execution_error_to_json error ]
  | Executor.Outer_completion_mismatch { expected; actual } ->
    `Assoc [ "kind", `String "outer_completion_mismatch"
           ; "expected", Agent_core.Tool_contract.completion_to_yojson expected
           ; "actual", Agent_core.Tool_contract.completion_to_yojson actual ]
;;

let export_error = function
  | Plan.Producer_unavailable node_id ->
    `Assoc [ "kind", `String "producer_unavailable"; "node_id", `String (Plan.Node_id.to_string node_id) ]
  | Plan.Producer_invalid error ->
    `Assoc [ "kind", `String "producer_invalid"; "error", Projection.plan_execution_error_to_json error ]
  | Plan.Export_pointer_unavailable error ->
    `Assoc [ "kind", `String "pointer_unavailable"; "error", Projection.pointer_resolution_error_to_json error ]
;;

let selected_fields plan nodes =
  let lookup node_id =
    match List.find_opt (fun (node : Executor.node_result) -> Plan.Node_id.equal node.node_id node_id) nodes with
    | None -> None
    | Some node ->
      match node.result, node.output_validation_error with
      | Tool_result.Completed payload, None -> Some payload.data
      | Tool_result.Completed _, Some _ | Tool_result.Deferred _, _ | Tool_result.Failed _, _ -> None
  in
  Plan.resolve_exports plan ~lookup
  |> List.map (fun (export, value) ->
    export.Plan.name, match value with
    | Ok value -> `Assoc [ "available", `Bool true; "value", value ]
    | Error error -> `Assoc [ "available", `Bool false; "error", export_error error ])
  |> fun fields -> `Assoc fields
;;

let project ?nested_scopes ~base_path ~plan ~execution result =
  let metadata = match nested_scopes with None -> [] | Some scopes -> [ "nested_scopes", scopes ] in
  let result = match metadata with
    | [] -> result
    | _ ->
      let data = match Tool_result.data result with
        | `Assoc fields -> `Assoc (metadata @ fields)
        | data -> `Assoc (metadata @ [ "result", data ]) in
      match result with
      | Tool_result.Completed payload -> Tool_result.Completed { payload with data }
      | Tool_result.Deferred payload -> Tool_result.Deferred { payload with data }
      | Tool_result.Failed payload -> Tool_result.Failed
          { payload with data_source = Tool_result.Explicit_data data; message = Yojson.Safe.to_string data } in
  match Plan.exports plan with
  | [] -> Ok result
  | _ :: _ ->
    let nodes = settled execution in
    let retained =
      Tool_result.retained_artifacts result
      @ List.concat_map (fun (node : Executor.node_result) -> Tool_result.retained_artifacts node.result) nodes
    in
    let raw_document =
      `Assoc (metadata @ [ "result", Tool_result.to_json result
             ; "nodes", `List (List.map Projection.node_result_to_json nodes)
             ; "retained_artifacts", `List (List.map Tool_output.normalized_artifact_ref_to_json retained) ])
    in
    let raw =
      Tool_output.artifact_manifest_to_json
        ~content:(Tool_result.message result) ~structured_content:raw_document
      |> Yojson.Safe.to_string
    in
    match Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
            ~bytes:raw ~mime:Tool_output.artifact_manifest_mime with
    | reference ->
      let reference = Tool_output.with_preview reference "" in
      let nodes =
        List.map (fun (node : Plan.node) ->
          match List.find_opt (fun (result : Executor.node_result) -> Plan.Node_id.equal node.id result.node_id) nodes with
          | Some result -> node_summary result
          | None -> `Assoc [ "node_id", `String (Plan.Node_id.to_string node.id)
                            ; "tool_name", `String node.tool_name
                            ; "settled", `Bool false; "disposition", `Null ]) (Plan.nodes plan)
      in
      let original_fields =
        match Tool_result.data result with
        | `Assoc fields -> List.filter (fun (name, _) -> List.mem name [ "composition_tool"; "tool_kind" ]) fields
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
      in
      let failure =
        match execution with
        | Ok _ -> []
        | Error (failure : Executor.failure) ->
          [ "cause", cause_summary failure.cause
          ; "effect_disposition", `String (Tool_result.failure_effect_disposition_to_string failure.effect_disposition) ]
      in
      let data = `Assoc (original_fields @ failure @ metadata
        @ [ "exports", selected_fields plan (settled execution)
          ; "nodes", `List nodes
          ; "execution_artifact", Tool_output.normalized_artifact_ref_to_json reference ]) in
      let projected =
        match result with
        | Tool_result.Completed payload -> Tool_result.Completed { payload with data }
        | Tool_result.Deferred payload -> Tool_result.Deferred { payload with data }
        | Tool_result.Failed payload -> Tool_result.Failed
            { payload with data_source = Tool_result.Explicit_data data; message = Yojson.Safe.to_string data }
      in
      Ok (Tool_result.with_retained_artifacts (reference :: retained) projected)
    | exception Sys_error message ->
      Error { Tool_bridge.kind = Tool_bridge.Artifact_storage_failure
            ; message = "composition execution artifact persistence failed: " ^ message }
;;
