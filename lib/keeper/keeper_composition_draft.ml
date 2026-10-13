module Plan = Keeper_tool_plan
module Catalog = Keeper_tool_composition_catalog
module Descriptor = Keeper_tool_descriptor

type t =
  { plan : Plan.t
  ; execution : Catalog.execution_mode
  ; reference : Tool_output.artifact_ref
  }

type error =
  | Plan_rejected of Keeper_tool_plan_request.error
  | Inputs_rejected of Plan.Node_id.t * Plan.execution_error
  | Unsupported_node of { node_id : Plan.Node_id.t; tool_name : string }
  | Storage_failed of string
  | Draft_read_failed of Tool_blob_store.fetch_error
  | Draft_not_found
  | Malformed_draft of string
  | Different_keeper
  | Capability_changed

let prepare_tool_name = Catalog.prepare_tool_name
let run_tool_name = Catalog.run_tool_name
let ( let* ) = Result.bind

let plan draft = draft.plan
let execution draft = draft.execution
let reference draft = draft.reference

let error_to_json = function
  | Plan_rejected error -> Keeper_tool_plan_request.error_to_json error
  | Inputs_rejected (node_id, error) ->
    `Assoc [ "kind", `String "inputs_rejected"
           ; "node_id", `String (Plan.Node_id.to_string node_id)
           ; "error", Keeper_tool_composition_projection.plan_execution_error_to_json error ]
  | Unsupported_node { node_id; tool_name } ->
    `Assoc [ "kind", `String "unsupported_node"
           ; "node_id", `String (Plan.Node_id.to_string node_id)
           ; "tool_name", `String tool_name
           ; "detail", `String "Transient compositions currently require static read-only ordinary nodes; use the direct tool for this action." ]
  | Storage_failed detail -> `Assoc [ "kind", `String "storage_failed"; "detail", `String detail ]
  | Draft_read_failed error -> `Assoc [ "kind", `String "draft_read_failed"; "detail", `String (Tool_blob_store.fetch_error_to_string error) ]
  | Draft_not_found -> `Assoc [ "kind", `String "draft_not_found" ]
  | Malformed_draft detail -> `Assoc [ "kind", `String "malformed_draft"; "detail", `String detail ]
  | Different_keeper -> `Assoc [ "kind", `String "different_keeper" ]
  | Capability_changed -> `Assoc [ "kind", `String "capability_changed"; "detail", `String "Prepare again against the current frozen tool and Skill surface." ]
;;

let prepare_schema : Masc_domain.tool_schema =
  let input_schema =
    match Keeper_tool_plan_request.input_schema with
    | `Assoc fields ->
      let properties = match List.assoc_opt "properties" fields with
        | Some (`Assoc properties) -> properties | _ -> invalid_arg "canonical plan schema has no properties" in
      let required = match List.assoc_opt "required" fields with
        | Some (`List required) -> required | _ -> invalid_arg "canonical plan schema has no required fields" in
      `Assoc (("properties", `Assoc
          (("execution", `Assoc [ "type", `String "string"; "enum", `List [ `String "inline"; `String "async" ] ]) :: properties))
        :: ("required", `List (`String "execution" :: required))
        :: List.remove_assoc "required" (List.remove_assoc "properties" fields))
    | _ -> invalid_arg "canonical plan request schema is not an object"
  in
  { Tool_schemas_composition_control.prepare_schema with input_schema }
;;

let run_schema = Tool_schemas_composition_control.run_schema
;;

let validate_plan ~capability_surface json =
  let* plan = Keeper_tool_plan_request.plan_of_json
      ~descriptors:(Keeper_capability_surface.descriptors capability_surface) json
      |> Result.map_error (fun error -> Plan_rejected error) in
  let* () =
    List.fold_left (fun acc (node : Plan.node) ->
      let* () = acc in
      match Plan.descriptor plan node.id with
      | Some descriptor ->
        (match descriptor.Descriptor.execution, Descriptor.readonly_static_hint descriptor with
         | Descriptor.Ordinary _, Some true -> Ok ()
         | Descriptor.Terminal, _ | Descriptor.Ordinary _, (Some false | None) ->
           Error (Unsupported_node { node_id = node.id; tool_name = node.tool_name }))
      | None -> Error (Unsupported_node { node_id = node.id; tool_name = node.tool_name })) (Ok ()) (Plan.nodes plan)
  in
  let* _inputs = Plan.prepare_inputs plan |> Result.map_error (fun (node_id, error) -> Inputs_rejected (node_id, error)) in
  Ok plan
;;

let contracts ~capability_surface plan =
  let tools = List.map (fun (node : Plan.node) ->
    match Plan.descriptor plan node.id with
    | None -> `Null
    | Some descriptor ->
      let output_schema = match descriptor.Descriptor.composable_output with
        | Descriptor.Opaque_output -> `Null
        | Descriptor.Json_output { schema } -> schema in
      `Assoc [ "node_id", `String (Plan.Node_id.to_string node.id)
             ; "route", Descriptor.route_evidence_json descriptor
             ; "input_schema", descriptor.input_schema
             ; "output_schema", output_schema ]) (Plan.nodes plan) in
  `Assoc [ "surface_digest", `String (Keeper_capability_surface.digest capability_surface)
         ; "tools", `List tools ]
;;

let put_document ~base_path json =
  match Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
      ~bytes:(Yojson.Safe.to_string json) ~mime:"application/json" with
  | reference -> Ok reference
  | exception Sys_error detail -> Error (Storage_failed detail)
;;

let prepare ~base_path ~capability_surface ~keeper_name ~execution json =
  let* plan = validate_plan ~capability_surface json in
  let* canonical = Keeper_tool_plan_request.to_yojson plan
    |> Result.map_error (fun (Keeper_tool_plan_request.Unsubstituted_param { name }) -> Malformed_draft ("unbound parameter " ^ name)) in
  let document = `Assoc
    [ "keeper", `String keeper_name
    ; "execution", `String (Catalog.execution_mode_to_string execution)
    ; "plan", canonical
    ; "contracts", contracts ~capability_surface plan ] in
  let* reference = put_document ~base_path document in
  Ok { plan; execution; reference }
;;

let draft_fields = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length (List.sort_uniq String.compare names) <> List.length names then Error (Malformed_draft "duplicate field")
    else if List.sort String.compare names <> List.sort String.compare [ "keeper"; "execution"; "plan"; "contracts" ] then
      Error (Malformed_draft "expected keeper, execution, plan and contracts")
    else Ok fields
  | _ -> Error (Malformed_draft "expected object")
;;

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Malformed_draft ("expected string " ^ name))
;;

let load ~base_path ~capability_surface ~keeper_name ~sha256 =
  let* bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256
      |> Result.map_error (fun error -> Draft_read_failed error) in
  let* bytes = match bytes with Some bytes -> Ok bytes | None -> Error Draft_not_found in
  let* json = match Yojson.Safe.from_string bytes with
    | json -> Ok json | exception Yojson.Json_error detail -> Error (Malformed_draft detail) in
  let* fields = draft_fields json in
  let* owner = required_string fields "keeper" in
  let* () = if String.equal owner keeper_name then Ok () else Error Different_keeper in
  let* raw_execution = required_string fields "execution" in
  let* execution = match raw_execution with
    | "inline" -> Ok Catalog.Inline | "async" -> Ok Catalog.Async
    | _ -> Error (Malformed_draft "execution must be inline or async") in
  let* plan = match List.assoc_opt "plan" fields with
    | Some json -> validate_plan ~capability_surface json
    | None -> Error (Malformed_draft "missing plan") in
  let* () = match List.assoc_opt "contracts" fields with
    | Some recorded when Yojson.Safe.equal (Yojson.Safe.sort recorded) (Yojson.Safe.sort (contracts ~capability_surface plan)) -> Ok ()
    | Some _ | None -> Error Capability_changed in
  let* reference = Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length bytes)
      ~preview:(Tool_blob_store.make_preview bytes) ~mime:"application/json"
      |> Result.map_error (fun error -> Malformed_draft (Tool_output.make_error_to_string error)) in
  Ok { plan; execution; reference }
;;

let preview draft =
  let layers = Plan.dependency_layers draft.plan |> List.map (fun nodes ->
    `List (List.map (fun (node : Plan.node) -> `String (Plan.Node_id.to_string node.id)) nodes)) in
  let batches = Keeper_tool_plan_executor.schedule draft.plan |> List.map (function
    | Keeper_tool_plan_executor.Serial_batch node ->
      `List [ `Assoc [ "node_id", `String (Plan.Node_id.to_string node.node.id)
                      ; "schedule", Keeper_tool_composition_projection.schedule_to_json node.schedule ] ]
    | Keeper_tool_plan_executor.Concurrent_batch nodes ->
      `List (List.map (fun (node : Keeper_tool_plan_executor.scheduled_node) ->
        `Assoc [ "node_id", `String (Plan.Node_id.to_string node.node.id)
               ; "schedule", Keeper_tool_composition_projection.schedule_to_json node.schedule ]) nodes)) in
  `Assoc [ "draft", Tool_output.normalized_artifact_ref_to_json draft.reference
         ; "execution", `String (Catalog.execution_mode_to_string draft.execution)
         ; "branch_failure_policy", `String (Plan.branch_failure_policy_to_string (Plan.branch_failure_policy draft.plan))
         ; "dependency_layers", `List layers
         ; "schedule_preview", `List batches
         ; "scheduling", `String "The executor dispatches ready nodes dynamically; these are dependency and descriptor groups, not fixed start times."
         ; "exports", `List (List.map (fun (export : Plan.export) ->
             `Assoc [ "name", `String export.name; "node", `String (Plan.Node_id.to_string export.node_id)
                    ; "pointer", `String (Plan.Json_pointer.to_string export.pointer) ]) (Plan.exports draft.plan)) ]
;;

let record_invocation ~base_path ~composition_run_id ~invocation draft =
  put_document ~base_path (`Assoc
    [ "draft", Tool_output.normalized_artifact_ref_to_json draft.reference
    ; "composition_run_id", `String (Plan.Composition_run_id.to_string composition_run_id)
    ; "tool_use_id", `String (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
    ; "source_turn", `Int (Agent_core.Tool_contract.Invocation.turn invocation) ])
;;
