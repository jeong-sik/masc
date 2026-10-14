module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
open Result.Syntax

type readiness = Waiting | Ready
type observed = Pending | Terminal of Async.entry

let original_matches binding (entry : Async.entry) =
  match entry.request_context with
  | None -> Error "composition request has no accepted original source"
  | Some fields ->
    let* original = Dependency.composition_of_request_context ~request_id:entry.request_id fields in
    if Yojson.Safe.equal (Dependency.composition_to_json original)
        (Dependency.composition_to_json binding)
    then Ok () else Error "composition request differs from the original result binding"

let observe ~base_path ~keeper_name binding =
  let* () = Keeper_composition_named_run.validate ~base_path ~keeper_name binding in
  let* entry = match Async.load_canonical_request ~base_path ~caller:keeper_name binding.Dependency.request_id with
    | Found entry -> Ok entry
    | Absent -> Error "original composition request is absent"
    | Unreadable reason -> Error ("original composition request is unreadable: " ^ reason)
    | Rejected rejection -> Error (Yojson.Safe.to_string (Async.access_rejection_to_json rejection)) in
  let* () = if String.equal entry.keeper_name keeper_name then Ok ()
    else Error "composition result belongs to a different Keeper lane" in
  let* () = original_matches binding entry in
  match entry.status with
  | Queued | Running | Cancelling _ -> Ok Pending
  | Waiting_for_dependencies _ -> Ok Pending
  | Done _ | Lost _ | Cancelled _ | Persistence_failed _ ->
    let* proof = Async.load_canonical_durable_terminal ~base_path ~caller:keeper_name binding.request_id
      |> Result.map_error Async.canonical_terminal_error_to_string in
    let terminal = Async.durable_terminal_entry proof in
    let* () = original_matches binding terminal in
    let* () = Keeper_composition_named_run.validate ~base_path ~keeper_name binding in
    Ok (Terminal terminal)

let readiness ~base_path ~keeper_name binding =
  observe ~base_path ~keeper_name binding |> Result.map (function Pending -> Waiting | Terminal _ -> Ready)

let handle ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) ~args =
  let failure detail = Keeper_tool_execution.failure
      ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect detail in
  let decoded =
    let* fields = Agent_core.Execution_json.object_fields ~context:"composition result input"
      ~required:["binding"] ~optional:[] args in
    Dependency.composition_of_json (List.assoc "binding" fields) in
  match decoded with
  | Error detail -> failure detail
  | Ok binding ->
    let publish result =
      let references = Tool_output.normalized_artifact_refs_in_json (Tool_result.data result) in
      let result = Tool_result.with_retained_artifacts references result in
      match Tool_bridge.attach_artifact_manifest
          ~projection:Tool_output.Inline_with_structured_diagnostic ~base_path:config.base_path result with
      | Ok result -> Keeper_tool_execution.of_tool_result result
      | Error error -> Keeper_tool_execution.failure_data
          ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
          ~message:("canonical composition result remains available; reader manifest publication failed: " ^ error.message)
          (`Assoc ["binding", Dependency.composition_to_json binding]) in
    let terminal_failure entry detail =
      Tool_result.make_err ~tool_name:Tool_schemas_composition_control.result_schema.name
        ~start_time:(Tool_timing.start ()) ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Proven_pre_effect
        ~data:(`Assoc ["binding", Dependency.composition_to_json binding;
                       "request", Async.entry_to_json entry]) detail |> publish in
    match observe ~base_path:config.base_path ~keeper_name:meta.name binding with
    | Error detail -> failure detail
    | Ok Pending ->
      Keeper_tool_execution.deferred_composition_result ~binding
        (`Assoc ["binding", Dependency.composition_to_json binding;
                 "status", `String "waiting_for_composition_result"])
    | Ok (Terminal entry) ->
      match entry.status with
      | Async.Done {ok = true; data = Some (`Assoc fields as data); body = _} ->
        let valid = Agent_core.Execution_json.validate ~context:"composition result exports" data in
        (match valid, List.assoc_opt "composition_tool" fields with
         | Ok (), Some (`String tool) when String.equal tool binding.composition_tool ->
           let selected = `Assoc ["binding", Dependency.composition_to_json binding; "result", data] in
           let manifest = Tool_output.artifact_manifest_to_json
               ~content:(Yojson.Safe.to_string selected) ~structured_content:selected |> Yojson.Safe.to_string in
           (match Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:config.base_path)
               ~bytes:manifest ~mime:Tool_output.artifact_manifest_mime with
            | reference ->
              let reference = Tool_output.with_preview reference "" in
              Tool_result.make_ok ~tool_name:Tool_schemas_composition_control.result_schema.name
                ~start_time:(Tool_timing.start ())
                ~data:(`Assoc ["binding", Dependency.composition_to_json binding; "result", data;
                  "result_artifact",Tool_output.normalized_artifact_ref_to_json reference]) () |> publish
            | exception Sys_error detail ->
              failure ("canonical child result is retained; result artifact publication failed: " ^ detail))
         | Error error, _ -> terminal_failure entry (Agent_core.Execution_json.validation_error_to_string error)
         | Ok (), _ -> terminal_failure entry "successful composition has no matching canonical structured result")
      | Async.Done {ok = false; body; data = _} -> terminal_failure entry ("original composition failed: " ^ body)
      | Async.Done {ok = true; data = Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _); _}
      | Async.Done {ok = true; data = None; _} -> terminal_failure entry "successful composition has no structured canonical result"
      | Lost {reason} -> terminal_failure entry ("original composition was lost: " ^ reason)
      | Cancelled {reason; cancelled_by = _} -> terminal_failure entry ("original composition was cancelled: " ^ reason)
      | Persistence_failed {reason; attempted_status = _} -> terminal_failure entry ("composition result publication failed: " ^ reason)
      | Queued | Running | Cancelling _ | Waiting_for_dependencies _ ->
        failure "canonical terminal proof unexpectedly contains a pending composition"
