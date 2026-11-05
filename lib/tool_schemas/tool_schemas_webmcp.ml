(* WebMCP consumer tool schemas — the TOML files are the SSOT. *)

let schema_of_name = Tool_definition_embedded.schema

let list_schema = schema_of_name "keeper_webmcp_list"
let call_schema = schema_of_name "keeper_webmcp_call"
let schemas = [ list_schema; call_schema ]
