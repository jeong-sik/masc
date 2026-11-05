(** See [tool_schemas_composition_control.mli]. *)

let schema_of_name = Tool_definition_embedded.schema

let status_schema = schema_of_name "keeper_composition_status"
let cancel_schema = schema_of_name "keeper_composition_cancel"
let prepare_schema = schema_of_name "keeper_composition_prepare"
let run_schema = schema_of_name "keeper_composition_run"
let result_schema = schema_of_name "keeper_composition_result"
