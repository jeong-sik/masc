(** Canonical pure projection of immutable plan errors. *)

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
