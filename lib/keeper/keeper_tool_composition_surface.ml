module Catalog = Keeper_tool_composition_catalog
module Executor = Keeper_tool_plan_executor

let empty_input_schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc []
    ; "required", `List []
    ; "additionalProperties", `Bool false
    ]
;;

let schedule_to_json (schedule : Agent_core.Tool_contract.schedule) =
  `Assoc
    [ "planned_index", `Int schedule.planned_index
    ; "batch_index", `Int schedule.batch_index
    ; "batch_size", `Int schedule.batch_size
    ; ( "execution_mode"
      , Agent_core.Tool_contract.execution_mode_to_yojson schedule.execution_mode )
    ]
;;

let node_result_to_json (result : Executor.node_result) =
  `Assoc
    [ "node_id", `String (Keeper_tool_plan.Node_id.to_string result.node_id)
    ; "tool_name", `String result.tool_name
    ; "input", result.input
    ; "schedule", schedule_to_json result.schedule
    ; "result", Tool_result.to_json result.result
    ]
;;

let json_type_to_string = function
  | Keeper_tool_plan.Null_type -> "null"
  | Keeper_tool_plan.Boolean_type -> "boolean"
  | Keeper_tool_plan.Integer_type -> "integer"
  | Keeper_tool_plan.Number_type -> "number"
  | Keeper_tool_plan.String_type -> "string"
  | Keeper_tool_plan.Array_type -> "array"
  | Keeper_tool_plan.Object_type -> "object"
;;

let path_to_json path = `List (List.map (fun segment -> `String segment) path)

let schema_value_error_to_json = function
  | Keeper_tool_plan.Unsupported_schema_type schema ->
    `Assoc
      [ "kind", `String "unsupported_schema_type"
      ; "schema", schema
      ]
  | Keeper_tool_plan.Missing_required_field { path; field } ->
    `Assoc
      [ "kind", `String "missing_required_field"
      ; "path", path_to_json path
      ; "field", `String field
      ]
  | Keeper_tool_plan.Unexpected_field { path; field } ->
    `Assoc
      [ "kind", `String "unexpected_field"
      ; "path", path_to_json path
      ; "field", `String field
      ]
  | Keeper_tool_plan.Duplicate_value_field { path; field } ->
    `Assoc
      [ "kind", `String "duplicate_value_field"
      ; "path", path_to_json path
      ; "field", `String field
      ]
  | Keeper_tool_plan.Type_mismatch { path; expected; actual } ->
    `Assoc
      [ "kind", `String "type_mismatch"
      ; "path", path_to_json path
      ; "expected", `String (json_type_to_string expected)
      ; "actual", `String (json_type_to_string actual)
      ]
;;

let pointer_resolution_error_to_json = function
  | Keeper_tool_plan.Json_pointer.Missing_object_field field ->
    `Assoc
      [ "kind", `String "missing_object_field"
      ; "field", `String field
      ]
  | Keeper_tool_plan.Json_pointer.Ambiguous_object_field field ->
    `Assoc
      [ "kind", `String "ambiguous_object_field"
      ; "field", `String field
      ]
  | Keeper_tool_plan.Json_pointer.Invalid_array_index index ->
    `Assoc
      [ "kind", `String "invalid_array_index"
      ; "index", `String index
      ]
  | Keeper_tool_plan.Json_pointer.Array_index_out_of_bounds index ->
    `Assoc
      [ "kind", `String "array_index_out_of_bounds"
      ; "index", `Int index
      ]
  | Keeper_tool_plan.Json_pointer.Expected_container segment ->
    `Assoc
      [ "kind", `String "expected_container"
      ; "segment", `String segment
      ]
;;

let template_resolution_error_to_json = function
  | Keeper_tool_plan.Json_template.Missing_output node_id ->
    `Assoc
      [ "kind", `String "missing_output"
      ; "source_node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ]
  | Keeper_tool_plan.Json_template.Pointer_resolution_failed { node_id; error } ->
    `Assoc
      [ "kind", `String "pointer_resolution_failed"
      ; "source_node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "error", pointer_resolution_error_to_json error
      ]
;;

let plan_execution_error_to_json = function
  | Keeper_tool_plan.Unknown_node_id node_id ->
    `Assoc
      [ "kind", `String "unknown_node_id"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ]
  | Keeper_tool_plan.Input_template_resolution_failed { node_id; error } ->
    `Assoc
      [ "kind", `String "input_template_resolution_failed"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "error", template_resolution_error_to_json error
      ]
  | Keeper_tool_plan.Input_validation_failed { node_id; tool_name; rejection } ->
    `Assoc
      [ "kind", `String "input_validation_failed"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "tool_name", `String tool_name
      ; "rejection", Tool_result.to_json rejection
      ]
  | Keeper_tool_plan.Output_validation_failed { node_id; tool_name; error } ->
    `Assoc
      [ "kind", `String "output_validation_failed"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "tool_name", `String tool_name
      ; "error", schema_value_error_to_json error
      ]
  | Keeper_tool_plan.Output_not_composable { node_id; tool_name } ->
    `Assoc
      [ "kind", `String "output_not_composable"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "tool_name", `String tool_name
      ]
;;

let cause_to_json = function
  | Executor.Tool_did_not_complete result ->
    `Assoc
      [ "kind", `String "tool_did_not_complete"
      ; "node", node_result_to_json result
      ]
  | Executor.Plan_execution_failed { node_id; schedule; error } ->
    `Assoc
      [ "kind", `String "plan_execution_failed"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "schedule", schedule_to_json schedule
      ; "error", plan_execution_error_to_json error
      ]
  | Executor.Outer_completion_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "outer_completion_mismatch"
      ; "expected", Agent_core.Tool_contract.completion_to_yojson expected
      ; "actual", Agent_core.Tool_contract.completion_to_yojson actual
      ]
;;

let failure_data ~tool_name (failure : Executor.failure) =
  `Assoc
    [ "composition_tool", `String tool_name
    ; "settled", `List (List.map node_result_to_json failure.settled)
    ; "cause", cause_to_json failure.cause
    ; ( "effect_disposition"
      , `String
          (Tool_result.failure_effect_disposition_to_string
             failure.effect_disposition) )
    ]
;;

let failure_class (failure : Executor.failure) =
  match failure.cause with
  | Executor.Tool_did_not_complete result ->
    Option.value
      ~default:Tool_result.Runtime_failure
      (Tool_result.failure_class result.result)
  | Executor.Plan_execution_failed _ | Executor.Outer_completion_mismatch _ ->
    Tool_result.Runtime_failure
;;

let result_of_execution ~tool_name ~start_time = function
  | Ok settled ->
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:
        (`Assoc
            [ "composition_tool", `String tool_name
            ; "actions", `List (List.map node_result_to_json settled)
            ])
      ()
  | Error
      ({ Executor.cause = Executor.Tool_did_not_complete result; _ } as failure :
        Executor.failure) ->
    let data = failure_data ~tool_name failure in
    (match result.result with
     | Tool_result.Deferred payload ->
       Tool_result.make_deferred
         ~tool_name
         ~start_time
         ~data
         ?metadata:payload.metadata
         ()
     | Tool_result.Failed payload ->
       Tool_result.make_err
         ~tool_name
         ~class_:payload.class_
         ~start_time
         ~data
         ?metadata:payload.metadata
         (Yojson.Safe.to_string data)
     | Tool_result.Completed _ ->
       Tool_result.make_err
         ~tool_name
         ~class_:Tool_result.Runtime_failure
         ~start_time
         ~data
         "composition executor reported a completed result as incomplete")
  | Error failure ->
    let data = failure_data ~tool_name failure in
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Runtime_failure
      ~start_time
      ~data
      (Yojson.Safe.to_string data)
;;

let make_tools
      ~catalog
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ?turn_sandbox_factory
      ?clock
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ?record_gate_result
      ?on_completed
      ?on_deferred
      ?on_external_effect_deferred
      ?on_failed
      ?on_externalization_error
      ()
  =
  Catalog.entries catalog
  |> List.map (fun (entry : Catalog.entry) ->
    let tool_name = Catalog.tool_name entry in
    let completion = Executor.outer_completion entry.plan in
    let descriptor =
      match completion with
      | Agent_core.Tool_contract.Continue_after_success ->
        Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Serial
      | Agent_core.Tool_contract.Terminal_after_success disposition ->
        Agent_core.Tool.terminal_descriptor disposition
    in
    let tool_externalization_error =
      match completion with
      | Agent_core.Tool_contract.Continue_after_success -> None
      | Agent_core.Tool_contract.Terminal_after_success _ ->
        on_externalization_error
    in
    Tool_bridge.agent_core_tool_of_masc_with_execution_env
      ~descriptor
      ~base_path:config.base_path
      ?on_externalization_error:tool_externalization_error
      ~name:tool_name
      ~description:
        (Option.value
           ~default:("Execute the validated Keeper composition " ^ entry.name ^ ".")
           entry.description)
      ~input_schema:empty_input_schema
      (fun execution_env input ->
        let start_time = Time_compat.now () in
        match
          Tool_input_validation.validate_args
            ~schema:empty_input_schema
            ~name:tool_name
            ~args:input
            ()
        with
        | Error rejection -> rejection
        | Ok _ ->
          (match Agent_core.Tool.Execution_env.invocation execution_env with
           | None ->
             Tool_result.runtime_err
               ~tool_name
               ~start_time
               "composition execution requires Agent-Core invocation identity"
           | Some parent_invocation ->
             let execution =
               Executor.execute_keeper
                 ~plan:entry.plan
                 ~run_id:(Keeper_tool_plan.Run_id.fresh ())
                 ~parent_invocation
                 ~config
                 ~meta
                 ~publication_recovery
                 ~ctx_snapshot
                 ?turn_sandbox_factory
                 ?clock
                 ?continuation_channel
                 ?gate_context
                 ?gate_grant
                 ?record_gate_result
                 ?on_completed
                 ?on_deferred
                 ?on_external_effect_deferred
                 ?on_failed
                 ()
             in
             (match completion, execution with
              | ( Agent_core.Tool_contract.Terminal_after_success _
                , Error failure )
                when failure.effect_disposition <> Tool_result.Proven_pre_effect
                     && not
                          (match failure.cause with
                           | Executor.Tool_did_not_complete
                               { result = Tool_result.Deferred _; _ } ->
                             true
                           | Executor.Tool_did_not_complete
                               { result =
                                   (Tool_result.Completed _ | Tool_result.Failed _)
                               ; _
                               }
                           | Executor.Plan_execution_failed _
                           | Executor.Outer_completion_mismatch _ ->
                             false) ->
                Option.iter
                  (fun mark_failed ->
                     let diagnostic =
                       failure_data ~tool_name failure |> Yojson.Safe.to_string
                     in
                     mark_failed
                       { Keeper_tools_agent_core.failure_class =
                           failure_class failure
                       ; effect_disposition = failure.effect_disposition
                       ; diagnostic
                       })
                  on_failed
              | Agent_core.Tool_contract.Continue_after_success, _
              | Agent_core.Tool_contract.Terminal_after_success _, Ok _
              | ( Agent_core.Tool_contract.Terminal_after_success _
                , Error
                    { Executor.effect_disposition = Tool_result.Proven_pre_effect
                    ; _
                    } ) ->
                ());
             result_of_execution ~tool_name ~start_time execution)))
;;
