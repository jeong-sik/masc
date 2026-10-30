(* WebMCP consumer tool schemas — the TOML files are the SSOT. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let list_schema = schema_of_name "keeper_webmcp_list"
let call_schema = schema_of_name "keeper_webmcp_call"
let schemas = [ list_schema; call_schema ]
