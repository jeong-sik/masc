(** See [tool_schemas_receipt_wait.mli]. *)

let schema_of_name = Tool_definition_embedded.schema

let schema = schema_of_name "keeper_receipt_wait"
let schemas = [ schema ]
