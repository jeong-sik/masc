(** Pure composition result and failure projection; no clock or publication acquisition. *)
module Executor = Keeper_tool_plan_executor

(* Composition tools are materialized Agent_core tools outside the Keeper
   descriptor registry, so their tool kind is observable through their own
   result payloads and node telemetry — never through descriptor route
   evidence. *)
let tool_kind_field kind =
  "tool_kind", `String (Keeper_tool_descriptor.tool_kind_to_string kind)
;;

let with_tool_kind_field kind = function
  | `Assoc fields -> `Assoc (tool_kind_field kind :: fields)
  | json -> json
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

let failure_effect_disposition_to_json = function
  | None -> `Null
  | Some disposition ->
    `String (Tool_result.failure_effect_disposition_to_string disposition)
;;

let deferred_kind_to_json = function
  | None -> `Null
  | Some kind -> `String (Keeper_tool_execution.deferred_kind_to_string kind)
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
  | Keeper_tool_plan.Json_template.Param_not_substituted name ->
    `Assoc
      [ "kind", `String "param_not_substituted"; "param", `String name ]
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
      ; "rejection", Tool_result.to_json (Tool_input_validation.rejection_result rejection)
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

let node_observation_result (node : Executor.node_result) =
  match node.output_validation_error with
  | None -> node.result
  | Some error ->
    Tool_result.Failed
      { effect_disposition = Tool_result.Effect_outcome_unknown
      ; class_ = Tool_result.Runtime_failure
      ; message = "Composition node output failed its declared schema"
      ; data_source = Tool_result.Explicit_data
          (`Assoc
            [ "validation_error", plan_execution_error_to_json error
            ; "producer_result", Tool_result.to_json node.result ])
      ; metadata = Tool_result.metadata node.result
      ; tool_name = node.tool_name
      ; duration_ms = Tool_result.duration_ms node.result }
;;

let wire_outcome_of_result : Tool_result.result -> Tool_result.tool_call_outcome =
  function
  | Tool_result.Completed _ -> Tool_result.Ok
  | Tool_result.Deferred _ -> Tool_result.Unknown
  | Tool_result.Failed _ -> Tool_result.Error
;;

let node_result_to_json (result : Executor.node_result) =
  `Assoc
    [ "node_id", `String (Keeper_tool_plan.Node_id.to_string result.node_id)
    ; "execution_id", Ids.Execution_id.to_yojson result.execution_id
    ; "tool_name", `String result.tool_name
    ; "input", result.input
    ; "schedule", schedule_to_json result.schedule
    ; "result", Tool_result.to_json (node_observation_result result)
    ; "tool_use_id", `String result.tool_use_id
    ; ( "failure_effect_disposition"
      , failure_effect_disposition_to_json result.failure_effect_disposition )
    ; "deferred_kind", deferred_kind_to_json result.deferred_kind
    ; "result_bytes", `Int result.result_bytes
    ; "truncated_to", Json_util.int_opt_to_json result.truncated_to
    ]
;;

let cause_to_json = function
  | Executor.Tool_did_not_complete result ->
    `Assoc
      [ "kind", `String "tool_did_not_complete"
      ; "node", node_result_to_json result
      ]
  | Executor.Node_observation_failed { node; detail } ->
    `Assoc
      [ "kind", `String "node_observation_failed"
      ; "node", node_result_to_json node
      ; "detail", `String detail
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

(* Why the failure comes before the settled nodes.

   This payload is what the durable tool-call row carries, and that row is
   truncated to [Keeper_tool_call_log.max_output_len] bytes on the serialized
   string. [settled] grows with the plan -- a node returning a task list put
   12KB in one row -- so with [settled] first the cut landed inside it and
   [cause] never reached disk. Eight failures of one composition on
   2026-09-03 were recorded with no readable reason for that exact ordering.

   Put [cause] and [effect_disposition] before [settled] so accumulated node
   rows cannot consume the log window before it reaches the diagnostic fields.
   A cause containing full node input or output can itself exceed that window. *)
let failure_payload ~tool_name ~tool_kind ~cause ~effect_disposition ~settled =
  `Assoc
    (("composition_tool", `String tool_name)
     :: tool_kind_field tool_kind
     :: [ "cause", cause
        ; "effect_disposition", `String effect_disposition
        ; "settled", `List settled
        ])
;;

let failure_data ~tool_name ~tool_kind (failure : Executor.failure) =
  failure_payload
    ~tool_name
    ~tool_kind
    ~cause:(cause_to_json failure.cause)
    ~effect_disposition:
      (Tool_result.failure_effect_disposition_to_string failure.effect_disposition)
    ~settled:(List.map node_result_to_json failure.settled)
;;

let plan_execution_error_kind = function
  | Keeper_tool_plan.Unknown_node_id _ -> Keeper_terminal_effect_detail.Unknown_node_id
  | Keeper_tool_plan.Input_template_resolution_failed _ ->
    Keeper_terminal_effect_detail.Input_template_resolution_failed
  | Keeper_tool_plan.Input_validation_failed _ ->
    Keeper_terminal_effect_detail.Input_validation_failed
  | Keeper_tool_plan.Output_validation_failed _ ->
    Keeper_terminal_effect_detail.Output_validation_failed
  | Keeper_tool_plan.Output_not_composable _ ->
    Keeper_terminal_effect_detail.Output_not_composable
;;

let node_deferral = function
  | None -> Keeper_terminal_effect_detail.Deferral_unrecorded
  | Some Keeper_tool_execution.Generic_deferred ->
    Keeper_terminal_effect_detail.Generic_deferral
  | Some (Keeper_tool_execution.External_effect_deferred _) ->
    Keeper_terminal_effect_detail.External_effect_deferral
;;

(* The executor's causes split in two, and the split is the disposition they
   carry. [Pre_effect_only] is the completion mismatch: the executor refuses
   the invocation before any node runs and stamps it [Proven_pre_effect]
   in [Keeper_tool_plan_executor.execute_bound], so it has no terminal effect to
   name. Everything else can settle after a node acted. Naming both arms keeps
   the projection total, so a new [Executor.cause] is a compile error here
   rather than a failure the caller drops. *)
type composition_projection =
  | Terminal_cause of Keeper_terminal_effect_detail.composition_cause
  | Pre_effect_only of
      { expected : Agent_core.Tool_contract.completion
      ; actual : Agent_core.Tool_contract.completion
      }

let composition_cause (failure : Executor.failure) =
  match failure.cause with
  | Executor.Tool_did_not_complete node ->
    let node_id = Keeper_tool_plan.Node_id.to_string node.node_id in
    (match node.result with
     | Tool_result.Deferred _ ->
       (* A deferred node did not fail. Its payload is the deferral's own JSON
          data, so it stays in the failure object and out of a message. *)
       Terminal_cause
         (Keeper_terminal_effect_detail.Node_deferred
            { node_id
            ; model_tool_name = node.tool_name
            ; deferral = node_deferral node.deferred_kind
            })
     | Tool_result.Completed _ | Tool_result.Failed _ ->
       Terminal_cause
         (Keeper_terminal_effect_detail.Node_failed
            { node_id
            ; model_tool_name = node.tool_name
            ; message = Tool_result.message node.result
            }))
  | Executor.Node_observation_failed { node; detail } ->
    Terminal_cause
      (Keeper_terminal_effect_detail.Node_observation_failed
         { node_id = Keeper_tool_plan.Node_id.to_string node.node_id
         ; model_tool_name = node.tool_name
         ; detail
         })
  | Executor.Plan_execution_failed { node_id; schedule = _; error } ->
    Terminal_cause
      (Keeper_terminal_effect_detail.Plan_execution_failed
         { node_id = Keeper_tool_plan.Node_id.to_string node_id
         ; error = plan_execution_error_kind error
         })
  | Executor.Outer_completion_mismatch { expected; actual } ->
    Pre_effect_only { expected; actual }
;;

let failure_class (failure : Executor.failure) =
  match failure.cause with
  | Executor.Tool_did_not_complete result ->
    Option.value
      ~default:Tool_result.Runtime_failure
      (Tool_result.failure_class result.result)
  | Executor.Plan_execution_failed _
  | Executor.Node_observation_failed _
  | Executor.Outer_completion_mismatch _ ->
    Tool_result.Runtime_failure
;;

let evidence_nodes_of_execution = function
  | Ok settled -> List.map node_result_to_json settled
  | Error failure -> List.map node_result_to_json failure.Executor.settled
;;
