(** Canonical JSON encodings of immutable plan errors. This module uses the
    plan's closed error types without acquiring an executor or runtime. *)

val schema_value_error_to_json :
  Keeper_tool_plan.schema_value_error -> Yojson.Safe.t

val pointer_resolution_error_to_json :
  Keeper_tool_plan.Json_pointer.resolution_error -> Yojson.Safe.t

val template_resolution_error_to_json :
  Keeper_tool_plan.Json_template.resolution_error -> Yojson.Safe.t

val plan_execution_error_to_json :
  Keeper_tool_plan.execution_error -> Yojson.Safe.t
