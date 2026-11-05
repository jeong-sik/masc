(** See [tool_schemas_code_query.mli]. *)

let schema_of_name = Tool_definition_embedded.schema

let schema = schema_of_name "keeper_code_query"
let schemas = [ schema ]
